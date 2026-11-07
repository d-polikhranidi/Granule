import ClickHouseCore
import Foundation

/// A server's databases and tables, as the sidebar shows them; a table's
/// columns once it's opened.
nonisolated struct Schema {
    nonisolated struct Database: Hashable, Sendable {
        var name: String
        var tables: [Table]
        /// `system`, `INFORMATION_SCHEMA`: listed after the user's.
        var isSystem: Bool { ["system", "information_schema"].contains(name.lowercased()) }
    }

    nonisolated struct Table: Hashable, Sendable {
        var database: String
        var name: String
        var engine: String
        /// Rows and bytes on disk (compressed), when the engine knows them.
        var rows: Int?
        var bytes: Int?
        var comment: String

        var qualifiedName: String { CHSQL.quotedName(database) + "." + CHSQL.quotedName(name) }

        var isView: Bool { engine.hasSuffix("View") }

        /// What the sidebar says beside its name: rows and size.
        var detail: String {
            var parts: [String] = []
            if let rows { parts.append(rows.formatted(.number.notation(.compactName))) }
            if let bytes, bytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
            return parts.joined(separator: " · ")
        }
    }

    nonisolated struct Column: Hashable, Sendable {
        var name: String
        var type: String
        /// DEFAULT, MATERIALIZED, ALIAS, EPHEMERAL (empty for none).
        var defaultKind: String
        var defaultExpression: String
        var comment: String
        var isInPrimaryKey: Bool
        var isInSortingKey: Bool
        var compressedBytes: Int
        var uncompressedBytes: Int

        /// The column's size compressed and its ratio, when it has data.
        var sizeText: String? {
            guard compressedBytes > 0 else { return nil }
            let size = ByteCountFormatter.string(fromByteCount: Int64(compressedBytes), countStyle: .file)
            let ratio = Double(uncompressedBytes) / Double(compressedBytes)
            return "\(size) · ×\(ratio.formatted(.number.precision(.fractionLength(1))))"
        }
    }

    var databases: [Database] = []

    /// The server's databases and tables (system ones last).
    static func load(_ client: CHClient) async throws -> Schema {
        let databases = try await client.result("SELECT name FROM system.databases ORDER BY name")
        let tables = try await client.result("""
            SELECT database, name, engine, total_rows, total_bytes, comment
            FROM system.tables WHERE NOT is_temporary ORDER BY database, name
            """)
        var byDatabase: [String: [Table]] = [:]
        for row in tables.rows() {
            guard row.count >= 6 else { continue }
            byDatabase[row[0], default: []].append(Table(database: row[0], name: row[1], engine: row[2], rows: Int(row[3]),
                                                         bytes: Int(row[4]), comment: row[5]))
        }
        var schema = Schema()
        schema.databases = databases.rows().compactMap(\.first).map { Database(name: $0, tables: byDatabase[$0] ?? []) }
        schema.databases.sort { ($0.isSystem ? 1 : 0, $0.name) < ($1.isSystem ? 1 : 0, $1.name) }
        return schema
    }

    /// A table's columns, in order.
    static func columns(of table: Table, client: CHClient) async throws -> [Column] {
        let result = try await client.result("""
            SELECT name, type, default_kind, default_expression, comment, is_in_primary_key, is_in_sorting_key,
                   data_compressed_bytes, data_uncompressed_bytes
            FROM system.columns WHERE database = \(CHSQL.quotedString(table.database)) AND table = \(CHSQL.quotedString(table.name))
            ORDER BY position
            """)
        return result.rows().compactMap { row in
            guard row.count >= 9 else { return nil }
            return Column(name: row[0], type: row[1], defaultKind: row[2], defaultExpression: row[3], comment: row[4],
                          isInPrimaryKey: row[5] == "1", isInSortingKey: row[6] == "1",
                          compressedBytes: Int(row[7]) ?? 0, uncompressedBytes: Int(row[8]) ?? 0)
        }
    }

    /// A table's `CREATE` statement, as the server writes it.
    static func createStatement(of table: Table, client: CHClient) async throws -> String {
        let text = try await client.plainText("SHOW CREATE TABLE \(table.qualifiedName) FORMAT TSVRaw", background: true)
        return text.trimmingCharacters(in: .newlines)
    }

    /// The statement that shows a table's rows: no ORDER BY (the table sorts
    /// what came), as many rows as the memory allows.
    static func previewStatement(of table: Table) -> String {
        "SELECT * FROM \(table.qualifiedName)"
    }
}
