import ClickHouseCore
import ClickHouseSSH
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
    /// Called when killing queries or mutations failed (shown apart: the view keeps refreshing).
    var onKillFailure: (Error) -> Void = { _ in }

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
    /// The running query's progress from the server (polled), and the
    /// finished one's numbers from its log.
    private(set) var progress: CHQueryProgress?
    private(set) var serverStats: CHServerStats?
    private var monitoring: Task<Void, Never>?
    private var queryID = ""
    private let sessionID = UUID().uuidString
    private var lastRows = 0
    private(set) var searchText = ""
    /// The session's database after a `USE` run in it (`nil`: the connection's).
    private(set) var currentDatabase: String?
    /// The server's view shown (its statement run as is), refreshed while it's live.
    private(set) var view: ServerView?
    /// The cluster the views read across (`nil`: this server alone).
    var cluster: String?
    private var refreshing: Task<Void, Never>?
    /// When the shown view was last read.
    private(set) var refreshed: Date?
    /// The view is being read again (the status stays as it was meanwhile).
    private var isRefreshing = false
    private var lastStats: CHQueryStats?

    init(client: CHClient, table: GHTableView) {
        self.client = client
        self.table = table
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// A statement of the user's that changes data is running: another Run would stop it halfway.
    var isRunningWrite: Bool {
        isRunning && view == nil && statement.map { CHSQL.kind(of: $0) == .other } == true
    }

    /// The question before a Kill, and what it means.
    func killQuestion(for plan: KillPlan) -> (title: String, detail: String) {
        let count = plan.statements.count
        let title = plan.killsMutations
            ? (count == 1 ? String(localized: "Kill this mutation?") : String(localized: "Kill \(count.formatted()) mutations?"))
            : (count == 1 ? String(localized: "Kill this query?") : String(localized: "Kill \(count.formatted()) queries?"))
        var detail = plan.killsMutations
            ? String(localized: "A killed mutation stops where it is: the parts it already changed stay changed.")
            : String(localized: "The query stops; what it already wrote stays written.")
        if let cluster = plan.cluster { detail += " " + String(localized: "On every server of the cluster \(cluster).") }
        return (title, detail)
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
        whenWriteMayStop { [weak self] in
            guard let self else { return }
            cancel()
            view = nil
            start(sql, parameters: parameters, refresh: false)
        }
    }

    /// A server view: its rows, read again every two seconds while it's live
    /// and shown; across the cluster if one is chosen.
    func show(_ view: ServerView) {
        whenWriteMayStop { [weak self] in
            guard let self else { return }
            cancel()
            self.view = view
            start(view.sql(cluster: cluster), parameters: [:], refresh: false)
        }
    }

    /// Asked before a statement of the user's that changes data is stopped halfway by
    /// whatever runs next (Run, a server view, a table's details): call the closure to go on.
    var confirmStoppingWrite: (@escaping () -> Void) -> Void = { proceed in proceed() }

    private func whenWriteMayStop(_ go: @escaping () -> Void) {
        guard isRunningWrite else { return go() }
        confirmStoppingWrite(go)
    }

    /// Whether Export may run the statement again: only one that reads (a write would run twice).
    var canExport: Bool {
        statement.map { CHSQL.kind(of: $0) == .read && CHSQL.formatClause(of: $0) == nil } ?? false
    }

    /// The question before a statement that drops, deletes or rewrites data on a production
    /// server that isn't read only (`nil`: none), and the name to type to run it.
    func productionQuestion(for sql: String) -> (title: String, detail: String, name: String)? {
        let endpoint = client.endpoint
        guard endpoint.environment == .production, !endpoint.isReadOnly, CHSQL.isDestructive(sql) else { return nil }
        // The statement's first line, after the comments before it.
        let start = CHSQL.tokens(sql).first { $0.kind != .whitespace && $0.kind != .comment }?.range.location ?? 0
        let rest = (sql as NSString).substring(from: start)
        var line = rest.split(whereSeparator: \.isNewline).first.map(String.init) ?? rest
        if line.count > 120 { line = String(line.prefix(120)) + "…" }
        return (String(localized: "Change data on the production server?"),
                String(localized: "This drops, deletes or rewrites data on \(endpoint.title):\n\n\(line)\n\nType the connection's name to run it."),
                endpoint.title)
    }

    private func start(_ sql: String, parameters: [String: String], refresh: Bool) {
        refreshesLive = false
        isRefreshing = refresh
        rewrittenColumns = []
        statement = sql
        onText(nil)
        let started = ContinuousClock.now
        state = .running(started: started)
        lastRows = 0
        progress = nil
        serverStats = nil
        onChange()
        if let format = CHSQL.formatClause(of: sql), format.lowercased() != "native" {
            running = Task { [weak self] in await self?.runForText(sql, parameters: parameters) }
        } else {
            running = Task { [weak self] in await self?.runForRows(sql, parameters: parameters, rewrites: 0, refresh: refresh) }
        }
    }

    /// A live view waits while its window can't be seen (Mac: not on screen;
    /// iPad and iPhone: in the background), and goes on when it can.
    var isPaused = false {
        didSet { if oldValue, !isPaused, refreshesLive { scheduleRefresh() } }
    }
    /// Whether the live view is meant to go on: not once it's stopped or a reading failed.
    private var refreshesLive = false

    /// The live view run again in two seconds, ten on ClickHouse Cloud (every query
    /// keeps a service awake), unless something else runs by then or it's paused.
    private func scheduleRefresh() {
        refreshing?.cancel()
        guard let view, view.isLive else { return }
        refreshesLive = true
        let interval: Duration = client.endpoint.isCloud ? .seconds(10) : .seconds(2)
        refreshing = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled, self.view == view, !self.isRunning, !self.isPaused else { return }
            self.start(view.sql(cluster: self.cluster), parameters: [:], refresh: true)
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

    private func runForRows(_ sql: String, parameters: [String: String], rewrites: Int, refresh: Bool = false) async {
        var options = CHQueryOptions()
        queryID = options.queryID
        if view == nil { monitor(options.queryID) }
        options.sessionID = sessionID
        options.parameters = parameters
        // A server view is the viewer's own query: left out of the views of the log.
        options.isBackground = view != nil
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
                        show(result, keepingLayout: refresh)
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
                    monitoring?.cancel()
                    if let latest { add(latest) }
                    if !shown, !isRead {
                        onText(String(localized: "Done."))
                    }
                    if let database = Self.usedDatabase(sql) { currentDatabase = database }
                    state = .finished(stats)
                    lastStats = stats
                    isRefreshing = false
                    if refresh {
                        table.sortsRows = true
                    } else {
                        finish()
                    }
                    if view != nil {
                        refreshed = Date()
                        scheduleRefresh()
                    } else {
                        logged(stats.queryID)
                    }
                }
            }
        } catch CHClientError.unsupportedType(let column, let type) where rewrites < 8 && isRead && !column.isEmpty {
            // A column whose bytes can't be read: run it again with the column as its value or text.
            let expression = type.hasPrefix("AggregateFunction")
                ? "finalizeAggregation(\(CHSQL.quotedName(column)))" : "toString(\(CHSQL.quotedName(column)))"
            rewrittenColumns.append(column)
            let rewritten = "SELECT * REPLACE (\(expression) AS \(CHSQL.quotedName(column))) FROM (\n\(sql)\n)"
            statement = rewritten
            await runForRows(rewritten, parameters: parameters, rewrites: rewrites + 1, refresh: refresh)
            return
        } catch {
            guard !Task.isCancelled else { return }
            isRefreshing = false
            state = .failed(error)
            if let latest { add(latest) }
            table.sortsRows = true
        }
        onChange()
    }

    /// The database a `USE` statement switches the session to.
    static func usedDatabase(_ sql: String) -> String? {
        let words = CHSQL.tokens(sql).filter { $0.kind != .whitespace && $0.kind != .comment }
        let text = sql as NSString
        guard words.count >= 2, text.substring(with: words[0].range).uppercased() == "USE" else { return nil }
        let name = text.substring(with: words[1].range)
        guard name.count >= 2, let first = name.first, first == "`" || first == "\"" else { return name }
        return String(name.dropFirst().dropLast())
    }

    /// The server's progress of a running query, twice a second (from a
    /// second connection; the session runs the query).
    private func monitor(_ id: String) {
        monitoring?.cancel()
        monitoring = Task { [weak self, client] in
            try? await Task.sleep(for: .milliseconds(300))
            while !Task.isCancelled {
                let progress = try? await client.progress(of: id)
                guard let self, !Task.isCancelled, self.queryID == id, self.isRunning else { return }
                if let progress { self.progress = progress }
                self.onChange()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// A finished query's numbers from the server's log, once it's written
    /// there (every 7.5 s by default): looked for a few times.
    private func logged(_ id: String) {
        monitoring?.cancel()
        monitoring = Task { [weak self, client] in
            for delay in [0.5, 2, 3, 4, 6] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                let stats: CHServerStats?
                do {
                    stats = try await client.serverStats(of: id)
                } catch {
                    return
                }
                guard let self, self.queryID == id else { return }
                if let stats {
                    self.serverStats = stats
                    self.onChange()
                    return
                }
            }
        }
    }

    /// The first block (or the header): the table's columns. A view read
    /// again keeps its columns, sort, search and selection (rows by their id).
    private func show(_ result: CHResult, keepingLayout: Bool = false) {
        if keepingLayout, let source, source.result.typeNames == result.typeNames, source.result.names == result.names {
            source.result = result
            lastRows = result.rowCount
            table.reloadData()
            onChange()
            return
        }
        let source = ResultTableSource(result: result, timeZone: client.serverInfo?.zone ?? .gmt)
        self.source = source
        table.sortsRows = false
        table.sortDescriptors = []
        table.rowFilter = nil
        table.rowIdentifierColumnID = view?.identifierColumn.flatMap { name in result.names.firstIndex(of: name).map(String.init) }
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
        // Fitted once the table has laid the rows out (a small result comes and ends in one go).
        let source = source
        DispatchQueue.main.async { [weak self] in
            guard let self, self.source === source else { return }
            for column in table.tableColumns {
                guard let fitted = table.fittingWidth(ofColumnID: column.id, measuringRows: 1_000) else { continue }
                table.setWidth(min(max(fitted, 48), Self.widest), forColumnID: column.id)
            }
        }
        onChange()
    }

    /// The widest a column gets to fit its values (longer ones are cut, the inspector shows them).
    static let widest = 480.0

    /// Stops the query (closing its connection; the server is told to kill it).
    func cancel() {
        monitoring?.cancel()
        refreshing?.cancel()
        refreshesLive = false
        guard let running else { return }
        running.cancel()
        self.running = nil
        if isRunning {
            state = .cancelled
            table.sortsRows = true
            onChange()
        }
    }

    // MARK: Killing

    /// What killing the given rows is called, if the view shown can (Kill Query, Kill Mutation).
    var killTitle: String? { view?.killTitle }

    /// Kills the queries or mutations of the given rows (data source rows), then reads the view again.
    /// What Kill sends for rows, read when they're chosen: a live view's rows move
    /// while its question is up, so the ids are taken at once.
    struct KillPlan {
        fileprivate let view: ServerView
        fileprivate let statements: [String]
        fileprivate let localStatements: [String]
        fileprivate let hosts: [String?]
        let cluster: String?
        var killsMutations: Bool { view == .mutations }
    }

    func killPlan(rows: IndexSet) -> KillPlan? {
        guard let view, let source else { return nil }
        let names = source.result.names
        let statements = rows.compactMap { row in
            view.killStatement(cluster: cluster) { name in names.firstIndex(of: name).flatMap { source.fullText(row: row, columnIndex: $0) } }
        }
        guard !statements.isEmpty else { return nil }
        // Without a cluster's Keeper, ON CLUSTER can't run: the rows of this server are killed here,
        // the others' can't be (their servers aren't connected).
        let hosts = rows.map { row in names.firstIndex(of: "host").flatMap { source.fullText(row: row, columnIndex: $0) } }
        let localStatements = rows.compactMap { row in
            view.killStatement { name in names.firstIndex(of: name).flatMap { source.fullText(row: row, columnIndex: $0) } }
        }
        return KillPlan(view: view, statements: statements, localStatements: localStatements, hosts: hosts, cluster: cluster)
    }

    func kill(rows: IndexSet) {
        if let plan = killPlan(rows: rows) { kill(plan) }
    }

    func kill(_ plan: KillPlan) {
        let (view, statements, localStatements, hosts) = (plan.view, plan.statements, plan.localStatements, plan.hosts)
        let thisServer = client.serverInfo?.displayName
        Task { [weak self, client] in
            var failure: Error?
            for (index, statement) in statements.enumerated() {
                do {
                    _ = try await client.plainText(statement + " FORMAT Null")
                } catch let error as CHServerError where error.code == 139 && index < localStatements.count {
                    if hosts[index] == nil || hosts[index] == thisServer {
                        do { _ = try await client.plainText(localStatements[index] + " FORMAT Null") } catch { failure = error }
                    } else {
                        failure = CHServerError(text: "Code: 139. DB::Exception: " + String(localized: "This cluster has no Keeper, so a query on \(hosts[index] ?? "another server") can be killed only by connecting to it."))
                    }
                } catch {
                    failure = error
                }
            }
            guard let self else { return }
            if let failure { onKillFailure(failure) }
            if !isRunning { start(view.sql(cluster: cluster), parameters: [:], refresh: true) }
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
    /// What the window is doing, in short (the toolbar's indicator): the whole is `status`.
    var briefStatus: String {
        let rows = source?.result.rowCount ?? 0
        switch state {
        case .idle:
            return ""
        case .running(let started):
            let seconds = Self.seconds(ContinuousClock.now - started).formatted(.number.precision(.fractionLength(1)))
            return rows > 0 ? String(localized: "Running · \(rows.formatted()) rows · \(seconds) s") : String(localized: "Running · \(seconds) s")
        case .finished(let stats):
            let seconds = Self.seconds(stats.elapsed).formatted(.number.precision(.fractionLength(2)))
            return "\(rowsText(rows)) · \(seconds) s"
        case .failed:
            return String(localized: "Failed")
        case .cancelled:
            return String(localized: "Cancelled")
        }
    }

    /// How far a running query has read, when the server knows how much it will (0…1).
    var progressFraction: Double? { isRunning ? progress?.fraction : nil }

    var status: String {
        let rows = source?.result.rowCount ?? 0
        var parts: [String] = []
        var state = state
        if isRefreshing, let lastStats { state = .finished(lastStats) }
        switch state {
        case .idle:
            return ""
        case .running(let started):
            let seconds = Self.seconds(ContinuousClock.now - started)
            parts.append(rows > 0 ? String(localized: "Receiving… \(rows.formatted()) rows") : String(localized: "Running…"))
            parts.append(String(localized: "\(seconds.formatted(.number.precision(.fractionLength(1)))) s"))
            if let progress, progress.readRows > 0 {
                let read = progress.readRows.formatted(.number.notation(.compactName))
                if let fraction = progress.fraction {
                    let total = progress.totalRows.formatted(.number.notation(.compactName))
                    parts.append(String(localized: "read \(read) of \(total) rows (\(fraction.formatted(.percent.precision(.fractionLength(0)))))"))
                } else {
                    parts.append(String(localized: "read \(read) rows"))
                }
                parts.append(Self.bytes(progress.readBytes))
                if progress.memory > 0 { parts.append(String(localized: "\(Self.bytes(progress.memory)) memory")) }
            }
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
            if let server = serverStats {
                let read = server.readRows.formatted(.number.notation(.compactName))
                parts.append(String(localized: "server: \(server.duration.formatted(.number.precision(.fractionLength(3)))) s, read \(read) rows, \(Self.bytes(server.readBytes)), \(Self.bytes(server.memory)) memory"))
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
        if let view, let refreshed, !isRunning || isRefreshing {
            parts.insert(cluster.map { "\(view.title) · \($0)" } ?? view.title, at: 0)
            if view.isLive { parts.append(String(localized: "live, read at \(refreshed.formatted(date: .omitted, time: .standard))")) }
        }
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

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .memory)
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

extension Error {
    /// What the viewer says of an error.
    /// The first paragraph of `viewerDescription`: a server's error can go on
    /// for a page (where its passwords are kept, …), the rest is in details.
    var viewerSummary: String { viewerDescription.firstParagraph }

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
        case let error as CHSSHTunnel.Failure: return error.description
        case let error as CHSSHKey.Failure: return error.description
        default: return localizedDescription
        }
    }
}

extension String {
    /// The text up to its first empty line.
    var firstParagraph: String {
        let text = trimmingCharacters(in: .whitespacesAndNewlines)
        return text.components(separatedBy: "\n\n").first ?? text
    }
}
