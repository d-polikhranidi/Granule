import ClickHouseCore
import Foundation
import Gingham
#if os(iOS)
import os
#endif

/// A window's queries: runs a statement, shows its rows in the table as
/// they come (Gingham sorts, searches and sums them once they're all
/// there), says what's happening, cancels. One query at a time: running
/// another cancels the one before. The window's statements share a session
/// (`SET` and temporary tables last between them).
final class QueryController {
    let client: CHClient
    let table: GHTableView
    private(set) var source: ResultTableSource?
    /// Called when the status changed (rows came, the query ended, the table's activity).
    var onChange: () -> Void = {}
    /// Called with a statement's text output (its own `FORMAT`, or a statement without rows).
    var onText: (String?) -> Void = { _ in }

    enum State {
        case idle
        case running(started: ContinuousClock.Instant)
        case finished(CHQueryStats)
        case failed(Error)
        case cancelled
    }

    private(set) var state = State.idle
    /// The statement shown (as run, after any rewrite for unreadable columns).
    private(set) var statement: String?
    /// Columns shown as their final values (`finalizeAggregation`) or text: their bytes can't be read.
    private(set) var rewrittenColumns: [String] = []
    private var running: Task<Void, Never>?
    private let sessionID = UUID().uuidString
    private var lastRows = 0
    private(set) var searchText = ""

    init(client: CHClient, table: GHTableView) {
        self.client = client
        self.table = table
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    private var isFinished: Bool {
        if case .finished = state { return true }
        return false
    }

    /// The rows a result keeps at most, by the memory the app may take: the server stops there.
    static var budget: (rows: Int?, bytes: Int) {
        #if os(iOS)
        let available = os_proc_available_memory()
        let memory = available > 0 ? available : Int(ProcessInfo.processInfo.physicalMemory / 4)
        return (nil, max(256 << 20, memory / 2))
        #else
        return (nil, Int(ProcessInfo.processInfo.physicalMemory / 3))
        #endif
    }

    // MARK: Running

    /// Runs a statement: its rows into the table, or its text (a statement
    /// with its own `FORMAT`) to `onText`.
    func run(_ sql: String, parameters: [String: String] = [:]) {
        cancel()
        rewrittenColumns = []
        statement = sql
        onText(nil)
        let started = ContinuousClock.now
        state = .running(started: started)
        lastRows = 0
        onChange()
        if let format = CHSQL.formatClause(of: sql), format.lowercased() != "native" {
            running = Task { [weak self] in await self?.runForText(sql, parameters: parameters) }
        } else {
            running = Task { [weak self] in await self?.runForRows(sql, parameters: parameters, rewrites: 0) }
        }
    }

    private func runForText(_ sql: String, parameters: [String: String]) async {
        do {
            let text = try await client.plainText(sql, sessionID: sessionID)
            guard !Task.isCancelled else { return }
            onText(text)
            state = .finished(CHQueryStats(queryID: "", rows: 0, receivedBytes: text.utf8.count, resultBytes: 0, firstRows: nil,
                                           elapsed: elapsed, reachedLimit: false))
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error)
        }
        onChange()
    }

    private var elapsed: Duration {
        if case .running(let started) = state { return ContinuousClock.now - started }
        return .zero
    }

    private func runForRows(_ sql: String, parameters: [String: String], rewrites: Int) async {
        var options = CHQueryOptions()
        options.sessionID = sessionID
        options.parameters = parameters
        let budget = Self.budget
        options.maxRows = budget.rows
        options.maxBytes = budget.bytes
        let isRead = CHSQL.kind(of: sql) == .read
        var shown = false
        var lastUpdate = ContinuousClock.now
        // The rows received but not yet given to the table.
        var latest: CHResult?
        do {
            for try await event in client.execute(sql, options: options) {
                guard !Task.isCancelled else { return }
                switch event {
                case .result(let result):
                    if !shown {
                        show(result)
                        shown = true
                    } else if ContinuousClock.now - lastUpdate > .milliseconds(50) {
                        // More rows, at most 20 times a second (a block is ~65,000 rows).
                        add(result)
                        lastUpdate = ContinuousClock.now
                        latest = nil
                    } else {
                        latest = result
                    }
                case .finished(let stats):
                    if let latest { add(latest) }
                    if !shown, !isRead {
                        onText(String(localized: "Done."))
                    }
                    state = .finished(stats)
                    finish()
                }
            }
        } catch CHClientError.unsupportedType(let column, let type) where rewrites < 8 && isRead && !column.isEmpty {
            // A column whose bytes can't be read: run it again with the column as its value or text.
            let expression = type.hasPrefix("AggregateFunction")
                ? "finalizeAggregation(\(CHSQL.quotedName(column)))" : "toString(\(CHSQL.quotedName(column)))"
            rewrittenColumns.append(column)
            let rewritten = "SELECT * REPLACE (\(expression) AS \(CHSQL.quotedName(column))) FROM (\n\(sql)\n)"
            statement = rewritten
            await runForRows(rewritten, parameters: parameters, rewrites: rewrites + 1)
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error)
            if let latest { add(latest) }
            table.sortsRows = true
        }
        onChange()
    }

    /// The first block (or the header): the table's columns.
    private func show(_ result: CHResult) {
        let source = ResultTableSource(result: result, timeZone: client.serverInfo?.zone ?? .gmt)
        self.source = source
        table.sortsRows = false
        table.sortDescriptors = []
        table.rowFilter = nil
        table.columns = source.columns
        table.dataSource = source
        table.reloadData()
        lastRows = result.rowCount
        if !searchText.isEmpty { table.rowFilter = filter(searchText) }
        onChange()
    }

    /// More rows at the end.
    private func add(_ result: CHResult) {
        guard let source else { return show(result) }
        source.result = result
        lastRows = result.rowCount
        table.noteNumberOfRowsChanged()
        onChange()
    }

    /// All rows here: the table sorts them now, and the columns fit their
    /// titles, values and sums (1,000 rows all over the result), up to `widest`.
    private func finish() {
        table.sortsRows = true
        for column in table.tableColumns {
            guard let fitted = table.fittingWidth(ofColumnID: column.id, measuringRows: 1_000) else { continue }
            table.setWidth(min(max(fitted, 48), Self.widest), forColumnID: column.id)
        }
        onChange()
    }

    /// The widest a column gets to fit its values (longer ones are cut, the inspector shows them).
    static let widest = 480.0

    /// Stops the query (closing its connection; the server is told to kill it).
    func cancel() {
        guard let running else { return }
        running.cancel()
        self.running = nil
        if isRunning {
            state = .cancelled
            table.sortsRows = true
            onChange()
        }
    }

    // MARK: Search

    /// Rows with words that begin with each of the text's words, in any column.
    func search(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        table.rowFilter = text.isEmpty ? nil : filter(text)
        onChange()
    }

    private func filter(_ text: String) -> GHRowFilter {
        GHRowFilter(searchText: text, columnIDs: Set(table.tableColumns.map(\.id)))
    }

    // MARK: Status

    /// What the window says: rows (found), how long, how much, sorting, or the error.
    var status: String {
        let rows = source?.result.rowCount ?? 0
        var parts: [String] = []
        switch state {
        case .idle:
            return ""
        case .running(let started):
            let seconds = Self.seconds(ContinuousClock.now - started)
            parts.append(rows > 0 ? String(localized: "Receiving… \(rows.formatted()) rows") : String(localized: "Running…"))
            parts.append(String(localized: "\(seconds.formatted(.number.precision(.fractionLength(1)))) s"))
        case .finished(let stats):
            parts.append(rowsText(rows))
            if let first = stats.firstRows, stats.rows > 0 {
                parts.append(String(localized: "first rows in \(Self.seconds(first).formatted(.number.precision(.fractionLength(3)))) s"))
            }
            parts.append(String(localized: "\(Self.seconds(stats.elapsed).formatted(.number.precision(.fractionLength(3)))) s"))
            if stats.receivedBytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(stats.receivedBytes), countStyle: .file)) }
            if stats.reachedLimit || (source.map { $0.result.byteCount >= Self.budget.bytes } ?? false) {
                parts.append(String(localized: "stopped at the memory limit"))
            }
        case .failed:
            parts.append(rows > 0 ? String(localized: "Failed after \(rows.formatted()) rows") : String(localized: "Failed"))
        case .cancelled:
            parts.append(String(localized: "Cancelled after \(rows.formatted()) rows"))
        }
        if table.isSortingRows { parts.append(String(localized: "Sorting…")) }
        if table.isSearchingRows, searchText.isEmpty || !isFinished { parts.append(String(localized: "Searching…")) }
        if table.isCopying { parts.append(String(localized: "Copying…")) }
        if table.isExporting { parts.append(String(localized: "Exporting…")) }
        if !rewrittenColumns.isEmpty {
            parts.append(String(localized: "shown as values: \(rewrittenColumns.joined(separator: ", "))"))
        }
        return parts.joined(separator: " · ")
    }

    private func rowsText(_ rows: Int) -> String {
        guard !searchText.isEmpty else { return String(localized: "\(rows.formatted()) rows") }
        return table.isSearchingRows ? String(localized: "Searching…") : String(localized: "\(table.numberOfRows.formatted()) of \(rows.formatted()) rows")
    }

    /// The error to show, if the query failed.
    var error: Error? {
        if case .failed(let error) = state { return error }
        return nil
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

extension Error {
    /// What the viewer says of an error.
    var viewerDescription: String {
        let error: Error = self
        switch error {
        case let error as CHServerError: return error.description
        case CHClientError.unsupportedType(let column, let type):
            return String(localized: "The column \(column) is of a type this viewer can't read: \(type).")
        case CHClientError.truncated: return String(localized: "The result was cut off: the connection closed before its end.")
        case CHClientError.unexpectedResponse(let status, let text):
            return String(localized: "The server answered \(status), not as ClickHouse: \(text)")
        case CHClientError.malformed(let what): return String(localized: "The result can't be read (\(what)).")
        case CHClientError.badURL: return String(localized: "The server's address isn't valid.")
        default: return localizedDescription
        }
    }
}
