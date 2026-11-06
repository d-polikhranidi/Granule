import Foundation

/// Bytes of a decoded column, allocated once and never changed after the
/// decoder fills them: read on any thread.
public final class CHBuffer: @unchecked Sendable {
    public let base: UnsafeMutableRawPointer
    /// The bytes it holds.
    public let count: Int

    init(count: Int) {
        self.count = count
        // (16-byte aligned: Int128 and Int256 values, UUIDs.)
        base = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 16)
    }

    /// A copy of bytes.
    convenience init(copying bytes: UnsafeRawBufferPointer) {
        self.init(count: bytes.count)
        if let source = bytes.baseAddress, !bytes.isEmpty { base.copyMemory(from: source, byteCount: bytes.count) }
    }

    deinit { base.deallocate() }

    func pointer<T>(to type: T.Type) -> UnsafeMutablePointer<T> { base.assumingMemoryBound(to: type) }

    subscript<T>(_ type: T.Type, index: Int) -> T { base.load(fromByteOffset: index * MemoryLayout<T>.stride, as: type) }
}

/// A column of a result block as the viewer keeps it: values in arrays the
/// size of their type (ClickHouse's own layout, little-endian), strings'
/// bytes one after another with where each ends, composite types as columns
/// of their parts. Made once by the decoder; read on any thread.
public final class CHColumn: Sendable {
    public let type: CHType
    /// The values it holds.
    public let count: Int
    let storage: Storage

    enum Storage: Sendable {
        /// Values of a fixed size: numbers, dates, UUIDs, addresses, enums, FixedString.
        case fixed(CHBuffer, width: Int)
        /// Strings' bytes (`chars`) and where each ends in them (UInt32).
        case strings(ends: CHBuffer, chars: CHBuffer)
        /// Whether each value is NULL (UInt8), and the values (any under a NULL).
        case nullable(nulls: CHBuffer, values: CHColumn)
        /// The distinct values (for `LowCardinality(Nullable(T))`, 0 is NULL)
        /// and each row's (UInt32).
        case lowCardinality(dictionary: CHColumn, indexes: CHBuffer)
        /// Where each array ends in `elements` (UInt64), and the elements of all.
        case array(ends: CHBuffer, elements: CHColumn)
        /// The tuple's elements, a column each.
        case tuple([CHColumn])
        /// Each row's variant (UInt8; `nullDiscriminator` for NULL), its
        /// value's row in that variant's column (UInt32), and the columns.
        case variant(discriminators: CHBuffer, rows: CHBuffer, variants: [CHColumn], nullDiscriminator: Int)
        /// No values (`Nothing`).
        case nothing
    }

    init(type: CHType, count: Int, storage: Storage) {
        self.type = type
        self.count = count
        self.storage = storage
    }

    /// Whether a row's value is NULL.
    public func isNull(_ row: Int) -> Bool {
        switch storage {
        case .nullable(let nulls, _): return nulls[UInt8.self, row] != 0
        case .lowCardinality(_, let indexes):
            if case .nullable = type.lowCardinalityInner { return indexes[UInt32.self, row] == 0 }
            return false
        case .variant(let discriminators, _, _, let null): return Int(discriminators[UInt8.self, row]) == null
        case .nothing: return true
        default: return false
        }
    }

    /// The bytes of a string value (String, FixedString, JSON text) and of its
    /// dictionary's for LowCardinality: valid while the column is.
    func stringBytes(_ row: Int) -> UnsafeRawBufferPointer? {
        switch storage {
        case .strings(let ends, let chars):
            let end = Int(ends[UInt32.self, row])
            let start = row == 0 ? 0 : Int(ends[UInt32.self, row - 1])
            return UnsafeRawBufferPointer(start: chars.base + start, count: end - start)
        case .fixed(let buffer, let width):
            guard case .fixedString = type.base else { return nil }
            return UnsafeRawBufferPointer(start: buffer.base + row * width, count: width)
        case .nullable(_, let values): return values.stringBytes(row)
        case .lowCardinality(let dictionary, let indexes): return dictionary.stringBytes(Int(indexes[UInt32.self, row]))
        default: return nil
        }
    }

    /// The bytes it keeps, roughly (the memory a result takes).
    public var byteCount: Int {
        switch storage {
        case .fixed(let buffer, _): buffer.count
        case .strings(let ends, let chars): ends.count + chars.count
        case .nullable(let nulls, let values): nulls.count + values.byteCount
        case .lowCardinality(let dictionary, let indexes): dictionary.byteCount + indexes.count
        case .array(let ends, let elements): ends.count + elements.byteCount
        case .tuple(let elements): elements.reduce(0) { $0 + $1.byteCount }
        case .variant(let discriminators, let rows, let variants, _):
            discriminators.count + rows.count + variants.reduce(0) { $0 + $1.byteCount }
        case .nothing: 0
        }
    }
}

extension CHType {
    /// The type inside `LowCardinality` (self for others).
    var lowCardinalityInner: CHType {
        if case .lowCardinality(let inner) = self { return inner }
        return self
    }

    /// The size of a value of a fixed-size type, `nil` for others.
    var fixedWidth: Int? {
        switch self {
        case .int8, .uint8, .bool, .enum8: 1
        case .int16, .uint16, .bfloat16, .date, .enum16: 2
        case .int32, .uint32, .float32, .date32, .dateTime, .ipv4, .time: 4
        case .int64, .uint64, .float64, .dateTime64, .time64, .interval: 8
        case .int128, .uint128, .uuid, .ipv6: 16
        case .int256, .uint256: 32
        case .fixedString(let width): width
        case .decimal(let precision, _): precision <= 9 ? 4 : precision <= 18 ? 8 : precision <= 38 ? 16 : 32
        default: nil
        }
    }
}
