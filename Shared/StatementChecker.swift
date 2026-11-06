import ClickHouseCore
import Foundation

/// A problem of the editor's text: where (UTF-16, in the whole text), what,
/// and the names the server suggests instead.
struct EditorProblem: Equatable {
    var range: NSRange?
    var message: String
    var suggestions: [String]
    var isError: Bool
    var isFromServer: Bool
    /// The statement it's in.
    var statement: NSRange
}

/// Checks the editor's statements as they're typed: what the text alone
/// tells at once (open quotes, brackets), then the statement at the cursor
/// by the server, half a second after typing stops (its syntax, names and
/// types, without running it). On ClickHouse Cloud the server checks only
/// when asked (Query > Check Statement): a check wakes a sleeping service
/// and keeps it awake.
final class StatementChecker {
    private let client: CHClient
    /// Whether the server checks while typing.
    let isAutomatic: Bool
    /// Called when the problems changed.
    var onChange: () -> Void = {}
    /// The database names without one are in (the session's, after a USE).
    var database: () -> String? = { nil }
    private(set) var problems: [EditorProblem] = []
    /// Whether the server is checking now.
    private(set) var isChecking = false

    private var local: [EditorProblem] = []
    private var text = ""
    private var waiting: Task<Void, Never>?
    private var generation = 0
    /// The server's verdicts by a statement's text: a statement isn't asked
    /// about again until it changes, and its problems move with it.
    private var verdicts: [String: [CHSQL.Problem]] = [:]
    /// A script's statements checked while typing at most (the rest when asked).
    private static let automaticLimit = 30

    init(client: CHClient, isAutomatic: Bool) {
        self.client = client
        self.isAutomatic = isAutomatic
    }

    /// The text changed or the cursor moved.
    func update(text: String, cursor: Int) {
        if text != self.text {
            self.text = text
            generation += 1
            isChecking = false
            local = Self.localProblems(in: text)
            publish()
        }
        guard isAutomatic, client.serverInfo != nil else { return }
        schedule(cursor: cursor, explicit: false)
    }

    /// Query > Check Statement: the statement at the cursor checked again now, names too.
    func checkNow(text: String, cursor: Int) {
        if text != self.text { update(text: text, cursor: cursor) }
        if let range = CHSQL.statement(at: cursor, in: text) { verdicts[(text as NSString).substring(with: range)] = nil }
        schedule(cursor: cursor, explicit: true)
    }

    /// The statements without a verdict, the cursor's first: checked one after
    /// another half a second after typing stops (at once when asked).
    private func schedule(cursor: Int, explicit: Bool) {
        let ranges = CHSQL.statements(text)
        let current = CHSQL.statement(at: cursor, in: text)
        var pending = ranges.filter { range in
            !local.contains { $0.isError && NSIntersectionRange($0.statement, range).length > 0 } || explicit && range == current
        }
        if explicit { pending = current.map { [$0] } ?? [] }
        pending.sort { ($0 == current ? 0 : 1, $0.location) < ($1 == current ? 0 : 1, $1.location) }
        let statements = pending.prefix(explicit ? 1 : Self.automaticLimit).map { (text as NSString).substring(with: $0) }
            .filter { verdicts[$0] == nil }
        guard !statements.isEmpty else { return }
        waiting?.cancel()
        let generation = generation
        waiting = Task { [weak self, client] in
            if !explicit { try? await Task.sleep(for: .milliseconds(600)) }
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.isChecking = true
            self.onChange()
            for statement in statements {
                // While typing: names only without scalar subqueries (checking them runs them).
                let checksNames = explicit || !CHSQL.mayHaveScalarSubquery(statement)
                let found: [CHSQL.Problem]
                do {
                    found = try await client.check(statement, checksNames: checksNames, limit: explicit ? 5 : 1, database: self.database())
                } catch {
                    break
                }
                guard !Task.isCancelled else { return }
                if self.verdicts.count > 500 { self.verdicts.removeAll() }
                self.verdicts[statement] = found
                if self.generation == generation { self.publish() }
            }
            self.isChecking = false
            if self.generation == generation { self.publish() }
        }
    }

    /// The problems: the text's own, and the server's verdicts on its statements where they are now.
    private func publish() {
        var server: [EditorProblem] = []
        for range in CHSQL.statements(text) {
            guard let verdict = verdicts[(text as NSString).substring(with: range)] else { continue }
            server += verdict.map { problem in
                EditorProblem(range: problem.range.map { NSRange(location: $0.location + range.location, length: $0.length) },
                              message: problem.message, suggestions: problem.suggestions, isError: problem.severity == .error,
                              isFromServer: true, statement: range)
            }
        }
        problems = local + server
        onChange()
    }

    private static func localProblems(in text: String) -> [EditorProblem] {
        CHSQL.statements(text).flatMap { range in
            CHSQL.localProblems(in: (text as NSString).substring(with: range)).map { problem in
                EditorProblem(range: problem.range.map { NSRange(location: $0.location + range.location, length: $0.length) },
                              message: problem.message, suggestions: problem.suggestions, isError: problem.severity == .error,
                              isFromServer: false, statement: range)
            }
        }
    }

    /// The problem to show: the one at the cursor, or of its statement, or the first.
    func problem(at cursor: Int) -> EditorProblem? {
        problems.first { $0.range.map { NSLocationInRange(cursor, $0) || NSMaxRange($0) == cursor } ?? false }
            ?? problems.first { NSLocationInRange(cursor, $0.statement) || NSMaxRange($0.statement) == cursor }
            ?? problems.first
    }
}
