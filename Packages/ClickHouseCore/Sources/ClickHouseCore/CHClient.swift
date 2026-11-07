import Foundation

/// How a query runs: its id, session, parameters and the most of its result kept.
public struct CHQueryOptions: Sendable {
    /// The id the server knows it by (`KILL QUERY`, `system.query_log`).
    public var queryID = UUID().uuidString
    /// A session keeps `SET` and temporary tables between queries (one query at a time in it).
    public var sessionID: String?
    /// Values of the query's `{name:Type}` parameters, as text.
    public var parameters: [String: String] = [:]
    /// The rows and bytes kept of a result at most: the server stops there
    /// (`result_overflow_mode = break`). `nil`: no limit.
    public var maxRows: Int?
    public var maxBytes: Int?
    /// More settings for the query.
    public var settings: [String: String] = [:]
    /// The viewer's own query, not the user's: marked in `system.query_log`
    /// (`CHClient.backgroundComment`) so views of the log can leave it out.
    public var isBackground = false

    public init() {}
}

/// What a running query reports.
public enum CHQueryEvent: Sendable {
    /// The result so far: its header first, then each block's rows added.
    case result(CHResult)
    /// It's done.
    case finished(CHQueryStats)
}

/// A finished query's numbers, as the viewer measured them.
public struct CHQueryStats: Sendable {
    public var queryID: String
    public var rows: Int
    /// Bytes received (compressed) and kept (decoded).
    public var receivedBytes: Int
    public var resultBytes: Int
    /// From the request to the first block of rows, and to the end.
    public var firstRows: Duration?
    public var elapsed: Duration
    /// Whether the result stopped at the limit of rows or bytes kept.
    public var reachedLimit: Bool

    public init(queryID: String, rows: Int, receivedBytes: Int, resultBytes: Int, firstRows: Duration?, elapsed: Duration, reachedLimit: Bool) {
        self.queryID = queryID
        self.rows = rows
        self.receivedBytes = receivedBytes
        self.resultBytes = resultBytes
        self.firstRows = firstRows
        self.elapsed = elapsed
        self.reachedLimit = reachedLimit
    }
}

/// Why a query failed on the viewer's side.
public enum CHClientError: Error, Sendable, Equatable {
    case badURL
    /// The response wasn't ClickHouse's (a proxy's page, or no server there).
    case unexpectedResponse(status: Int, text: String)
    /// The result ended inside a block (the connection was cut).
    case truncated
    /// A column the viewer can't read (and can't skip).
    case unsupportedType(column: String, type: String)
    case malformed(String)
}

/// A ClickHouse server's HTTP interface: queries with their results read
/// as they come (Native blocks in ClickHouse's own LZ4 frames), small
/// queries for the viewer's own needs, cancelling by id.
public final class CHClient: Sendable {
    public let endpoint: CHEndpoint
    private let password: String
    /// What the server takes: set once connected (`connect()`).
    private let state = CHLocked(CHServerInfo?.none)
    /// Small queries (the server's info, schema, KILL): one session, connections kept.
    private let session: URLSession
    private let sessionDelegate: CHTrustDelegate

    /// The client certificate given to servers that ask for one.
    let identity: CHClientIdentity?

    /// The local port of a tunnel the server is reached through (`nil`: directly).
    private let tunnelPort = CHLocked<Int?>(nil)
    /// The tunnel itself, kept open while the client lives.
    private let tunnel = CHLocked<AnyObject?>(nil)

    public init(endpoint: CHEndpoint, password: String, identity: CHClientIdentity? = nil) {
        self.endpoint = endpoint
        self.password = password
        self.identity = identity
        let tunnelPort = tunnelPort
        let host = endpoint.host
        sessionDelegate = CHTrustDelegate(trust: endpoint.trust, identity: identity, hostname: { tunnelPort.value == nil ? nil : host })
        session = URLSession(configuration: Self.configuration(timeout: 60), delegate: sessionDelegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    static func configuration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        // A query may say nothing for minutes while it aggregates: no idle limit to speak of.
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.httpShouldUsePipelining = false
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return configuration
    }

    /// Reaches the server through a tunnel's local port from now on (`nil`: directly),
    /// keeping `tunnel` while the client lives. TLS still checks the server's own name.
    public func route(throughLocalPort port: Int?, keeping tunnel: AnyObject? = nil) {
        tunnelPort.value = port
        self.tunnel.value = tunnel
    }

    /// The server's HTTP interface as this client reaches it: directly, or a tunnel's local port.
    var baseURL: URL? {
        guard let port = tunnelPort.value else { return endpoint.url }
        var components = URLComponents()
        components.scheme = endpoint.isSecure ? "https" : "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/"
        return components.url
    }

    /// The name TLS checks the server's certificate for, when it isn't the URL's (a tunnel).
    var tlsHostname: String? { tunnelPort.value == nil ? nil : endpoint.host }

    /// The server's info, once connected.
    public var serverInfo: CHServerInfo? { state.value }

    // MARK: Connecting

    /// Reaches the server (waiting up to `timeout` for a sleeping Cloud
    /// service to wake), then learns its version, zone and the user's limits.
    @discardableResult
    public func connect(timeout: TimeInterval = 120) async throws -> CHServerInfo {
        guard let base = baseURL else { throw CHClientError.badURL }
        var ping = URLRequest(url: base.appending(path: "ping"))
        ping.timeoutInterval = timeout
        let (data, response) = try await session.data(for: ping)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CHClientError.unexpectedResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                                   text: String(decoding: data.prefix(500), as: UTF8.self))
        }
        let text = try await plainText("SELECT version(), timezone(), currentUser(), getSetting('readonly'), hostName() FORMAT TSV",
                                       settings: [:], database: nil)
        let fields = text.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        guard fields.count >= 5 else { throw CHClientError.unexpectedResponse(status: 200, text: text) }
        let info = CHServerInfo(version: CHVersion(fields[0]), timeZone: fields[1], user: fields[2],
                                readonly: Int(fields[3]) ?? 0, displayName: fields[4])
        state.value = info
        return info
    }

    // MARK: Requests

    /// The `log_comment` of the viewer's own queries (progress, checks, completion,
    /// schema, server views): `system.query_log` and `system.processes` keep it, so
    /// the server views leave them out and a DBA can tell them from the user's.
    public static let backgroundComment = "Granule: background"

    /// The request of a statement: the SQL in the body, settings in the URL.
    func request(_ sql: String, settings: [String: String], database: String?, queryID: String? = nil,
                 sessionID: String? = nil, parameters: [String: String] = [:], timeout: TimeInterval = 3600,
                 background: Bool = false) throws -> URLRequest {
        guard let base = baseURL, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw CHClientError.badURL
        }
        var settings = settings
        // A user with readonly = 1 may set nothing (and before connect() it isn't known yet).
        if let info = state.value, maySetSettings {
            if background { settings["log_comment"] = Self.backgroundComment }
            // A read-only connection writes nowhere: statements with their own FORMAT, Export and Kill
            // too, not only results (readonly = 2 refuses writes and still lets KILL and SET through).
            if endpoint.isReadOnly, info.readonly == 0, settings["readonly"] == nil { settings["readonly"] = "2" }
        }
        var items: [URLQueryItem] = []
        let database = database ?? (endpoint.database.isEmpty ? nil : endpoint.database)
        if let database { items.append(URLQueryItem(name: "database", value: database)) }
        if let queryID { items.append(URLQueryItem(name: "query_id", value: queryID)) }
        if let sessionID {
            items.append(URLQueryItem(name: "session_id", value: sessionID))
            items.append(URLQueryItem(name: "session_timeout", value: "3600"))
        }
        for (name, value) in settings.sorted(by: { $0.key < $1.key }) { items.append(URLQueryItem(name: name, value: value)) }
        for (name, value) in parameters.sorted(by: { $0.key < $1.key }) { items.append(URLQueryItem(name: "param_" + name, value: value)) }
        components.queryItems = items
        // "+" stays "+" in a query string: a setting's value must keep it.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw CHClientError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(sql.utf8)
        request.timeoutInterval = timeout
        request.setValue(endpoint.user, forHTTPHeaderField: "X-ClickHouse-User")
        if !password.isEmpty { request.setValue(password, forHTTPHeaderField: "X-ClickHouse-Key") }
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Whether requests may change settings: a user with `readonly = 1`
    /// may not (Code 164); the HTTP interface's own parameters still work
    /// (`default_format`, `compress`, `client_protocol_version`).
    var maySetSettings: Bool { (state.value?.readonly ?? 0) != 1 }

    /// Whether JSON columns come as their text (24.10+, when settings may be set).
    var readsJSONAsText: Bool { maySetSettings && (state.value?.version.isAtLeast(24, 10) ?? false) }

    /// The parameters and settings every result query gets: Native blocks
    /// (in LZ4 frames off the local network), the layouts the decoder reads,
    /// and for statements that only read, `readonly` (so closing the
    /// connection cancels them) and the most of the result kept.
    func resultSettings(for sql: String, options: CHQueryOptions) -> [String: String] {
        var settings: [String: String] = [
            "default_format": "Native",
            "client_protocol_version": String(CHNativeReader.revision),
        ]
        if endpoint.compressesResults {
            settings["compress"] = "1"
        }
        guard maySetSettings else { return settings }
        let info = state.value
        settings["enable_http_compression"] = "0"
        if endpoint.compressesResults { settings["network_compression_method"] = "LZ4" }
        if readsJSONAsText { settings["output_format_native_write_json_as_string"] = "1" }
        if let version = info?.version, version.isAtLeast(25, 6) {
            settings["output_format_native_use_flattened_dynamic_and_json_serialization"] = "1"
        }
        let reads = CHSQL.kind(of: sql) == .read
        if reads || endpoint.isReadOnly {
            // readonly = 2: reads only, settings still allowed (unless the user's own is 2 already).
            if (info?.readonly ?? 0) == 0 { settings["readonly"] = "2" }
            settings["cancel_http_readonly_queries_on_client_close"] = "1"
        }
        if reads {
            if let rows = options.maxRows { settings["max_result_rows"] = String(rows) }
            if let bytes = options.maxBytes { settings["max_result_bytes"] = String(bytes) }
            if options.maxRows != nil || options.maxBytes != nil { settings["result_overflow_mode"] = "break" }
        }
        settings.merge(options.settings) { _, own in own }
        return settings
    }

    // MARK: Queries

    /// Runs a statement and reads its result as it comes: `.result` with the
    /// rows so far after each block, then `.finished`. Ending the iteration
    /// early (or cancelling its task) cancels the query: the connection is
    /// closed and the server told to kill it.
    public func execute(_ sql: String, options: CHQueryOptions = CHQueryOptions()) -> AsyncThrowingStream<CHQueryEvent, Error> {
        AsyncThrowingStream { continuation in
            var request: URLRequest
            do {
                let settings = resultSettings(for: sql, options: options)
                request = try self.request(sql, settings: settings, database: nil, queryID: options.queryID,
                                           sessionID: options.sessionID, parameters: options.parameters, background: options.isBackground)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            // No HTTP compression on top (a user with readonly = 1 can't turn it off by a setting).
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let reader = CHStreamReader(queryID: options.queryID, maxRows: options.maxRows, maxBytes: options.maxBytes,
                                        compressed: endpoint.compressesResults, jsonAsText: readsJSONAsText, continuation: continuation)
            let delegate = CHQueryDelegate(trust: endpoint.trust, identity: identity, hostname: tlsHostname, reader: reader)
            // A session of its own: its results are read on its own queue.
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            let session = URLSession(configuration: Self.configuration(timeout: 3600), delegate: delegate, delegateQueue: queue)
            let task = session.dataTask(with: request)
            delegate.onStop = { [weak task] in task?.cancel() }
            continuation.onTermination = { [weak self] termination in
                task.cancel()
                session.finishTasksAndInvalidate()
                if case .cancelled = termination, !reader.isFinished, let self {
                    Task { try? await self.kill(queryID: options.queryID) }
                }
            }
            task.resume()
        }
    }

    /// A whole result, for the viewer's own small queries (schema, server state):
    /// marked as the viewer's own unless `background` is false.
    public func result(_ sql: String, settings: [String: String] = [:], background: Bool = true) async throws -> CHResult {
        var options = CHQueryOptions()
        options.settings = settings
        options.isBackground = background
        var result = CHResult()
        for try await event in execute(sql, options: options) {
            if case .result(let current) = event { result = current }
        }
        return result
    }

    /// A statement's result as the server writes it (its own `FORMAT`), as text.
    public func plainText(_ sql: String, settings: [String: String] = [:], database: String? = nil,
                          queryID: String? = nil, sessionID: String? = nil, background: Bool = false) async throws -> String {
        let request = try request(sql, settings: settings, database: database, queryID: queryID, sessionID: sessionID, background: background)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        let text = String(decoding: data, as: UTF8.self)
        if let error = CHException.find(in: data, tag: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-ClickHouse-Exception-Tag")) {
            throw error
        }
        return text
    }

    /// A statement's result written by the server in `format` (CSV, Parquet, …)
    /// into a file, as it comes: Export. Returns the bytes written.
    public func download(_ sql: String, format: String, to file: URL, parameters: [String: String] = [:],
                         progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> Int {
        // The server's own compression over a slow network (URLSession decodes gzip and Brotli).
        var settings = ["default_format": format]
        if maySetSettings { settings["enable_http_compression"] = "1" }
        let request = try request(sql, settings: settings, database: nil, parameters: parameters)
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: file)
        let trust = endpoint.trust
        let holder = CHLocked<URLSessionDataTask?>(nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = CHDownloadDelegate(trust: trust, identity: self.identity, hostname: self.tlsHostname, handle: handle, progress: progress,
                                                  continuation: continuation)
                let session = URLSession(configuration: Self.configuration(timeout: 3600), delegate: delegate, delegateQueue: nil)
                let task = session.dataTask(with: request)
                holder.value = task
                task.resume()
            }
        } onCancel: {
            holder.value?.cancel()
        }
    }

    /// Asks the server to stop a query (`KILL QUERY … ASYNC`).
    public func kill(queryID: String) async throws {
        _ = try await plainText("KILL QUERY WHERE query_id = \(CHSQL.quotedString(queryID)) ASYNC FORMAT Null", background: true)
    }

    /// A response with an error status: the server's error, or what came instead.
    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw CHClientError.unexpectedResponse(status: 0, text: "") }
        guard http.statusCode != 200 else { return }
        let text = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        if http.value(forHTTPHeaderField: "X-ClickHouse-Exception-Code") != nil || text.hasPrefix("Code: ") {
            throw CHServerError(text: text)
        }
        throw CHClientError.unexpectedResponse(status: http.statusCode, text: String(text.prefix(500)))
    }
}

/// The text of an error the server wrote after the result had begun: a
/// status of 200, then `\r\n__exception__\r\n<tag>\r\n<message>\n<length> <tag>\r\n__exception__\r\n`
/// at the end (older servers: the message, `Code: …`, after the rows).
enum CHException {
    static func find(in bytes: some Collection<UInt8>, tag: String?) -> CHServerError? {
        let tail = Array(bytes.suffix(64 * 1024))
        let marker = Array("__exception__".utf8)
        guard let last = lastRange(of: marker, in: tail) else { return nil }
        // The opening marker, if the tail has it: the message is after its tag line.
        let before = Array(tail[..<last.lowerBound])
        var start = 0
        if let first = lastRange(of: marker, in: before) {
            start = first.upperBound
            // \r\n<tag>\r\n
            var lines = 0
            while start < before.count, lines < 2 {
                if before[start] == 0x0A { lines += 1 }
                start += 1
            }
            if tag == nil { start = min(start, before.count) }
        }
        var message = String(decoding: before[min(start, before.count)...], as: UTF8.self)
        // The last line is "<length> <tag>".
        if let lastLine = message.trimmingCharacters(in: .newlines).range(of: "\n", options: .backwards) {
            message = String(message[..<lastLine.lowerBound])
        }
        return CHServerError(text: message)
    }

    private static func lastRange(of pattern: [UInt8], in bytes: [UInt8]) -> Range<Int>? {
        guard bytes.count >= pattern.count else { return nil }
        var index = bytes.count - pattern.count
        while index >= 0 {
            if bytes[index] == pattern[0], Array(bytes[index..<(index + pattern.count)]) == pattern { return index..<(index + pattern.count) }
            index -= 1
        }
        return nil
    }
}

/// A value behind a lock.
final class CHLocked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result { lock.withLock { body(&stored) } }
}

/// Answers the server's TLS challenges by the endpoint's trust and our client certificate.
final class CHTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let trust: CHTrust
    let identity: CHClientIdentity?
    let hostname: @Sendable () -> String?

    init(trust: CHTrust, identity: CHClientIdentity?, hostname: @escaping @Sendable () -> String?) {
        self.trust = trust
        self.identity = identity
        self.hostname = hostname
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        CHAuthentication.answer(challenge, trust: trust, identity: identity, hostname: hostname())
    }
}
