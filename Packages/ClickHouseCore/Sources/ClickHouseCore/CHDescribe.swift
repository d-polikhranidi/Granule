import Foundation

/// A session's lock: ClickHouse refuses a second query in a session while one runs there.
public let chSessionIsLocked = 373

extension CHClient {
    /// The body run again while the server says the session is busy (`SESSION_IS_LOCKED`, as
    /// just after a query in it was dropped), for up to about three seconds.
    public func whenSessionIsFree<T>(_ body: () async throws -> T) async throws -> T {
        var tries = 0
        while true {
            do {
                return try await body()
            } catch let error as CHServerError where error.code == chSessionIsLocked && tries < 20 {
                tries += 1
                try await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// A query's result columns the viewer can't read (`AggregateFunction` states and the
    /// like), as the server describes the result without running it (`DESCRIBE (…)`, marked
    /// as the viewer's own): all of them rewritten at once, not one run each. Outside the
    /// session first, in `database` (the session's after a USE): the query that just failed
    /// may still hold the session (a remote server takes a while to drop it); in the session
    /// (a temporary table lives there) once it's free.
    public func unreadableColumns(of query: String, parameters: [String: String] = [:], database: String? = nil,
                                  sessionID: String? = nil) async throws -> [(name: String, type: String)] {
        let describe = "DESCRIBE (\n\(query)\n) FORMAT TSVRaw"
        let text: String
        do {
            text = try await plainText(describe, database: database, parameters: parameters, background: true)
        } catch {
            guard let sessionID else { throw error }
            text = try await whenSessionIsFree {
                try await self.plainText(describe, sessionID: sessionID, parameters: parameters, background: true)
            }
        }
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return nil }
            let type = CHType(parsing: String(fields[1]))
            guard !type.isReadable || (!readsJSONAsText && type.containsJSON) else { return nil }
            return (String(fields[0]), String(fields[1]))
        }
    }
}
