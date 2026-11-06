import Foundation

/// Reads a query's response as it comes, on its session's queue: frames
/// decompressed, blocks read once whole, each one added to the result and
/// reported. An error the server writes after the result had begun is found
/// at the end; one before it is the response's status.
final class CHStreamReader: @unchecked Sendable {
    private let queryID: String
    private let maxRows: Int?
    private let continuation: AsyncThrowingStream<CHQueryEvent, Error>.Continuation
    private let started = ContinuousClock.now

    private let frames = CHByteQueue()
    private let native = CHByteQueue()
    private var result = CHResult()
    private var status = 0
    private var exceptionTag: String?
    /// An error status's body.
    private var errorBody = Data()
    /// Blocks are tried once this many bytes are there (twice as many as
    /// when one wasn't whole), so a block isn't read again for every packet.
    private var threshold = 0
    /// What stopped the reading of blocks (the rest is kept, to find a server error in it).
    private var decodeError: Error?
    private var receivedBytes = 0
    private var firstRows: Duration?
    private let finished = CHLocked(false)

    /// Stops the request (an unreadable column: the rest can't be read either).
    var onStop: (() -> Void)?

    /// Whether the response is in frames (`compress=1`).
    private let compressed: Bool

    /// The bytes kept at most: the reading stops there (also when the
    /// server's own limit can't be set, for a user with readonly = 1).
    private let maxBytes: Int?
    /// Whether JSON columns come as their text.
    private let jsonAsText: Bool
    /// Stopped at `maxBytes` (the request cancelled: not an error).
    private var stoppedAtLimit = false

    init(queryID: String, maxRows: Int?, maxBytes: Int?, compressed: Bool, jsonAsText: Bool,
         continuation: AsyncThrowingStream<CHQueryEvent, Error>.Continuation) {
        self.queryID = queryID
        self.maxRows = maxRows
        self.maxBytes = maxBytes
        self.compressed = compressed
        self.jsonAsText = jsonAsText
        self.continuation = continuation
    }

    var isFinished: Bool { finished.value }

    func receive(_ response: URLResponse) {
        guard let http = response as? HTTPURLResponse else { return }
        status = http.statusCode
        exceptionTag = http.value(forHTTPHeaderField: "X-ClickHouse-Exception-Tag")
    }

    func receive(_ data: Data) {
        receivedBytes += data.count
        guard status == 200 else {
            if errorBody.count < 1 << 20 { errorBody.append(data) }
            return
        }
        data.withUnsafeBytes { (compressed ? frames : native).append($0) }
        guard decodeError == nil, !stoppedAtLimit else { return }
        do {
            if compressed { try CHFrameReader.decompress(frames, into: native) }
            try readBlocks(final: false)
        } catch {
            decodeError = error
            if case CHDecodeError.unsupportedType = error, !containsException { onStop?() }
        }
    }

    private var containsException: Bool {
        CHException.find(in: native.unread, tag: exceptionTag) != nil
    }

    private func readBlocks(final: Bool) throws {
        while native.count > 0, final || native.count >= threshold {
            var reader = CHNativeReader(native.unread, jsonAsText: jsonAsText)
            let block: CHBlock
            do {
                block = try reader.readBlock()
            } catch CHDecodeError.needMoreData {
                if final { throw CHDecodeError.needMoreData }
                threshold = native.count * 2
                return
            }
            native.consume(reader.offset)
            threshold = 0
            try result.append(block)
            if block.rowCount > 0, firstRows == nil { firstRows = ContinuousClock.now - started }
            continuation.yield(.result(result))
            if let maxBytes, result.byteCount >= maxBytes, !final {
                stoppedAtLimit = true
                onStop?()
                return
            }
        }
    }

    func complete(_ error: Error?) {
        defer { finished.value = true }
        if stoppedAtLimit {
            continuation.yield(.finished(stats(reachedLimit: true)))
            continuation.finish()
            return
        }
        if let error {
            // Cancelled by the viewer: the iteration has ended already.
            continuation.finish(throwing: decodeError.map(Self.clientError) ?? error)
            return
        }
        guard status == 200 else {
            var body = errorBody
            // Frames (`compress=1`): the rows the server had written, then its error.
            body.withUnsafeBytes { raw in
                guard CHFrameReader.looksLikeFrame(raw) else { return }
                let input = CHByteQueue(), output = CHByteQueue()
                input.append(raw)
                try? CHFrameReader.decompress(input, into: output)
                if output.count > 0 { body = Data(output.unread) }
            }
            if let serverError = CHException.find(in: body, tag: exceptionTag) ?? body.withUnsafeBytes(plainError) {
                continuation.finish(throwing: serverError)
                return
            }
            let text = String(decoding: body.prefix(64 * 1024), as: UTF8.self)
            continuation.finish(throwing: CHClientError.unexpectedResponse(status: status, text: String(text.prefix(500))))
            return
        }
        do {
            if decodeError == nil {
                if compressed { try CHFrameReader.decompress(frames, into: native) }
                try readBlocks(final: true)
            }
        } catch {
            decodeError = decodeError ?? error
        }
        // What's left after the last block: the server's error, if it wrote one.
        if let serverError = CHException.find(in: native.unread, tag: exceptionTag)
            ?? CHException.find(in: frames.unread, tag: exceptionTag)
            ?? plainError(in: native.unread) {
            continuation.finish(throwing: serverError)
            return
        }
        if let decodeError {
            continuation.finish(throwing: Self.clientError(decodeError))
            return
        }
        if frames.count > 0 {
            continuation.finish(throwing: CHClientError.truncated)
            return
        }
        let reached = maxRows.map { result.rowCount >= $0 } ?? false || maxBytes.map { result.byteCount >= $0 } ?? false
        continuation.yield(.finished(stats(reachedLimit: reached)))
        continuation.finish()
    }

    private func stats(reachedLimit: Bool) -> CHQueryStats {
        CHQueryStats(queryID: queryID, rows: result.rowCount, receivedBytes: receivedBytes, resultBytes: result.byteCount,
                     firstRows: firstRows, elapsed: ContinuousClock.now - started, reachedLimit: reachedLimit)
    }

    /// An older server's error after the rows: its text, `Code: …`.
    private func plainError(in bytes: UnsafeRawBufferPointer) -> CHServerError? {
        guard bytes.count >= 6 else { return nil }
        let text = String(decoding: bytes.suffix(64 * 1024), as: UTF8.self)
        if let range = text.range(of: "Code: "), text.contains("DB::Exception") || text.contains("Exception") {
            return CHServerError(text: String(text[range.lowerBound...]))
        }
        return nil
    }

    private static func clientError(_ error: Error) -> Error {
        switch error {
        case CHDecodeError.unsupportedType(let column, let type): CHClientError.unsupportedType(column: column, type: type)
        case CHDecodeError.needMoreData: CHClientError.truncated
        case CHDecodeError.malformed(let text): CHClientError.malformed(text)
        case CHFrameReader.Failure.unsupportedMethod(let method): CHClientError.malformed("compression method 0x\(String(method, radix: 16))")
        case CHFrameReader.Failure.malformed: CHClientError.malformed("a compressed frame")
        default: error
        }
    }
}

/// A query's session delegate: the response to its reader, the TLS challenge by the endpoint's trust.
final class CHQueryDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let trust: CHTrust
    private let reader: CHStreamReader
    var onStop: (() -> Void)? {
        get { reader.onStop }
        set { reader.onStop = newValue }
    }

    init(trust: CHTrust, reader: CHStreamReader) {
        self.trust = trust
        self.reader = reader
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        reader.receive(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        reader.receive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        reader.complete(error)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust, trust != .system else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if trust.evaluate(serverTrust) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// Writes a response into a file as it comes (Export), and finds the server's error at its end.
final class CHDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let trust: CHTrust
    private let handle: FileHandle
    private let progress: @Sendable (Int) -> Void
    private let continuation: CheckedContinuation<Int, Error>
    private var status = 0
    private var exceptionTag: String?
    private var body = Data()
    private var tail = Data()
    private var written = 0
    private var failure: Error?

    init(trust: CHTrust, handle: FileHandle, progress: @escaping @Sendable (Int) -> Void, continuation: CheckedContinuation<Int, Error>) {
        self.trust = trust
        self.handle = handle
        self.progress = progress
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        exceptionTag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-ClickHouse-Exception-Tag")
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard status == 200 else {
            if body.count < 1 << 20 { body.append(data) }
            return
        }
        guard failure == nil else { return }
        do {
            try handle.write(contentsOf: data)
            written += data.count
            tail.append(data)
            if tail.count > 1 << 16 { tail.removeFirst(tail.count - (1 << 15)) }
            progress(written)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle.close()
        session.finishTasksAndInvalidate()
        if let failure { return continuation.resume(throwing: failure) }
        if let error { return continuation.resume(throwing: error) }
        if status != 200 {
            let text = String(decoding: body.prefix(64 * 1024), as: UTF8.self)
            return continuation.resume(throwing: text.hasPrefix("Code: ") ? CHServerError(text: text)
                                       : CHClientError.unexpectedResponse(status: status, text: String(text.prefix(500))))
        }
        if let serverError = CHException.find(in: tail, tag: exceptionTag) { return continuation.resume(throwing: serverError) }
        continuation.resume(returning: written)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust, trust != .system else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        trust.evaluate(serverTrust) ? completionHandler(.useCredential, URLCredential(trust: serverTrust))
            : completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
