import Foundation

/// A result as received so far: its columns, and its rows in the blocks
/// they came in. A value: each block received makes a new one (blocks are
/// only added), so a copy stays as it was while more come.
public struct CHResult: Sendable {
    public private(set) var names: [String] = []
    public private(set) var typeNames: [String] = []
    public private(set) var types: [CHType] = []
    /// The blocks with rows.
    public private(set) var blocks: [CHBlock] = []
    /// The first row of each block.
    private(set) var blockStarts: [Int] = []
    public private(set) var rowCount = 0
    /// The bytes its values keep, roughly.
    public private(set) var byteCount = 0

    public init() {}

    /// Whether the header has come (the columns are known).
    public var hasHeader: Bool { !names.isEmpty || !blocks.isEmpty }

    mutating func append(_ block: CHBlock) throws {
        if names.isEmpty && types.isEmpty {
            names = block.names
            typeNames = block.typeNames
            types = block.types
        } else if block.typeNames != typeNames {
            throw CHDecodeError.malformed("a block of other columns")
        }
        guard block.rowCount > 0 else { return }
        blockStarts.append(rowCount)
        blocks.append(block)
        rowCount += block.rowCount
        byteCount += block.byteCount
    }

    /// The block of a row and the row in it.
    public func locate(_ row: Int) -> (block: Int, row: Int) {
        // Blocks are mostly of one size: guess, then search.
        var low = 0, high = blockStarts.count - 1
        if let first = blocks.first?.rowCount, first > 0 {
            let guess = min(high, row / first)
            if blockStarts[guess] <= row, guess == high || blockStarts[guess + 1] > row { return (guess, row - blockStarts[guess]) }
        }
        while low < high {
            let middle = (low + high + 1) / 2
            if blockStarts[middle] <= row { low = middle } else { high = middle - 1 }
        }
        return (low, row - blockStarts[low])
    }

    /// Calls `body` for the blocks holding `rows`: each block, its rows'
    /// range in it, and their offset from `rows.lowerBound`.
    public func forEachBlock(in rows: Range<Int>, _ body: (CHBlock, Range<Int>, Int) -> Void) {
        guard !rows.isEmpty, rows.lowerBound >= 0, rows.upperBound <= rowCount else { return }
        var (index, start) = locate(rows.lowerBound)
        var done = 0
        while done < rows.count, index < blocks.count {
            let block = blocks[index]
            let count = min(block.rowCount - start, rows.count - done)
            body(block, start..<(start + count), done)
            done += count
            index += 1
            start = 0
        }
    }
}

extension CHResult {
    /// The text of `columns` (by index) for `rows`, a row's after another as
    /// UTF-8, a tab between a row's values, for a search of them: `body`
    /// gets the bytes (valid while it runs), `starts[i]` where row
    /// `rows.lowerBound + i` begins, `starts[rows.count]` where the last ends.
    /// One String column of rows in one block is given as it is kept (no copy).
    public func withSearchText(columns: [Int], rows: Range<Int>, timeZone: TimeZone, starts: UnsafeMutableBufferPointer<UInt32>,
                               _ body: (UnsafeRawBufferPointer) -> Void) {
        guard !rows.isEmpty, starts.count > rows.count else { return body(UnsafeRawBufferPointer(start: nil, count: 0)) }
        if columns.count == 1 {
            let (blockIndex, first) = locate(rows.lowerBound)
            let column = blocks[blockIndex].columns[columns[0]]
            if first + rows.count <= column.count, case .strings(let ends, let chars) = column.storage {
                let end = ends.pointer(to: UInt32.self)
                let base = first == 0 ? 0 : end[first - 1]
                starts[0] = 0
                for offset in 0..<rows.count { starts[offset + 1] = end[first + offset] - base }
                return body(UnsafeRawBufferPointer(start: chars.base + Int(base), count: Int(end[first + rows.count - 1] - base)))
            }
        }
        // Each column's texts at once, then a row's after another.
        let context = CHTextContext(defaultTimeZone: timeZone)
        var columnTexts = [CHTexts](repeating: CHTexts(), count: columns.count)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(rows.count * 16 * columns.count)
        forEachBlock(in: rows) { block, range, offset in
            for (index, column) in columns.enumerated() {
                columnTexts[index].removeAll()
                block.columns[column].appendTexts(rows: range, context: context, to: &columnTexts[index])
            }
            for row in 0..<range.count {
                starts[offset + row] = UInt32(truncatingIfNeeded: bytes.count)
                for texts in columnTexts {
                    texts.withText(row) { bytes.append(contentsOf: $0) }
                    bytes.append(0x09)
                }
            }
        }
        starts[rows.count] = UInt32(truncatingIfNeeded: bytes.count)
        bytes.withUnsafeBytes(body)
    }
}

extension CHResult {
    /// Its values as text, row by row (NULL as no text): the viewer's own small queries.
    public func rows(timeZone: TimeZone = .gmt) -> [[String]] {
        let context = CHTextContext(defaultTimeZone: timeZone)
        var rows: [[String]] = []
        rows.reserveCapacity(rowCount)
        for block in blocks {
            for row in 0..<block.rowCount {
                rows.append(block.columns.map { $0.isNull(row) ? "" : $0.text(row, context: context) })
            }
        }
        return rows
    }
}
