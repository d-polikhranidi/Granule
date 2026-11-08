import Foundation

/// What a query reads, as the server estimates it from its tables' indexes
/// without running it (`EXPLAIN ESTIMATE`): MergeTree tables only, the rows of
/// the parts and granules its conditions leave, before any LIMIT.
public struct CHEstimate: Sendable, Equatable {
    public struct Table: Sendable, Equatable {
        public var database: String
        public var name: String
        public var parts: Int
        public var rows: Int
        public var marks: Int
    }

    public var tables: [Table]

    /// The rows of every table read.
    public var rows: Int { tables.reduce(0) { $0 + $1.rows } }
}

extension CHClient {
    /// The server's estimate of what a query reads, within two seconds (marked as the
    /// viewer's own). `database`: the one names without one are in (the session's).
    /// A user who may set no settings (readonly = 1) gets no time limit: a query with a scalar
    /// subquery isn't estimated then (the plan runs it, as names are checked: `check`).
    public func estimate(_ query: String, parameters: [String: String] = [:], database: String? = nil) async throws -> CHEstimate {
        guard maySetSettings || !CHSQL.mayHaveScalarSubquery(query) else { return CHEstimate(tables: []) }
        var settings = ["default_format": "TSV"]
        if maySetSettings {
            settings["max_execution_time"] = "2"
            settings["timeout_overflow_mode"] = "throw"
        }
        let text = try await plainText("EXPLAIN ESTIMATE " + query, settings: settings, database: database,
                                       parameters: parameters, background: true)
        let tables = text.split(separator: "\n").compactMap { line -> CHEstimate.Table? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 5, let parts = Int(fields[2]), let rows = Int(fields[3]), let marks = Int(fields[4]) else { return nil }
            return CHEstimate.Table(database: String(fields[0]), name: String(fields[1]), parts: parts, rows: rows, marks: marks)
        }
        return CHEstimate(tables: tables)
    }
}
