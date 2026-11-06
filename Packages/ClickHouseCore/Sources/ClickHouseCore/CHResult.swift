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
