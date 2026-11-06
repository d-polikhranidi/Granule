import Foundation

/// How far a running query is, as the server's `system.processes` says.
public struct CHQueryProgress: Sendable, Equatable {
    public var readRows: Int
    public var readBytes: Int
    /// The rows it expects to read in all (0 when it can't tell).
    public var totalRows: Int
    public var memory: Int
    public var elapsed: Double

    /// The share read, 0...1, if the server knows the total.
    public var fraction: Double? { totalRows > 0 ? min(1, Double(readRows) / Double(totalRows)) : nil }
}

/// A finished query's numbers, as the server logged them (`system.query_log`).
public struct CHServerStats: Sendable, Equatable {
    public var readRows: Int
    public var readBytes: Int
    public var memory: Int
    public var duration: Double
    public var resultRows: Int
}

extension CHClient {
    /// A running query's progress (`nil` once it's gone, or for a user who can't see it).
    public func progress(of queryID: String) async throws -> CHQueryProgress? {
        let text = try await plainText("""
            SELECT read_rows, read_bytes, total_rows_approx, memory_usage, elapsed
            FROM system.processes WHERE query_id = \(CHSQL.quotedString(queryID)) FORMAT TSV
            """)
        let fields = text.trimmingCharacters(in: .newlines).split(separator: "\t").map(String.init)
        guard fields.count >= 5 else { return nil }
        return CHQueryProgress(readRows: Int(fields[0]) ?? 0, readBytes: Int(fields[1]) ?? 0, totalRows: Int(fields[2]) ?? 0,
                               memory: Int(fields[3]) ?? 0, elapsed: Double(fields[4]) ?? 0)
    }

    /// A finished query's numbers from the log (`nil` until the server writes
    /// it there, every 7.5 s by default, or for a user who can't read it).
    public func serverStats(of queryID: String) async throws -> CHServerStats? {
        let text = try await plainText("""
            SELECT read_rows, read_bytes, memory_usage, query_duration_ms, result_rows
            FROM system.query_log
            WHERE query_id = \(CHSQL.quotedString(queryID)) AND type != 'QueryStart' AND event_date >= yesterday()
            ORDER BY event_time DESC LIMIT 1 FORMAT TSV
            """)
        let fields = text.trimmingCharacters(in: .newlines).split(separator: "\t").map(String.init)
        guard fields.count >= 5 else { return nil }
        return CHServerStats(readRows: Int(fields[0]) ?? 0, readBytes: Int(fields[1]) ?? 0, memory: Int(fields[2]) ?? 0,
                             duration: (Double(fields[3]) ?? 0) / 1000, resultRows: Int(fields[4]) ?? 0)
    }
}
