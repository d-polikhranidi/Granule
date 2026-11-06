import Compression
import Foundation

/// Bytes kept while more come: appended at the end, read from the front.
final class CHByteQueue {
    private var storage: UnsafeMutableRawPointer
    private var capacity: Int
    /// Where the unread bytes start and end.
    private var start = 0
    private var end = 0

    init(capacity: Int = 1 << 20) {
        self.capacity = capacity
        storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    }

    deinit { storage.deallocate() }

    /// The unread bytes.
    var count: Int { end - start }

    var unread: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: storage + start, count: end - start) }

    /// Room for `count` more bytes at the end: the place to write them, then `didWrite`.
    func reserve(_ count: Int) -> UnsafeMutableRawPointer {
        if end + count > capacity {
            let unreadCount = end - start
            if unreadCount + count <= capacity / 2 {
                // Enough room once the read bytes go: move the rest to the front.
                storage.copyMemory(from: storage + start, byteCount: unreadCount)
            } else {
                var grown = capacity * 2
                while grown < unreadCount + count { grown *= 2 }
                let larger = UnsafeMutableRawPointer.allocate(byteCount: grown, alignment: 16)
                larger.copyMemory(from: storage + start, byteCount: unreadCount)
                storage.deallocate()
                storage = larger
                capacity = grown
            }
            start = 0
            end = unreadCount
        }
        return storage + end
    }

    func didWrite(_ count: Int) { end += count }

    func append(_ bytes: UnsafeRawBufferPointer) {
        guard let source = bytes.baseAddress, !bytes.isEmpty else { return }
        reserve(bytes.count).copyMemory(from: source, byteCount: bytes.count)
        didWrite(bytes.count)
    }

    /// The first `count` unread bytes are read.
    func consume(_ count: Int) {
        start += count
        if start == end {
            start = 0
            end = 0
        }
    }
}

/// Reads ClickHouse's own compressed frames (`compress=1`): each is a 16-byte
/// checksum, a method byte, the frame's size with its 9-byte header, the
/// size of its bytes uncompressed, then the bytes (LZ4 blocks: the
/// Compression framework's raw LZ4).
struct CHFrameReader {
    enum Failure: Error, Equatable {
        /// A method other than none and LZ4 (ZSTD: Apple has no decoder).
        case unsupportedMethod(UInt8)
        case malformed
    }

    /// Frames decompressed from `input` into `output` while whole ones are
    /// there; the bytes of a frame not yet whole stay in `input`.
    static func decompress(_ input: CHByteQueue, into output: CHByteQueue) throws {
        while input.count >= 25 {
            let bytes = input.unread
            let method = bytes[16]
            let compressedSize = Int(bytes.loadUnaligned(fromByteOffset: 17, as: UInt32.self))
            let size = Int(bytes.loadUnaligned(fromByteOffset: 21, as: UInt32.self))
            guard compressedSize >= 9, size <= 1 << 30 else { throw Failure.malformed }
            let frame = 16 + compressedSize
            guard bytes.count >= frame else { return }
            let payload = UnsafeRawBufferPointer(rebasing: bytes[25..<frame])
            switch method {
            case 0x02:
                guard payload.count == size else { throw Failure.malformed }
                output.append(payload)
            case 0x82:
                let target = output.reserve(size).assumingMemoryBound(to: UInt8.self)
                let written = compression_decode_buffer(target, size, payload.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                                                        nil, COMPRESSION_LZ4_RAW)
                guard written == size else { throw Failure.malformed }
                output.didWrite(size)
            default:
                throw Failure.unsupportedMethod(method)
            }
            input.consume(frame)
        }
    }

    /// Whether bytes start like a frame (an error's text before any frame doesn't).
    static func looksLikeFrame(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard bytes.count >= 25 else { return false }
        let method = bytes[16]
        let compressedSize = Int(bytes.loadUnaligned(fromByteOffset: 17, as: UInt32.self))
        return (method == 0x02 || method == 0x82 || method == 0x90) && compressedSize >= 9 && compressedSize < 1 << 30
    }
}
