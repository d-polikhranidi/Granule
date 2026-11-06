import CHDecode
import Foundation

/// What writing values as text needs beyond the values: the time zone of
/// times whose type names none (the server's, or the session's), and the
/// offsets of the zones met so far. One per batch of rows on a thread: its
/// caches aren't shared.
public final class CHTextContext {
    /// The zone of `DateTime` and `DateTime64` values without one in their type.
    public let defaultTimeZone: TimeZone
    private var zones: [String: CHZoneOffsets] = [:]
    private let defaultOffsets: CHZoneOffsets

    public init(defaultTimeZone: TimeZone) {
        self.defaultTimeZone = defaultTimeZone
        defaultOffsets = CHZoneOffsets(defaultTimeZone)
    }

    /// The offsets of a zone the type names (the default zone's for `nil`
    /// or a name the system doesn't know).
    func offsets(_ name: String?) -> CHZoneOffsets {
        guard let name else { return defaultOffsets }
        if let known = zones[name] { return known }
        let offsets = TimeZone(identifier: name).map(CHZoneOffsets.init) ?? defaultOffsets
        zones[name] = offsets
        return offsets
    }
}

/// A zone's offset from UTC at an instant, kept by quarter hour: zones
/// change their offsets only at whole quarter hours.
final class CHZoneOffsets {
    private let zone: TimeZone
    private let fixed: Int?
    private var buckets = [Int64](repeating: .min, count: 256)
    private var offsets = [Int32](repeating: 0, count: 256)

    init(_ zone: TimeZone) {
        self.zone = zone
        // UTC and zones without daylight saving time have one offset.
        let now = Date()
        fixed = zone.nextDaylightSavingTimeTransition(after: Date(timeIntervalSince1970: -2_208_988_800)) == nil
            ? zone.secondsFromGMT(for: now) : nil
    }

    func offset(at seconds: Int64) -> Int64 {
        if let fixed { return Int64(fixed) }
        let bucket = seconds >= 0 ? seconds / 900 : (seconds - 899) / 900
        let slot = Int(truncatingIfNeeded: bucket) & 255
        if buckets[slot] == bucket { return Int64(offsets[slot]) }
        let offset = zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(bucket * 900)))
        buckets[slot] = bucket
        offsets[slot] = Int32(offset)
        return Int64(offset)
    }
}

extension CHColumn {
    /// A row's value as ClickHouse writes it in a result's text (`TSVRaw`):
    /// strings as they are, `NULL` for none, composite values with their
    /// strings quoted.
    public func text(_ row: Int, context: CHTextContext) -> String {
        if let bytes = topLevelStringBytes(row) { return String(decoding: bytes, as: UTF8.self) }
        var writer = CHTextWriter()
        writer.write(self, row: row, quoted: false, context: context)
        return writer.string
    }

    /// A row's text as UTF-8 for `body`, without a copy for strings (valid
    /// while `body` runs); NULL as no text.
    public func withText<Result>(_ row: Int, context: CHTextContext, writer: inout CHTextWriter,
                                 _ body: (UnsafeRawBufferPointer) -> Result) -> Result {
        if isNull(row) { return body(UnsafeRawBufferPointer(start: nil, count: 0)) }
        if let bytes = topLevelStringBytes(row) { return body(bytes) }
        writer.removeAll()
        writer.write(self, row: row, quoted: false, context: context)
        return writer.withBytes(body)
    }

    /// A string's own bytes at the top level (a FixedString without its trailing zeros).
    private func topLevelStringBytes(_ row: Int) -> UnsafeRawBufferPointer? {
        switch type.base {
        case .string, .json:
            guard !isNull(row) else { return nil }
            return stringBytes(row)
        case .fixedString:
            guard !isNull(row), var bytes = stringBytes(row) else { return nil }
            while let last = bytes.last, last == 0 { bytes = UnsafeRawBufferPointer(rebasing: bytes.dropLast()) }
            return bytes
        default:
            return nil
        }
    }
}

/// Writes values as text, into bytes it keeps between values.
public struct CHTextWriter {
    private var bytes: [UInt8] = []

    public init() {
        bytes.reserveCapacity(256)
    }

    var string: String { String(decoding: bytes, as: UTF8.self) }

    mutating func removeAll() { bytes.removeAll(keepingCapacity: true) }

    func withBytes<Result>(_ body: (UnsafeRawBufferPointer) -> Result) -> Result {
        bytes.withUnsafeBytes(body)
    }

    private mutating func append(_ text: StaticString) {
        text.withUTF8Buffer { bytes.append(contentsOf: $0) }
    }

    private mutating func append(_ byte: UInt8) { bytes.append(byte) }

    /// What a C formatter writes (into room for any value).
    private mutating func appendFormatted(_ format: (UnsafeMutablePointer<CChar>) -> Int) {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(CH_TEXT_CAPACITY)) { buffer in
            let count = format(buffer.baseAddress!)
            buffer.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: count) {
                bytes.append(contentsOf: UnsafeBufferPointer(start: $0, count: count))
            }
        }
    }

    /// A value: `quoted` inside composite values (strings, dates, UUIDs,
    /// addresses and enums in single quotes, escaped).
    mutating func write(_ column: CHColumn, row: Int, quoted: Bool, context: CHTextContext) {
        switch column.storage {
        case .nullable(let nulls, let values):
            if nulls[UInt8.self, row] != 0 { append("NULL") } else { write(values, row: row, quoted: quoted, context: context) }
        case .lowCardinality(let dictionary, let indexes):
            let index = Int(indexes[UInt32.self, row])
            if index == 0, case .nullable = column.type.lowCardinalityInner { append("NULL") } else {
                write(dictionary, row: index, quoted: quoted, context: context)
            }
        case .strings:
            guard let text = column.stringBytes(row) else { return }
            if quoted { appendQuoted(text) } else { bytes.append(contentsOf: text) }
        case .fixed(let buffer, let width):
            writeFixed(column.type, buffer: buffer, width: width, row: row, quoted: quoted, context: context)
        case .array(let ends, let elements):
            let end = Int(ends[UInt64.self, row]), start = row == 0 ? 0 : Int(ends[UInt64.self, row - 1])
            if case .map = column.type {
                // Pairs as key:value.
                guard case .tuple(let parts) = elements.storage, parts.count == 2 else { return }
                append(UInt8(ascii: "{"))
                for index in start..<end {
                    if index > start { append(UInt8(ascii: ",")) }
                    write(parts[0], row: index, quoted: true, context: context)
                    append(UInt8(ascii: ":"))
                    write(parts[1], row: index, quoted: true, context: context)
                }
                append(UInt8(ascii: "}"))
            } else {
                append(UInt8(ascii: "["))
                for index in start..<end {
                    if index > start { append(UInt8(ascii: ",")) }
                    write(elements, row: index, quoted: true, context: context)
                }
                append(UInt8(ascii: "]"))
            }
        case .tuple(let elements):
            append(UInt8(ascii: "("))
            for (index, element) in elements.enumerated() {
                if index > 0 { append(UInt8(ascii: ",")) }
                write(element, row: row, quoted: true, context: context)
            }
            append(UInt8(ascii: ")"))
        case .variant(let discriminators, let rows, let variants, let null):
            let kind = Int(discriminators[UInt8.self, row])
            if kind == null || kind >= variants.count { append("NULL") } else {
                write(variants[kind], row: Int(rows[UInt32.self, row]), quoted: quoted, context: context)
            }
        case .nothing:
            append("NULL")
        }
    }

    private mutating func writeFixed(_ type: CHType, buffer: CHBuffer, width: Int, row: Int, quoted: Bool, context: CHTextContext) {
        let base = UnsafeRawPointer(buffer.base)
        switch type {
        case .int8, .int16, .int32, .int64, .int128, .int256, .uint8, .uint16, .uint32, .uint64, .uint128, .uint256, .interval:
            guard let kind = type.numberKind else { return }
            appendFormatted { ch_format_integer(kind, base, row, $0) }
        case .float64:
            appendFloat(buffer[Double.self, row].description)
        case .float32:
            appendFloat(buffer[Float.self, row].description)
        case .bfloat16:
            let value = Float(bitPattern: UInt32(buffer[UInt16.self, row]) << 16)
            appendFloat(value.description)
        case .bool:
            if buffer[UInt8.self, row] != 0 { append("true") } else { append("false") }
        case .decimal(_, let scale):
            guard let kind = type.numberKind else { return }
            appendFormatted { ch_format_decimal(kind, base, row, Int32(scale), $0) }
        case .date:
            quotedIf(quoted) { $0.appendFormatted { ch_format_date(Int64(buffer[UInt16.self, row]), $0) } }
        case .date32:
            quotedIf(quoted) { $0.appendFormatted { ch_format_date(Int64(buffer[Int32.self, row]), $0) } }
        case .dateTime(let zone):
            let seconds = Int64(buffer[UInt32.self, row])
            let local = seconds + context.offsets(zone).offset(at: seconds)
            quotedIf(quoted) { $0.appendFormatted { ch_format_datetime(local, 0, 0, $0) } }
        case .dateTime64(let precision, let zone):
            let ticks = buffer[Int64.self, row], scale = Self.powersOfTen[precision]
            // Seconds rounded down: before 1970 the fraction still counts up.
            var seconds = ticks / scale, fraction = ticks % scale
            if fraction < 0 {
                seconds -= 1
                fraction += scale
            }
            let local = seconds + context.offsets(zone).offset(at: seconds)
            quotedIf(quoted) { $0.appendFormatted { ch_format_datetime(local, fraction, Int32(precision), $0) } }
        case .time:
            let seconds = Int64(buffer[Int32.self, row])
            quotedIf(quoted) { $0.appendFormatted { ch_format_time(seconds, 0, 0, $0) } }
        case .time64(let precision):
            let ticks = buffer[Int64.self, row], scale = Self.powersOfTen[precision]
            quotedIf(quoted) { $0.appendFormatted { ch_format_time(ticks / scale, ticks % scale, Int32(precision), $0) } }
        case .uuid:
            quotedIf(quoted) { $0.appendFormatted { ch_format_uuid((base + row * 16).assumingMemoryBound(to: UInt8.self), $0) } }
        case .ipv4:
            let address = buffer[UInt32.self, row]
            quotedIf(quoted) { $0.appendFormatted { ch_format_ipv4(address, $0) } }
        case .ipv6:
            quotedIf(quoted) { $0.appendFormatted { ch_format_ipv6((base + row * 16).assumingMemoryBound(to: UInt8.self), $0) } }
        case .enum8(let cases):
            appendEnum(cases, value: Int(buffer[Int8.self, row]), quoted: quoted)
        case .enum16(let cases):
            appendEnum(cases, value: Int(buffer[Int16.self, row]), quoted: quoted)
        case .fixedString:
            var text = UnsafeRawBufferPointer(start: base + row * width, count: width)
            if !quoted {
                while let last = text.last, last == 0 { text = UnsafeRawBufferPointer(rebasing: text.dropLast()) }
                bytes.append(contentsOf: text)
            } else {
                appendQuoted(text)
            }
        default:
            break
        }
    }

    static let powersOfTen: [Int64] = (0...18).map { power in (0..<power).reduce(1) { value, _ in value * 10 } }

    private mutating func quotedIf(_ quoted: Bool, _ body: (inout CHTextWriter) -> Void) {
        if quoted { append(UInt8(ascii: "'")) }
        body(&self)
        if quoted { append(UInt8(ascii: "'")) }
    }

    private mutating func appendEnum(_ cases: [CHEnumCase], value: Int, quoted: Bool) {
        guard let name = cases.first(where: { $0.value == value })?.name else {
            appendFormatted { buffer in
                var value = Int64(value)
                return withUnsafePointer(to: &value) { ch_format_integer(CH_I64, $0, 0, buffer) }
            }
            return
        }
        var text = name
        text.withUTF8 { utf8 in
            if quoted { appendQuoted(UnsafeRawBufferPointer(utf8)) } else { bytes.append(contentsOf: utf8) }
        }
    }

    /// A string in single quotes, escaped as ClickHouse does.
    private mutating func appendQuoted(_ text: UnsafeRawBufferPointer) {
        append(UInt8(ascii: "'"))
        for byte in text {
            switch byte {
            case UInt8(ascii: "'"): append("\\'")
            case UInt8(ascii: "\\"): append("\\\\")
            case 0x0A: append("\\n")
            case 0x09: append("\\t")
            case 0x0D: append("\\r")
            case 0x00: append("\\0")
            case 0x08: append("\\b")
            case 0x0C: append("\\f")
            default: append(byte)
            }
        }
        append(UInt8(ascii: "'"))
    }

    /// A float as ClickHouse writes it: its shortest digits (Swift's), as a
    /// whole number below 10^21, in exponent form below 10^-6 (as JavaScript).
    private mutating func appendFloat(_ description: String) {
        var text = description
        if text == "inf" || text == "-inf" || text == "nan" || text == "-nan" {
            if text == "-nan" { text = "nan" }
            text.withUTF8 { bytes.append(contentsOf: $0) }
            return
        }
        var utf8 = Array(text.utf8)
        var negative = false
        if utf8.first == UInt8(ascii: "-") {
            negative = true
            utf8.removeFirst()
        }
        // Digits and the power of ten after them: value = 0.digits × 10^point.
        var digits: [UInt8] = [], point = 0, exponent = 0, seenPoint = false, index = 0
        while index < utf8.count {
            let byte = utf8[index]
            if byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                exponent = Int(String(decoding: utf8[(index + 1)...], as: UTF8.self)) ?? 0
                break
            }
            if byte == UInt8(ascii: ".") {
                seenPoint = true
            } else {
                digits.append(byte)
                if !seenPoint { point += 1 }
            }
            index += 1
        }
        // Leading zeros (0.001) out, the point moved with them; trailing ones out.
        while digits.count > 1, digits.first == UInt8(ascii: "0") {
            digits.removeFirst()
            point -= 1
        }
        while digits.count > 1, digits.last == UInt8(ascii: "0") { digits.removeLast() }
        point += exponent
        if negative { append(UInt8(ascii: "-")) }
        if digits == [UInt8(ascii: "0")] {
            append(UInt8(ascii: "0"))
            return
        }
        let count = digits.count
        if count <= point, point <= 21 {
            bytes.append(contentsOf: digits)
            bytes.append(contentsOf: repeatElement(UInt8(ascii: "0"), count: point - count))
        } else if 0 < point, point <= 21 {
            bytes.append(contentsOf: digits[..<point])
            append(UInt8(ascii: "."))
            bytes.append(contentsOf: digits[point...])
        } else if -6 < point, point <= 0 {
            append("0.")
            bytes.append(contentsOf: repeatElement(UInt8(ascii: "0"), count: -point))
            bytes.append(contentsOf: digits)
        } else {
            append(digits[0])
            if count > 1 {
                append(UInt8(ascii: "."))
                bytes.append(contentsOf: digits[1...])
            }
            append(UInt8(ascii: "e"))
            bytes.append(contentsOf: String(point - 1).utf8)
        }
    }
}

extension CHType {
    /// How its values are stored as numbers (for C), `nil` if not numbers.
    var numberKind: ch_number_kind? {
        switch self {
        case .int8, .enum8: CH_I8
        case .uint8, .bool: CH_U8
        case .int16, .enum16: CH_I16
        case .uint16, .date: CH_U16
        case .int32, .date32, .time: CH_I32
        case .uint32, .dateTime, .ipv4: CH_U32
        case .int64, .dateTime64, .time64, .interval: CH_I64
        case .uint64: CH_U64
        case .int128: CH_I128
        case .uint128: CH_U128
        case .int256: CH_I256
        case .uint256: CH_U256
        case .float32: CH_F32
        case .float64: CH_F64
        case .bfloat16: CH_BF16
        case .decimal(let precision, _): precision <= 9 ? CH_I32 : precision <= 18 ? CH_I64 : precision <= 38 ? CH_I128 : CH_I256
        default: nil
        }
    }

    /// What its stored numbers are multiplied by to sort and sum (days to
    /// seconds, ticks to seconds, decimals to their values).
    var numberScale: Double {
        switch self {
        case .date, .date32: 86_400
        case .decimal(_, let scale): pow(10, -Double(scale))
        case .dateTime64(let precision, _), .time64(let precision): pow(10, -Double(precision))
        default: 1
        }
    }
}

extension CHColumn {
    /// Its values of `rows` as numbers into `values` (NaN for NULL and for
    /// values that aren't numbers): what sorts and sums them. Times are
    /// seconds since 1970, dates their midnights in UTC.
    public func numbers(rows: Range<Int>, into values: UnsafeMutablePointer<Double>) {
        switch storage {
        case .fixed(let buffer, _):
            guard let kind = type.numberKind else { return fill(values, rows.count) }
            ch_numbers(kind, buffer.base, rows.lowerBound, rows.count, type.numberScale, values)
        case .nullable(let nulls, let inner):
            inner.numbers(rows: rows, into: values)
            ch_apply_nulls(nulls.pointer(to: UInt8.self), rows.lowerBound, rows.count, values)
        case .lowCardinality(let dictionary, let indexes):
            // The dictionary's numbers once (index 0 is NULL in a nullable one).
            var numbers = [Double](repeating: .nan, count: dictionary.count)
            numbers.withUnsafeMutableBufferPointer { dictionary.numbers(rows: 0..<dictionary.count, into: $0.baseAddress!) }
            if case .nullable = type.lowCardinalityInner, !numbers.isEmpty { numbers[0] = .nan }
            numbers.withUnsafeBufferPointer {
                ch_gather_numbers($0.baseAddress, indexes.pointer(to: UInt32.self), rows.lowerBound, rows.count, values)
            }
        case .variant(let discriminators, let rowsInVariant, let variants, let null):
            for (offset, row) in rows.enumerated() {
                let kind = Int(discriminators[UInt8.self, row])
                guard kind != null, kind < variants.count, variants[kind].type.sortsAsNumber else {
                    values[offset] = .nan
                    continue
                }
                variants[kind].numbers(rows: Int(rowsInVariant[UInt32.self, row])..<Int(rowsInVariant[UInt32.self, row]) + 1,
                                       into: values + offset)
            }
        default:
            fill(values, rows.count)
        }
    }

    private func fill(_ values: UnsafeMutablePointer<Double>, _ count: Int) {
        values.update(repeating: .nan, count: count)
    }
}
