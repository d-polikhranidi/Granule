import CHDecode
import Foundation

/// Texts of many values one after another (UTF-8), with where each ends:
/// a column's rows written at once (search, sorting by text, copy).
public struct CHTexts {
    public private(set) var bytes: [UInt8] = []
    /// Where each text ends in `bytes`.
    public private(set) var ends: [UInt32] = []

    public init() {}

    public var count: Int { ends.count }

    public mutating func removeAll() {
        bytes.removeAll(keepingCapacity: true)
        ends.removeAll(keepingCapacity: true)
    }

    /// A text's bytes, for `body`.
    public func withText<Result>(_ index: Int, _ body: (UnsafeRawBufferPointer) -> Result) -> Result {
        let start = index == 0 ? 0 : Int(ends[index - 1]), end = Int(ends[index])
        return bytes.withUnsafeBytes { body(UnsafeRawBufferPointer(rebasing: $0[start..<end])) }
    }

    /// Room for `count` more texts of at most `capacity` bytes each, written by
    /// `write` (into the bytes after the last, with their ends from it), which
    /// returns the bytes it wrote.
    mutating func append(count: Int, capacity: Int,
                         _ write: (UnsafeMutablePointer<CChar>, UnsafeMutablePointer<UInt32>, UInt32) -> Int) {
        guard count > 0 else { return }
        let byteStart = bytes.count, endStart = ends.count
        bytes.append(contentsOf: repeatElement(0, count: count * capacity))
        ends.append(contentsOf: repeatElement(0, count: count))
        let written = bytes.withUnsafeMutableBytes { raw in
            ends.withUnsafeMutableBufferPointer { endBuffer in
                write((raw.baseAddress! + byteStart).assumingMemoryBound(to: CChar.self), endBuffer.baseAddress! + endStart, UInt32(byteStart))
            }
        }
        bytes.removeLast(count * capacity - written)
    }

    mutating func append(_ text: UnsafeRawBufferPointer) {
        bytes.append(contentsOf: text)
        ends.append(UInt32(truncatingIfNeeded: bytes.count))
    }
}

extension CHColumn {
    /// The text of `rows` as `text(_:context:)` writes each (NULL: no text),
    /// added to `texts`: in C at once for numbers, dates, times, UUIDs and
    /// addresses, as they are for strings.
    public func appendTexts(rows: Range<Int>, context: CHTextContext, to texts: inout CHTexts) {
        guard !rows.isEmpty else { return }
        var nulls: CHBuffer?
        var values = self
        if case .nullable(let mask, let inner) = storage {
            nulls = mask
            values = inner
        }
        let nullBytes = nulls.map { UnsafePointer($0.pointer(to: UInt8.self)) }
        let capacity = Int(CH_TEXT_CAPACITY)
        if case .lowCardinality(let dictionary, let indexes) = storage {
            // The dictionary's texts once, then each row's copied (index 0 is NULL in a nullable one: no text).
            var words = CHTexts()
            dictionary.appendTexts(rows: 0..<dictionary.count, context: context, to: &words)
            let isNullable = if case .nullable = type.lowCardinalityInner { true } else { false }
            let index = indexes.pointer(to: UInt32.self)
            words.bytes.withUnsafeBytes { raw in
                for row in rows {
                    let word = Int(index[row])
                    if isNullable, word == 0 {
                        texts.append(UnsafeRawBufferPointer(start: nil, count: 0))
                        continue
                    }
                    let start = word == 0 ? 0 : Int(words.ends[word - 1])
                    texts.append(UnsafeRawBufferPointer(rebasing: raw[start..<Int(words.ends[word])]))
                }
            }
            return
        }
        switch values.storage {
        case .strings(let ends, let chars) where nulls == nil:
            let end = ends.pointer(to: UInt32.self)
            let first = rows.lowerBound == 0 ? 0 : Int(end[rows.lowerBound - 1])
            let base = UInt32(texts.bytes.count) &- UInt32(first)
            texts.append(count: rows.count, capacity: 0) { _, _, _ in 0 }
            texts.replaceLast(rows.count, bytes: UnsafeRawBufferPointer(start: chars.base + first, count: Int(end[rows.upperBound - 1]) - first)) { index in
                end[rows.lowerBound + index] &+ base
            }
            return
        case .fixed(let buffer, _):
            let source = UnsafeRawPointer(buffer.base)
            switch values.type {
            case .int8, .int16, .int32, .int64, .int128, .int256, .uint8, .uint16, .uint32, .uint64, .uint128, .uint256, .interval:
                guard let kind = values.type.numberKind else { break }
                texts.append(count: rows.count, capacity: capacity) { out, ends, base in
                    ch_format_integers(kind, source, nullBytes, rows.lowerBound, rows.count, out, ends, base)
                }
                return
            case .decimal(_, let scale):
                guard let kind = values.type.numberKind else { break }
                texts.append(count: rows.count, capacity: capacity) { out, ends, base in
                    ch_format_decimals(kind, source, nullBytes, rows.lowerBound, rows.count, Int32(scale), out, ends, base)
                }
                return
            case .date, .date32:
                let wide: Int32 = if case .date32 = values.type { 1 } else { 0 }
                texts.append(count: rows.count, capacity: capacity) { out, ends, base in
                    ch_format_dates(wide, source, nullBytes, rows.lowerBound, rows.count, out, ends, base)
                }
                return
            case .dateTime(let zone), .dateTime64(_, let zone):
                var precision: Int32 = -1
                if case .dateTime64(let digits, _) = values.type { precision = Int32(digits) }
                var least: Int64 = 0, most: Int64 = 0
                ch_seconds_range(source, precision, rows.lowerBound, rows.count, &least, &most)
                let table = context.offsets(zone).table(from: least, to: most)
                texts.append(count: rows.count, capacity: capacity) { out, ends, base in
                    table.instants.withUnsafeBufferPointer { instants in
                        table.offsets.withUnsafeBufferPointer { offsets in
                            ch_format_datetimes(source, precision, nullBytes, rows.lowerBound, rows.count, instants.baseAddress, offsets.baseAddress,
                                                table.offsets.count, out, ends, base)
                        }
                    }
                }
                return
            case .uuid:
                texts.append(count: rows.count, capacity: capacity) { out, ends, base in
                    ch_format_uuids(source.assumingMemoryBound(to: UInt8.self), nullBytes, rows.lowerBound, rows.count, out, ends, base)
                }
                return
            case .ipv4:
                texts.append(count: rows.count, capacity: capacity) { out, ends, base in
                    ch_format_ipv4s(source.assumingMemoryBound(to: UInt32.self), nullBytes, rows.lowerBound, rows.count, out, ends, base)
                }
                return
            default:
                break
            }
        default:
            break
        }
        // The rest one by one: floats, strings with NULLs, enums, composites, …
        var writer = CHTextWriter()
        for row in rows {
            withText(row, context: context, writer: &writer) { texts.append($0) }
        }
    }
}

extension CHTexts {
    /// The last `count` texts made the bytes given, ending where `end(i)` says.
    fileprivate mutating func replaceLast(_ count: Int, bytes text: UnsafeRawBufferPointer, end: (Int) -> UInt32) {
        bytes.append(contentsOf: text)
        let first = ends.count - count
        for index in 0..<count { ends[first + index] = end(index) }
    }
}

extension CHZoneOffsets {
    /// The zone's offsets from `least` to `most` (seconds since 1970): the
    /// offset at `least`, then each change and the offset after it.
    func table(from least: Int64, to most: Int64) -> (instants: [Int64], offsets: [Int32]) {
        var instants = [least], offsets = [Int32(offset(at: least))]
        guard !isFixed, most > least else { return (instants, offsets) }
        var date = Date(timeIntervalSince1970: TimeInterval(least))
        let end = Date(timeIntervalSince1970: TimeInterval(most))
        while let next = zone.nextDaylightSavingTimeTransition(after: date), next <= end, instants.count < 10_000 {
            let seconds = Int64(next.timeIntervalSince1970.rounded())
            instants.append(seconds)
            offsets.append(Int32(zone.secondsFromGMT(for: next)))
            date = next
        }
        return (instants, offsets)
    }
}
