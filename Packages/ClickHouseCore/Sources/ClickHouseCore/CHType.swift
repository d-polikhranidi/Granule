import Foundation

/// A ClickHouse data type, as a result's header names it (`Nullable(String)`,
/// `DateTime64(3, 'Europe/Berlin')`, `Map(String, Array(UInt64))`), parsed
/// into what the decoder reads and how values are written as text.
public indirect enum CHType: Sendable, Hashable {
    case int8, int16, int32, int64, int128, int256
    case uint8, uint16, uint32, uint64, uint128, uint256
    case float32, float64, bfloat16
    case bool
    case string
    case fixedString(Int)
    case uuid, ipv4, ipv6
    /// Days since 1970 (UInt16; Date32: Int32).
    case date, date32
    /// Seconds since 1970 (UInt32), shown in the time zone the type names or
    /// the server's.
    case dateTime(timeZone: String?)
    /// Ticks of 10^-precision seconds since 1970 (Int64).
    case dateTime64(precision: Int, timeZone: String?)
    /// Seconds (Int32) and ticks of 10^-precision seconds (Int64) of a time of day or duration.
    case time
    case time64(precision: Int)
    /// An integer of 32, 64, 128 or 256 bits (by the precision) scaled by 10^-scale.
    case decimal(precision: Int, scale: Int)
    /// Int8 or Int16 values with their names.
    case enum8([CHEnumCase])
    case enum16([CHEnumCase])
    /// Intervals (Int64), with the unit's name (`IntervalSecond`).
    case interval(String)
    case nullable(CHType)
    case lowCardinality(CHType)
    case array(CHType)
    case tuple([CHTupleElement])
    case map(key: CHType, value: CHType)
    case variant([CHType])
    /// Values of any type, each with its type (read in the flattened layout).
    case dynamic
    /// JSON documents (read as their text: `output_format_native_write_json_as_string`).
    case json
    /// No values (`NULL` alone is `Nullable(Nothing)`).
    case nothing
    /// A type the viewer can't read: its whole name.
    case unsupported(String)

    /// The type of a type name; `unsupported` for what the viewer can't read.
    public init(parsing name: String) {
        var parser = CHTypeParser(name)
        self = (try? parser.parseWhole()) ?? .unsupported(name)
    }

    /// Whether the viewer can read its values (also of the types inside it).
    public var isReadable: Bool {
        switch self {
        case .unsupported: false
        case .nullable(let inner), .lowCardinality(let inner), .array(let inner): inner.isReadable
        case .tuple(let elements): elements.allSatisfy(\.type.isReadable)
        case .map(let key, let value): key.isReadable && value.isReadable
        case .variant(let types): types.allSatisfy(\.isReadable)
        default: true
        }
    }

    /// Whether it is or holds JSON.
    var containsJSON: Bool {
        switch self {
        case .json: true
        case .nullable(let inner), .lowCardinality(let inner), .array(let inner): inner.containsJSON
        case .tuple(let elements): elements.contains { $0.type.containsJSON }
        case .map(let key, let value): key.containsJSON || value.containsJSON
        case .variant(let types): types.contains(where: \.containsJSON)
        default: false
        }
    }

    /// The type without `Nullable` and `LowCardinality` around it.
    public var base: CHType {
        switch self {
        case .nullable(let inner), .lowCardinality(let inner): inner.base
        default: self
        }
    }

    /// Whether its values are numbers or times: they sort and sum as numbers.
    public var isNumeric: Bool {
        switch base {
        case .int8, .int16, .int32, .int64, .int128, .int256, .uint8, .uint16, .uint32, .uint64, .uint128, .uint256,
             .float32, .float64, .bfloat16, .decimal, .interval: true
        default: false
        }
    }

    /// Whether its values are dates, times or durations (sorted by time).
    public var isTemporal: Bool {
        switch base {
        case .date, .date32, .dateTime, .dateTime64, .time, .time64: true
        default: false
        }
    }

    /// Whether values sort as numbers (numbers, times, booleans, enums by value).
    public var sortsAsNumber: Bool {
        if isNumeric || isTemporal { return true }
        switch base {
        case .bool, .enum8, .enum16: return true
        default: return false
        }
    }
}

/// A name and value of an `Enum8`/`Enum16`.
public struct CHEnumCase: Sendable, Hashable {
    public var name: String
    public var value: Int
}

/// An element of a `Tuple`: its name in a named tuple, and its type.
public struct CHTupleElement: Sendable, Hashable {
    public var name: String?
    public var type: CHType
}

/// A type name parsed by recursive descent: `Name`, `Name(arguments)`, where
/// arguments are types, numbers, quoted strings, `'name' = value` (enums) or
/// `name Type` (named tuples, Nested).
struct CHTypeParser {
    private let text: [UInt8]
    private var at = 0

    struct Failure: Error {}

    init(_ name: String) {
        text = Array(name.utf8)
    }

    mutating func parseWhole() throws -> CHType {
        let type = try parseType()
        skipSpaces()
        guard at == text.count else { throw Failure() }
        return type
    }

    // MARK: Types

    private mutating func parseType() throws -> CHType {
        let start = at
        let name = try identifier()
        skipSpaces()
        let hasArguments = peek == UInt8(ascii: "(")
        switch name {
        case "Int8": return .int8
        case "Int16": return .int16
        case "Int32": return .int32
        case "Int64": return .int64
        case "Int128": return .int128
        case "Int256": return .int256
        case "UInt8": return .uint8
        case "UInt16": return .uint16
        case "UInt32": return .uint32
        case "UInt64": return .uint64
        case "UInt128": return .uint128
        case "UInt256": return .uint256
        case "Float32": return .float32
        case "Float64": return .float64
        case "BFloat16": return .bfloat16
        case "Bool": return .bool
        case "String": return .string
        case "UUID": return .uuid
        case "IPv4": return .ipv4
        case "IPv6": return .ipv6
        case "Date": return .date
        case "Date32": return .date32
        case "Nothing": return .nothing
        case "Time":
            return .time
        case "Dynamic":
            if hasArguments { try skipArguments() }
            return .dynamic
        case "JSON":
            if hasArguments { try skipArguments() }
            return .json
        case "FixedString":
            let arguments = try numberArguments()
            guard arguments.count == 1, arguments[0] > 0 else { throw Failure() }
            return .fixedString(arguments[0])
        case "DateTime":
            guard hasArguments else { return .dateTime(timeZone: nil) }
            try expect("(")
            let zone = try quoted()
            try expect(")")
            return .dateTime(timeZone: zone)
        case "DateTime64":
            try expect("(")
            let precision = try integer()
            var zone: String?
            skipSpaces()
            if peek == UInt8(ascii: ",") {
                at += 1
                zone = try quoted()
            }
            try expect(")")
            guard (0...9).contains(precision) else { throw Failure() }
            return .dateTime64(precision: precision, timeZone: zone)
        case "Time64":
            let arguments = try numberArguments()
            guard arguments.count == 1, (0...9).contains(arguments[0]) else { throw Failure() }
            return .time64(precision: arguments[0])
        case "Decimal":
            let arguments = try numberArguments()
            guard (1...2).contains(arguments.count), (1...76).contains(arguments[0]) else { throw Failure() }
            let scale = arguments.count == 2 ? arguments[1] : 0
            guard scale <= arguments[0] else { throw Failure() }
            return .decimal(precision: arguments[0], scale: scale)
        case "Decimal32", "Decimal64", "Decimal128", "Decimal256":
            let arguments = try numberArguments()
            guard arguments.count == 1 else { throw Failure() }
            let precision = ["Decimal32": 9, "Decimal64": 18, "Decimal128": 38, "Decimal256": 76][name] ?? 0
            return .decimal(precision: precision, scale: arguments[0])
        case "Enum8", "Enum16", "Enum":
            let cases = try enumCases()
            let wide = name == "Enum16" || (name == "Enum" && cases.contains { $0.value < -128 || $0.value > 127 })
            return wide ? .enum16(cases) : .enum8(cases)
        case "Nullable":
            return .nullable(try singleTypeArgument())
        case "LowCardinality":
            return .lowCardinality(try singleTypeArgument())
        case "Array":
            return .array(try singleTypeArgument())
        case "Map":
            let types = try typeArguments()
            guard types.count == 2 else { throw Failure() }
            return .map(key: types[0], value: types[1])
        case "Tuple":
            guard hasArguments else { return .tuple([]) }
            return .tuple(try tupleElements())
        case "Nested":
            return .array(.tuple(try tupleElements()))
        case "Variant":
            return .variant(try typeArguments())
        case "SimpleAggregateFunction":
            // The values are the type's: `SimpleAggregateFunction(sum, UInt64)`.
            try expect("(")
            _ = try identifier()
            try expect(",")
            let type = try parseType()
            try expect(")")
            return type
        // The geo types are tuples and arrays of points.
        case "Point": return .tuple([CHTupleElement(type: .float64), CHTupleElement(type: .float64)])
        case "Ring", "LineString": return .array(Self.point)
        case "Polygon", "MultiLineString": return .array(.array(Self.point))
        case "MultiPolygon": return .array(.array(.array(Self.point)))
        default:
            if name.hasPrefix("Interval") { return .interval(String(name.dropFirst("Interval".count))) }
            // AggregateFunction's states and others: their bytes have no
            // layout the viewer knows (it can't skip them either).
            if hasArguments { try skipArguments() }
            return .unsupported(String(decoding: text[start..<at], as: UTF8.self))
        }
    }

    private static let point = CHType.tuple([CHTupleElement(type: .float64), CHTupleElement(type: .float64)])

    private mutating func singleTypeArgument() throws -> CHType {
        let types = try typeArguments()
        guard types.count == 1 else { throw Failure() }
        return types[0]
    }

    private mutating func typeArguments() throws -> [CHType] {
        try expect("(")
        var types: [CHType] = []
        repeat {
            types.append(try parseType())
        } while try comma()
        try expect(")")
        return types
    }

    /// `Tuple(a UInt8, b String)` or `Tuple(UInt8, String)`.
    private mutating func tupleElements() throws -> [CHTupleElement] {
        try expect("(")
        var elements: [CHTupleElement] = []
        repeat {
            skipSpaces()
            // A name, then a type (a name is followed by a space, a type by "(", "," or ")").
            let mark = at
            let first = try identifier()
            skipSpaces()
            if let next = peek, next != UInt8(ascii: "("), next != UInt8(ascii: ","), next != UInt8(ascii: ")") {
                elements.append(CHTupleElement(name: first, type: try parseType()))
            } else {
                at = mark
                elements.append(CHTupleElement(name: nil, type: try parseType()))
            }
        } while try comma()
        try expect(")")
        return elements
    }

    private mutating func enumCases() throws -> [CHEnumCase] {
        try expect("(")
        var cases: [CHEnumCase] = []
        repeat {
            let name = try quoted()
            try expect("=")
            cases.append(CHEnumCase(name: name, value: try integer()))
        } while try comma()
        try expect(")")
        return cases
    }

    private mutating func numberArguments() throws -> [Int] {
        try expect("(")
        var numbers: [Int] = []
        repeat {
            numbers.append(try integer())
        } while try comma()
        try expect(")")
        return numbers
    }

    /// Arguments left unread (`JSON(max_dynamic_paths = 10, a.b UInt32)`), quotes and nesting kept apart.
    private mutating func skipArguments() throws {
        try expect("(")
        var depth = 1
        while at < text.count, depth > 0 {
            let byte = text[at]
            if byte == UInt8(ascii: "'") || byte == UInt8(ascii: "`") {
                _ = try quoted()
                continue
            }
            if byte == UInt8(ascii: "(") { depth += 1 }
            if byte == UInt8(ascii: ")") { depth -= 1 }
            at += 1
        }
        guard depth == 0 else { throw Failure() }
    }

    // MARK: Tokens

    private var peek: UInt8? { at < text.count ? text[at] : nil }

    private mutating func skipSpaces() {
        while at < text.count, text[at] == 0x20 || text[at] == 0x0A || text[at] == 0x09 { at += 1 }
    }

    private mutating func expect(_ character: Character) throws {
        skipSpaces()
        guard let ascii = character.asciiValue, peek == ascii else { throw Failure() }
        at += 1
    }

    /// A comma (and whether there was one).
    private mutating func comma() throws -> Bool {
        skipSpaces()
        guard peek == UInt8(ascii: ",") else { return false }
        at += 1
        return true
    }

    /// A name: letters, digits, `_` and `.`, or a back-quoted one.
    private mutating func identifier() throws -> String {
        skipSpaces()
        if peek == UInt8(ascii: "`") { return try quoted() }
        let start = at
        while at < text.count {
            let byte = text[at]
            let isName = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".") || byte >= 0x80
            guard isName else { break }
            at += 1
        }
        guard at > start else { throw Failure() }
        return String(decoding: text[start..<at], as: UTF8.self)
    }

    private mutating func integer() throws -> Int {
        skipSpaces()
        let start = at
        if peek == UInt8(ascii: "-") { at += 1 }
        while at < text.count, text[at] >= 0x30, text[at] <= 0x39 { at += 1 }
        guard let value = Int(String(decoding: text[start..<at], as: UTF8.self)) else { throw Failure() }
        return value
    }

    /// A string in single quotes or a name in back quotes, with backslash escapes.
    private mutating func quoted() throws -> String {
        skipSpaces()
        guard let quote = peek, quote == UInt8(ascii: "'") || quote == UInt8(ascii: "`") else { throw Failure() }
        at += 1
        var bytes: [UInt8] = []
        while at < text.count {
            let byte = text[at]
            at += 1
            if byte == UInt8(ascii: "\\"), at < text.count {
                bytes.append(Self.unescaped(text[at]))
                at += 1
            } else if byte == quote {
                // A doubled quote is one.
                if peek == quote {
                    bytes.append(quote)
                    at += 1
                } else {
                    return String(decoding: bytes, as: UTF8.self)
                }
            } else {
                bytes.append(byte)
            }
        }
        throw Failure()
    }

    private static func unescaped(_ byte: UInt8) -> UInt8 {
        switch byte {
        case UInt8(ascii: "n"): 0x0A
        case UInt8(ascii: "t"): 0x09
        case UInt8(ascii: "r"): 0x0D
        case UInt8(ascii: "0"): 0x00
        default: byte
        }
    }
}
