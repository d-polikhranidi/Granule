import ClickHouseCore
import Foundation
import Gingham

/// A result as the table's rows: a column for each of the result's, cells
/// as ClickHouse writes the values (numbers and times exactly, in their
/// columns' time zones), `NULL` for none. The table sorts, searches and sums
/// the rows itself, reading them through the column source
/// (`ResultColumnSource`: on all cores, off the main thread).
final class ResultTableSource: GHTableViewDataSource {
    /// The result as received so far (rows are only added).
    var result: CHResult
    /// The zone of times without one in their type: the server's.
    let timeZone: TimeZone
    private(set) var columns: [GHColumnItem] = []

    private let context: CHTextContext
    private var writer = CHTextWriter()
    /// The text shown of a value at most (the rest is in the cell's inspector).
    nonisolated static let shownLength = 2_000

    init(result: CHResult, timeZone: TimeZone) {
        self.result = result
        self.timeZone = timeZone
        context = CHTextContext(defaultTimeZone: timeZone)
        columns = makeColumns()
    }

    private func makeColumns() -> [GHColumnItem] {
        result.names.indices.map { index in
            let type = result.types[index]
            let name = result.names[index]
            let trailing = type.isNumeric
            // Sums of measures, not of identifiers or keys.
            let lowered = name.lowercased()
            let isKey = lowered == "id" || lowered.hasSuffix("_id") || name.hasSuffix("Id") || name.hasSuffix("ID")
                || lowered.hasSuffix("_key") || lowered.hasSuffix("hash") || lowered == "number"
            let sums = type.isNumeric && !isKey
            return .column(GHTableColumn(String(index), title: name, width: Self.width(of: type, name: name), minWidth: 32, maxWidth: 4_000,
                                         alignment: trailing ? .trailing : .leading, headerAlignment: trailing ? .trailing : .leading,
                                         summary: sums ? .aggregate(.sum) : .none, toolTip: "\(name): \(result.typeNames[index])",
                                         isFilterable: false))
        }
    }

    /// A first width by the type (fitted to the values once they've come).
    private static func width(of type: CHType, name: String) -> Double {
        let byType: Double = switch type.base {
        case .uint8, .int8, .bool, .enum8: 64
        case .date, .date32: 96
        case .dateTime: 150
        case .dateTime64: 190
        case .uuid: 290
        case .string, .json, .array, .map, .tuple: 220
        default: 110
        }
        return max(byType, min(260, Double(name.count) * 8 + 24))
    }

    /// The column's index in the result for a column id.
    func index(of column: GHTableColumn) -> Int? {
        guard let index = Int(column.id), index < result.names.count else { return nil }
        return index
    }

    // MARK: GHTableViewDataSource

    func numberOfRows(in tableView: GHTableView) -> Int { result.rowCount }

    func tableView(_ tableView: GHTableView, valueFor column: GHTableColumn, row: Int) -> GHCellValue {
        guard let index = index(of: column), row < result.rowCount else { return .empty }
        let (block, inBlock) = result.locate(row)
        let values = result.blocks[block].columns[index]
        if values.isNull(inBlock) { return .text("NULL") }
        return .text(values.withText(inBlock, context: context, writer: &writer) { Self.shownText($0) })
    }

    /// NULL sorts as no value (first), not as the text "NULL".
    func tableView(_ tableView: GHTableView, sortValueFor column: GHTableColumn, row: Int) -> GHCellValue {
        guard let index = index(of: column), row < result.rowCount else { return .empty }
        let (block, inBlock) = result.locate(row)
        let values = result.blocks[block].columns[index]
        guard !values.isNull(inBlock) else { return .empty }
        if values.type.sortsAsNumber {
            var number = Double.nan
            values.numbers(rows: inBlock..<inBlock + 1, into: &number)
            return number.isNaN ? .empty : .number(number)
        }
        return .text(values.withText(inBlock, context: context, writer: &writer) { Self.shownText($0) })
    }

    func columnSource(for tableView: GHTableView) -> (any GHColumnSource)? {
        ResultColumnSource(result: result, timeZone: timeZone)
    }

    /// A value's full text (the inspector, copying one cell).
    func fullText(row: Int, columnIndex: Int) -> String? {
        guard row >= 0, row < result.rowCount, columnIndex < result.names.count else { return nil }
        let (block, inBlock) = result.locate(row)
        return result.blocks[block].columns[columnIndex].text(inBlock, context: context)
    }

    /// Whether a value is NULL.
    func isNull(row: Int, columnIndex: Int) -> Bool {
        guard row >= 0, row < result.rowCount, columnIndex < result.names.count else { return false }
        let (block, inBlock) = result.locate(row)
        return result.blocks[block].columns[columnIndex].isNull(inBlock)
    }

    /// A value as its cell shows it (one line, its first characters), `NULL` for none.
    func shownText(row: Int, columnIndex: Int) -> String {
        guard row >= 0, row < result.rowCount, columnIndex < result.names.count else { return "" }
        let (block, inBlock) = result.locate(row)
        let values = result.blocks[block].columns[columnIndex]
        if values.isNull(inBlock) { return "NULL" }
        return values.withText(inBlock, context: context, writer: &writer) { Self.shownText($0) }
    }

    /// A value as a cell shows it: one line (line breaks as marks), the first
    /// `shownLength` characters.
    nonisolated static func shownText(_ bytes: UnsafeRawBufferPointer) -> String {
        var hasBreak = false
        for byte in bytes where byte == 0x0A || byte == 0x0D {
            hasBreak = true
            break
        }
        if !hasBreak, bytes.count <= shownLength { return String(decoding: bytes, as: UTF8.self) }
        var text = String(decoding: bytes.prefix(shownLength * 4), as: UTF8.self)
        if text.count > shownLength { text = String(text.prefix(shownLength)) + "…" }
        guard hasBreak else { return text }
        return text.replacingOccurrences(of: "\r\n", with: " ↵ ").replacingOccurrences(of: "\n", with: " ↵ ").replacingOccurrences(of: "\r", with: " ↵ ")
    }
}

/// The result as the table's column source: Gingham reads it on all cores,
/// off the main thread, to sort, search, sum, copy and export. A snapshot:
/// the result as it was when the table asked (rows are only added).
struct ResultColumnSource: GHColumnSource {
    let result: CHResult
    let timeZone: TimeZone

    private func index(_ column: GHTableColumn) -> Int? {
        guard let index = Int(column.id), index < result.names.count else { return nil }
        return index
    }

    func kind(of column: GHTableColumn) -> GHColumnSourceKind? {
        guard let index = index(column) else { return nil }
        // Numbers and times show as ClickHouse writes them, and sort and sum by value.
        return result.types[index].sortsAsNumber ? .numericText : .text
    }

    func texts(of column: GHTableColumn, rows: Range<Int>, into texts: inout GHTextBatch) {
        guard let index = index(column) else {
            for _ in rows { texts.append("") }
            return
        }
        // Each block's rows written at once (in C for numbers and times), then handed over.
        let context = CHTextContext(defaultTimeZone: timeZone)
        var written = CHTexts()
        result.forEachBlock(in: rows) { block, range, _ in
            written.removeAll()
            block.columns[index].appendTexts(rows: range, context: context, to: &written)
            for row in 0..<written.count { written.withText(row) { Self.append($0, to: &texts) } }
        }
    }

    func texts(of column: GHTableColumn, atRows rows: UnsafeBufferPointer<Int>, into texts: inout GHTextBatch) {
        guard let index = index(column) else {
            for _ in rows { texts.append("") }
            return
        }
        let context = CHTextContext(defaultTimeZone: timeZone)
        var writer = CHTextWriter()
        for row in rows {
            let (block, inBlock) = result.locate(row)
            result.blocks[block].columns[index].withText(inBlock, context: context, writer: &writer) { Self.append($0, to: &texts) }
        }
    }

    func numbers(of column: GHTableColumn, rows: Range<Int>, into values: UnsafeMutableBufferPointer<Double>) {
        guard let index = index(column), let base = values.baseAddress else { return }
        result.forEachBlock(in: rows) { block, range, offset in
            block.columns[index].numbers(rows: range, into: base + offset)
        }
    }

    /// The rows' text where it is for Gingham's search (in place, on all cores):
    /// a String column searched alone is given as it is kept.
    func withSearchText(of columns: [GHTableColumn], rows: Range<Int>, starts: UnsafeMutableBufferPointer<UInt32>,
                        _ body: (UnsafeRawBufferPointer) -> Void) -> Bool {
        let indexes = columns.compactMap(index)
        guard indexes.count == columns.count else { return false }
        #if DEBUG
        // `-ViewerNoInPlaceSearch YES`: each column's texts read instead, to compare.
        if UserDefaults.standard.bool(forKey: "ViewerNoInPlaceSearch") { return false }
        #endif
        result.withSearchText(columns: indexes, rows: rows, timeZone: timeZone, starts: starts, body)
        return true
    }

    /// A value as the cell shows it: one line (copy and export keep rows apart).
    private static func append(_ bytes: UnsafeRawBufferPointer, to texts: inout GHTextBatch) {
        var plain = bytes.count <= ResultTableSource.shownLength
        if plain {
            for byte in bytes where byte == 0x0A || byte == 0x0D {
                plain = false
                break
            }
        }
        if plain {
            texts.append(utf8: bytes.bindMemory(to: UInt8.self))
        } else {
            texts.append(ResultTableSource.shownText(bytes))
        }
    }
}
