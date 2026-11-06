import CHDecode
import Foundation

/// A block of a result: some rows of every column, as ClickHouse sent them.
public struct CHBlock: Sendable {
    /// The columns' names and types, as the header has them.
    public let names: [String]
    public let typeNames: [String]
    public let types: [CHType]
    public let rowCount: Int
    /// The columns' values (none in a block of no rows: a result's header).
    public let columns: [CHColumn]

    /// The bytes its columns keep, roughly.
    public var byteCount: Int { columns.reduce(0) { $0 + $1.byteCount } }
}

/// Why a result couldn't be read.
public enum CHDecodeError: Error, Sendable, Equatable {
    /// The bytes end inside a block (more are coming, or the result was cut).
    case needMoreData
    /// A column of a type whose bytes the viewer can't read (nor skip):
    /// `AggregateFunction` states and the like.
    case unsupportedType(column: String, type: String)
    /// Bytes that aren't a Native block.
    case malformed(String)
}

/// Reads blocks of ClickHouse's Native format, as the HTTP interface sends
/// it to a client of `revision` (`client_protocol_version`): a block is its
/// info (revisions above 0), the column and row counts, then each column's
/// name, type name and values, column after column. Values are copied out
/// of the bytes read, so those can go.
struct CHNativeReader {
    /// The revision the viewer asks for: the first with time zones in
    /// `DateTime`'s type (54337; below it they're left out), the last before
    /// columns' custom serializations (54454) and the layouts after them
    /// (Dynamic and JSON V2, strings with a stream of sizes).
    static let revision = 54453

    private let bytes: UnsafeRawBufferPointer
    private let hasBlockInfo: Bool
    /// Where the next byte is read.
    private(set) var offset = 0

    init(_ bytes: UnsafeRawBufferPointer, revision: Int = CHNativeReader.revision) {
        self.bytes = bytes
        hasBlockInfo = revision > 0
    }

    /// Whether every byte has been read.
    var isAtEnd: Bool { offset >= bytes.count }

    /// The next block; `needMoreData` (and the offset unchanged) if the bytes end inside it.
    mutating func readBlock() throws -> CHBlock {
        let start = offset
        do {
            if hasBlockInfo { try skipBlockInfo() }
            let columnCount = try Int(checking: readVarUInt())
            let rowCount = try Int(checking: readVarUInt())
            var names: [String] = [], typeNames: [String] = [], types: [CHType] = [], columns: [CHColumn] = []
            names.reserveCapacity(columnCount)
            for _ in 0..<columnCount {
                let name = try readString()
                let typeName = try readString()
                let type = CHType(parsing: typeName)
                guard type.isReadable else { throw CHDecodeError.unsupportedType(column: name, type: typeName) }
                names.append(name)
                typeNames.append(typeName)
                types.append(type)
                if rowCount > 0 {
                    let prefix = try readPrefix(type)
                    columns.append(try readColumn(type, prefix: prefix, rows: rowCount))
                }
            }
            return CHBlock(names: names, typeNames: typeNames, types: types, rowCount: rowCount, columns: columns)
        } catch {
            offset = start
            throw error
        }
    }

    /// The block's info: fields by number, then 0 (1: is_overflows, a byte;
    /// 2: bucket_num, Int32).
    private mutating func skipBlockInfo() throws {
        while true {
            switch try readVarUInt() {
            case 0: return
            case 1: _ = try take(1)
            case 2: _ = try take(4)
            case let field: throw CHDecodeError.malformed("block info field \(field)")
            }
        }
    }

    // MARK: Prefixes

    /// What a column's data starts with before its values, for the whole
    /// column (its parts' come first, in order).
    private indirect enum Prefix {
        case none
        case parts([Prefix])
        /// Dynamic's types, read from its prefix, and their prefixes; the
        /// discriminator of NULL; whether it's the flattened layout.
        case dynamic(types: [CHType], parts: [Prefix], flattened: Bool)
    }

    private mutating func readPrefix(_ type: CHType) throws -> Prefix {
        switch type {
        case .lowCardinality:
            // The keys' version: 1, shared dictionaries with additional keys.
            let version = try readUInt64()
            guard version == 1 else { throw CHDecodeError.malformed("LowCardinality version \(version)") }
            return .none
        case .nullable(let inner), .array(let inner):
            return try readPrefix(inner)
        case .map(let key, let value):
            return .parts([try readPrefix(key), try readPrefix(value)])
        case .tuple(let elements):
            return .parts(try elements.map { try readPrefix($0.type) })
        case .variant(let types):
            let mode = try readUInt64()
            guard mode == 0 else { throw CHDecodeError.malformed("Variant discriminators mode \(mode)") }
            return .parts(try types.map { try readPrefix($0) })
        case .json:
            // As text: version 1, then a String column.
            _ = try readUInt64()
            return .none
        case .dynamic:
            let version = try readUInt64()
            switch version {
            case 3:
                // Flattened: the types, then each one's values on their own.
                let count = try Int(checking: readVarUInt())
                let types = try (0..<count).map { _ in try Self.readableType(readString()) }
                return .dynamic(types: types, parts: try types.map { try readPrefix($0) }, flattened: true)
            case 1:
                // V1: the types, then a Variant of them and the shared variant (sorted by name).
                _ = try readVarUInt()
                let count = try Int(checking: readVarUInt())
                var names = try (0..<count).map { _ in try readString() }
                names.append("SharedVariant")
                names.sort()
                let types = try names.map { $0 == "SharedVariant" ? CHType.string : try Self.readableType($0) }
                let mode = try readUInt64()
                guard mode == 0 else { throw CHDecodeError.malformed("Dynamic discriminators mode \(mode)") }
                return .dynamic(types: types, parts: try types.map { try readPrefix($0) }, flattened: false)
            default:
                throw CHDecodeError.malformed("Dynamic version \(version)")
            }
        default:
            return .none
        }
    }

    private static func readableType(_ name: String) throws -> CHType {
        let type = CHType(parsing: name)
        guard type.isReadable else { throw CHDecodeError.unsupportedType(column: "Dynamic", type: name) }
        return type
    }

    // MARK: Values

    private mutating func readColumn(_ type: CHType, prefix: Prefix, rows: Int) throws -> CHColumn {
        if let width = type.fixedWidth {
            let buffer = CHBuffer(copying: try take(rows * width))
            return CHColumn(type: type, count: rows, storage: .fixed(buffer, width: width))
        }
        switch type {
        case .string, .json:
            return try readStrings(type, rows: rows)
        case .nullable(let inner):
            let nulls = CHBuffer(copying: try take(rows))
            let values = try readColumn(inner, prefix: prefix, rows: rows)
            return CHColumn(type: type, count: rows, storage: .nullable(nulls: nulls, values: values))
        case .lowCardinality(let inner):
            return try readLowCardinality(type, inner: inner, rows: rows)
        case .array(let inner):
            let ends = CHBuffer(copying: try take(rows * 8))
            let total = rows == 0 ? 0 : try Int(checking: ends[UInt64.self, rows - 1])
            let elements = try readColumn(inner, prefix: prefix, rows: total)
            return CHColumn(type: type, count: rows, storage: .array(ends: ends, elements: elements))
        case .map(let key, let value):
            let ends = CHBuffer(copying: try take(rows * 8))
            let total = rows == 0 ? 0 : try Int(checking: ends[UInt64.self, rows - 1])
            guard case .parts(let parts) = prefix, parts.count == 2 else { throw CHDecodeError.malformed("Map prefix") }
            let keys = try readColumn(key, prefix: parts[0], rows: total)
            let values = try readColumn(value, prefix: parts[1], rows: total)
            let pairs = CHColumn(type: .tuple([CHTupleElement(type: key), CHTupleElement(type: value)]), count: total,
                                 storage: .tuple([keys, values]))
            return CHColumn(type: type, count: rows, storage: .array(ends: ends, elements: pairs))
        case .tuple(let elements):
            guard case .parts(let parts) = prefix, parts.count == elements.count else { throw CHDecodeError.malformed("Tuple prefix") }
            var columns: [CHColumn] = []
            for (element, part) in zip(elements, parts) {
                columns.append(try readColumn(element.type, prefix: part, rows: rows))
            }
            return CHColumn(type: type, count: rows, storage: .tuple(columns))
        case .variant(let types):
            guard case .parts(let parts) = prefix, parts.count == types.count else { throw CHDecodeError.malformed("Variant prefix") }
            let discriminators = CHBuffer(copying: try take(rows))
            return try readVariants(type, types: types, parts: parts, discriminators: discriminators, null: 255, rows: rows)
        case .dynamic:
            guard case .dynamic(let types, let parts, let flattened) = prefix else { throw CHDecodeError.malformed("Dynamic prefix") }
            let discriminators: CHBuffer
            if flattened, types.count + 1 > 256 {
                // Discriminators wider than a byte (more than 255 types): not kept as such.
                throw CHDecodeError.unsupportedType(column: "Dynamic", type: "Dynamic of \(types.count) types")
            } else {
                discriminators = CHBuffer(copying: try take(rows))
            }
            return try readVariants(type, types: types, parts: parts, discriminators: discriminators,
                                    null: flattened ? types.count : 255, rows: rows)
        case .nothing:
            _ = try take(rows)
            return CHColumn(type: type, count: rows, storage: .nothing)
        default:
            throw CHDecodeError.unsupportedType(column: "", type: "\(type)")
        }
    }

    private mutating func readStrings(_ type: CHType, rows: Int) throws -> CHColumn {
        let rest = UnsafeRawBufferPointer(rebasing: bytes[offset...])
        let source = rest.bindMemory(to: UInt8.self)
        var total = 0
        let used = ch_scan_strings(source.baseAddress, source.count, rows, &total)
        guard used >= 0 else { throw CHDecodeError.needMoreData }
        guard total < Int(UInt32.max) else { throw CHDecodeError.malformed("a block's strings are over 4 GB") }
        let ends = CHBuffer(count: rows * 4)
        let chars = CHBuffer(count: total)
        ch_copy_strings(source.baseAddress, rows, chars.pointer(to: UInt8.self), ends.pointer(to: UInt32.self), 0)
        offset += Int(used)
        return CHColumn(type: type, count: rows, storage: .strings(ends: ends, chars: chars))
    }

    /// LowCardinality: in parts, each with its dictionary (the additional
    /// keys) and the rows' indexes in it; the dictionaries joined into one.
    private mutating func readLowCardinality(_ type: CHType, inner: CHType, rows: Int) throws -> CHColumn {
        let valueType = inner.base
        let indexes = CHBuffer(count: rows * 4)
        let target = indexes.pointer(to: UInt32.self)
        var dictionaries: [CHColumn] = []
        var dictionaryBase = 0, current = 0, done = 0
        while done < rows {
            let serialization = try readUInt64()
            let indexWidth = 1 << Int(serialization & 0xFF)
            guard indexWidth <= 8, serialization & (1 << 8) == 0 else {
                throw CHDecodeError.malformed("LowCardinality serialization \(serialization)")
            }
            if serialization & (1 << 9) != 0 {
                let keys = try Int(checking: readUInt64())
                let dictionary = try readColumn(valueType, prefix: .none, rows: keys)
                dictionaryBase = dictionaries.reduce(0) { $0 + $1.count }
                dictionaries.append(dictionary)
                current = dictionaries.count - 1
            }
            guard !dictionaries.isEmpty else { throw CHDecodeError.malformed("LowCardinality without keys") }
            let count = try Int(checking: readUInt64())
            guard count > 0, count <= rows - done else { throw CHDecodeError.malformed("LowCardinality of \(count) rows") }
            let raw = try take(count * indexWidth)
            let limit = dictionaries[current].count
            for i in 0..<count {
                let index: Int = switch indexWidth {
                case 1: Int(raw.load(fromByteOffset: i, as: UInt8.self))
                case 2: Int(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                case 4: Int(raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                default: Int(truncatingIfNeeded: raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self))
                }
                guard index < limit else { throw CHDecodeError.malformed("LowCardinality index \(index) of \(limit)") }
                target[done + i] = UInt32(dictionaryBase + index)
            }
            done += count
        }
        let dictionary = try dictionaries.count == 1 ? dictionaries[0] : Self.joined(dictionaries, type: valueType)
        return CHColumn(type: type, count: rows, storage: .lowCardinality(dictionary: dictionary, indexes: indexes))
    }

    /// Columns of strings or fixed-size values one after another.
    private static func joined(_ columns: [CHColumn], type: CHType) throws -> CHColumn {
        let count = columns.reduce(0) { $0 + $1.count }
        if let width = type.fixedWidth {
            let buffer = CHBuffer(count: count * width)
            var at = 0
            for column in columns {
                guard case .fixed(let part, _) = column.storage else { throw CHDecodeError.malformed("LowCardinality keys") }
                (buffer.base + at).copyMemory(from: part.base, byteCount: part.count)
                at += part.count
            }
            return CHColumn(type: type, count: count, storage: .fixed(buffer, width: width))
        }
        var totalChars = 0
        for column in columns {
            guard case .strings(_, let chars) = column.storage else { throw CHDecodeError.malformed("LowCardinality keys") }
            totalChars += chars.count
        }
        let ends = CHBuffer(count: count * 4), chars = CHBuffer(count: totalChars)
        var row = 0, base = 0
        for column in columns {
            guard case .strings(let partEnds, let partChars) = column.storage else { continue }
            (chars.base + base).copyMemory(from: partChars.base, byteCount: partChars.count)
            for i in 0..<column.count { ends.pointer(to: UInt32.self)[row + i] = UInt32(base) + partEnds[UInt32.self, i] }
            row += column.count
            base += partChars.count
        }
        return CHColumn(type: type, count: count, storage: .strings(ends: ends, chars: chars))
    }

    /// Variant and Dynamic: each row's discriminator, then each variant's
    /// values (as many as rows of it) in a column of their own.
    private mutating func readVariants(_ type: CHType, types: [CHType], parts: [Prefix], discriminators: CHBuffer,
                                       null: Int, rows: Int) throws -> CHColumn {
        var counts = [Int](repeating: 0, count: types.count)
        let rowsInVariant = CHBuffer(count: rows * 4)
        let kinds = discriminators.pointer(to: UInt8.self), targets = rowsInVariant.pointer(to: UInt32.self)
        for row in 0..<rows {
            let kind = Int(kinds[row])
            if kind == null {
                targets[row] = 0
                continue
            }
            guard kind < types.count else { throw CHDecodeError.malformed("variant \(kind) of \(types.count)") }
            targets[row] = UInt32(counts[kind])
            counts[kind] += 1
        }
        var variants: [CHColumn] = []
        for (index, variantType) in types.enumerated() {
            variants.append(try readColumn(variantType, prefix: parts[index], rows: counts[index]))
        }
        return CHColumn(type: type, count: rows,
                        storage: .variant(discriminators: discriminators, rows: rowsInVariant, variants: variants, nullDiscriminator: null))
    }

    // MARK: Bytes

    private mutating func take(_ count: Int) throws -> UnsafeRawBufferPointer {
        guard count >= 0, count <= bytes.count - offset else { throw CHDecodeError.needMoreData }
        defer { offset += count }
        return UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + count)])
    }

    private mutating func readUInt64() throws -> UInt64 {
        try take(8).loadUnaligned(as: UInt64.self)
    }

    private mutating func readVarUInt() throws -> UInt64 {
        var value: UInt64 = 0
        let rest = UnsafeRawBufferPointer(rebasing: bytes[offset...]).bindMemory(to: UInt8.self)
        let used = ch_read_varuint(rest.baseAddress, rest.count, &value)
        guard used > 0 else {
            if rest.count >= 10 { throw CHDecodeError.malformed("a VarUInt over 10 bytes") }
            throw CHDecodeError.needMoreData
        }
        offset += Int(used)
        return value
    }

    private mutating func readString() throws -> String {
        let length = try Int(checking: readVarUInt())
        guard length < 1 << 20 else { throw CHDecodeError.malformed("a name of \(length) bytes") }
        return String(decoding: try take(length), as: UTF8.self)
    }
}

extension Int {
    /// A count from the bytes: not one that can't be (a sign of bytes that aren't Native).
    init(checking value: UInt64) throws {
        guard value < UInt64(1) << 40 else { throw CHDecodeError.malformed("a count of \(value)") }
        self = Int(value)
    }
}
