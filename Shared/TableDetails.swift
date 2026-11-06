import ClickHouseCore
import Foundation

/// A table's details, each a result of its own (they sort and search like
/// any): its engine and keys, columns with their codecs and compression,
/// partitions, parts, skip indexes, projections, and what reads it or what
/// it writes to.
nonisolated enum TableDetail: String, CaseIterable, Sendable {
    case overview, columns, partitions, parts, indexes, projections, dependencies

    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .columns: String(localized: "Columns")
        case .partitions: String(localized: "Partitions")
        case .parts: String(localized: "Parts")
        case .indexes: String(localized: "Skip Indexes")
        case .projections: String(localized: "Projections")
        case .dependencies: String(localized: "Dependencies")
        }
    }

    func sql(database: String, table: String) -> String {
        let db = CHSQL.quotedString(database), name = CHSQL.quotedString(table)
        let partsOf = "database = \(db) AND table = \(name)"
        switch self {
        case .overview:
            return """
                SELECT p.1 AS property, p.2 AS value
                FROM system.tables
                ARRAY JOIN [
                    ('Engine', engine_full), ('Sorting key', sorting_key), ('Primary key', primary_key),
                    ('Partition key', partition_key), ('Sampling key', sampling_key), ('Storage policy', storage_policy),
                    ('Rows', toString(total_rows)), ('Bytes on disk', formatReadableSize(total_bytes)),
                    ('Rows ever inserted', toString(lifetime_rows)), ('Comment', comment),
                    ('Metadata changed', toString(metadata_modification_time)), ('Statement', create_table_query)
                ] AS p
                WHERE database = \(db) AND name = \(name)
                """
        case .columns:
            return """
                SELECT name, type, default_kind, default_expression, compression_codec,
                       data_compressed_bytes AS compressed, data_uncompressed_bytes AS uncompressed,
                       round(data_uncompressed_bytes / greatest(data_compressed_bytes, 1), 2) AS ratio,
                       is_in_partition_key, is_in_sorting_key, is_in_primary_key, is_in_sampling_key, comment
                FROM system.columns
                WHERE \(partsOf)
                ORDER BY position
                """
        case .partitions:
            return """
                SELECT partition, count() AS parts, sum(rows) AS rows, sum(bytes_on_disk) AS bytes_on_disk,
                       sum(data_compressed_bytes) AS compressed, sum(data_uncompressed_bytes) AS uncompressed,
                       round(sum(data_uncompressed_bytes) / greatest(sum(data_compressed_bytes), 1), 2) AS ratio,
                       min(min_time) AS first_time, max(max_time) AS last_time, max(modification_time) AS modified
                FROM system.parts
                WHERE \(partsOf) AND active
                GROUP BY partition
                ORDER BY partition
                """
        case .parts:
            return """
                SELECT name, partition, rows, bytes_on_disk, data_compressed_bytes AS compressed,
                       data_uncompressed_bytes AS uncompressed, marks, level, part_type, modification_time, disk_name
                FROM system.parts
                WHERE \(partsOf) AND active
                ORDER BY partition, name
                """
        case .indexes:
            return """
                SELECT name, type, expr, granularity, data_compressed_bytes AS compressed, data_uncompressed_bytes AS uncompressed
                FROM system.data_skipping_indices
                WHERE \(partsOf)
                """
        case .projections:
            return """
                SELECT name, count() AS parts, sum(rows) AS rows, sum(bytes_on_disk) AS bytes_on_disk,
                       sum(data_compressed_bytes) AS compressed, sum(data_uncompressed_bytes) AS uncompressed
                FROM system.projection_parts
                WHERE \(partsOf) AND active
                GROUP BY name
                ORDER BY name
                """
        case .dependencies:
            // The views that read it (as the server lists them), and for a
            // materialized view the table it writes to (TO … in its statement).
            return """
                SELECT 'read by' AS relation, concat(dependency.1, '.', dependency.2) AS object, '' AS kind
                FROM system.tables
                ARRAY JOIN arrayZip(dependencies_database, dependencies_table) AS dependency
                WHERE database = \(db) AND name = \(name)
                UNION ALL
                SELECT 'writes to', extract(create_table_query, '\\\\sTO\\\\s+([^\\\\s(]+)'), 'materialized view target'
                FROM system.tables
                WHERE database = \(db) AND name = \(name) AND engine = 'MaterializedView'
                  AND extract(create_table_query, '\\\\sTO\\\\s+([^\\\\s(]+)') != ''
                UNION ALL
                SELECT 'reads from', concat(database, '.', name), engine
                FROM system.tables
                WHERE has(arrayZip(dependencies_database, dependencies_table), (\(db), \(name)))
                """
        }
    }
}
