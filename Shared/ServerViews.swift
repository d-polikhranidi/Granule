import ClickHouseCore
import Foundation

/// What the server is doing, as tables: the statements behind the sidebar's
/// Server section. Their rows sort, search and sum like any result's; live
/// ones refresh every two seconds; queries and mutations can be killed.
nonisolated enum ServerView: String, CaseIterable, Hashable, Sendable {
    case processes, recentQueries, queryPatterns, failedQueries, merges, mutations, tableSizes, columnSizes, replicas,
         replicationQueue, errors, disks, settings, metrics

    var title: String {
        switch self {
        case .processes: String(localized: "Running Queries")
        case .recentQueries: String(localized: "Recent Queries")
        case .queryPatterns: String(localized: "Query Patterns")
        case .failedQueries: String(localized: "Failed Queries")
        case .merges: String(localized: "Merges")
        case .mutations: String(localized: "Mutations")
        case .tableSizes: String(localized: "Table Sizes")
        case .columnSizes: String(localized: "Column Sizes")
        case .replicas: String(localized: "Replicas")
        case .replicationQueue: String(localized: "Replication Queue")
        case .errors: String(localized: "Errors")
        case .disks: String(localized: "Disks")
        case .settings: String(localized: "Changed Settings")
        case .metrics: String(localized: "Metrics")
        }
    }

    var symbol: String {
        switch self {
        case .processes: "bolt.horizontal"
        case .recentQueries: "clock"
        case .queryPatterns: "flame"
        case .failedQueries: "exclamationmark.triangle"
        case .merges: "arrow.triangle.merge"
        case .mutations: "pencil.and.list.clipboard"
        case .tableSizes: "internaldrive"
        case .columnSizes: "chart.bar.xaxis"
        case .replicas: "square.on.square"
        case .replicationQueue: "list.number"
        case .errors: "xmark.octagon"
        case .disks: "externaldrive"
        case .settings: "slider.horizontal.3"
        case .metrics: "gauge.with.dots.needle.33percent"
        }
    }

    /// Whether it changes from second to second (it's run again while shown).
    var isLive: Bool {
        switch self {
        case .processes, .merges, .mutations, .replicas, .replicationQueue, .metrics: true
        default: false
        }
    }

    /// The column that tells a row (selection follows it across refreshes).
    var identifierColumn: String? {
        switch self {
        case .processes: "query_id"
        case .merges: "result_part_name"
        case .mutations: "mutation_id"
        default: nil
        }
    }

    var sql: String {
        switch self {
        case .processes:
            """
            SELECT query_id, user, elapsed, read_rows, read_bytes, total_rows_approx, memory_usage, peak_memory_usage,
                   written_rows, is_cancelled, query_kind, query
            FROM system.processes
            WHERE query NOT LIKE '%system.processes%'
            ORDER BY elapsed DESC
            """
        case .recentQueries:
            """
            SELECT event_time, type, query_duration_ms, read_rows, read_bytes, result_rows, memory_usage, user,
                   exception_code, query_kind, query_id, query
            FROM system.query_log
            WHERE event_date >= yesterday() AND event_time > now() - INTERVAL 1 HOUR AND type != 'QueryStart'
            ORDER BY event_time DESC
            LIMIT 100000
            """
        case .queryPatterns:
            """
            SELECT count() AS runs, sum(query_duration_ms) AS total_ms, round(avg(query_duration_ms)) AS avg_ms,
                   max(query_duration_ms) AS max_ms, sum(read_rows) AS read_rows, sum(read_bytes) AS read_bytes,
                   max(memory_usage) AS max_memory, normalized_query_hash, any(query) AS example
            FROM system.query_log
            WHERE event_date >= yesterday() AND event_time > now() - INTERVAL 1 DAY AND type = 'QueryFinish'
            GROUP BY normalized_query_hash
            ORDER BY total_ms DESC
            LIMIT 1000
            """
        case .failedQueries:
            """
            SELECT event_time, exception_code, exception, query_duration_ms, user, query_id, query
            FROM system.query_log
            WHERE event_date >= yesterday() AND event_time > now() - INTERVAL 1 DAY
              AND type IN ('ExceptionBeforeStart', 'ExceptionWhileProcessing')
            ORDER BY event_time DESC
            LIMIT 10000
            """
        case .merges:
            """
            SELECT database, table, elapsed, round(progress * 100, 1) AS percent,
                   round(elapsed / greatest(progress, 0.001) - elapsed) AS seconds_left, num_parts, result_part_name,
                   total_size_bytes_compressed, rows_read, rows_written, memory_usage, merge_type, merge_algorithm
            FROM system.merges
            ORDER BY elapsed DESC
            """
        case .mutations:
            """
            SELECT database, table, mutation_id, command, create_time, parts_to_do, is_done, latest_fail_reason, latest_fail_time
            FROM system.mutations
            WHERE NOT is_done OR create_time > now() - INTERVAL 1 DAY
            ORDER BY is_done, create_time DESC
            """
        case .tableSizes:
            """
            SELECT database, table, count() AS parts, sum(rows) AS rows, sum(bytes_on_disk) AS bytes_on_disk,
                   sum(data_compressed_bytes) AS compressed, sum(data_uncompressed_bytes) AS uncompressed,
                   round(sum(data_uncompressed_bytes) / greatest(sum(data_compressed_bytes), 1), 2) AS ratio,
                   uniqExact(partition) AS partitions, max(modification_time) AS modified
            FROM system.parts
            WHERE active
            GROUP BY database, table
            ORDER BY bytes_on_disk DESC
            """
        case .columnSizes:
            """
            SELECT database, table, column, any(type) AS type, sum(column_data_compressed_bytes) AS compressed,
                   sum(column_data_uncompressed_bytes) AS uncompressed,
                   round(sum(column_data_uncompressed_bytes) / greatest(sum(column_data_compressed_bytes), 1), 2) AS ratio
            FROM system.parts_columns
            WHERE active
            GROUP BY database, table, column
            ORDER BY compressed DESC
            LIMIT 100000
            """
        case .replicas:
            """
            SELECT database, table, is_leader, is_readonly, absolute_delay, queue_size, inserts_in_queue, merges_in_queue,
                   total_replicas, active_replicas, last_queue_update, zookeeper_exception
            FROM system.replicas
            ORDER BY absolute_delay DESC, queue_size DESC
            """
        case .replicationQueue:
            """
            SELECT database, table, type, create_time, num_tries, last_attempt_time, last_exception, postpone_reason, new_part_name
            FROM system.replication_queue
            ORDER BY create_time
            """
        case .errors:
            """
            SELECT last_error_time, name, code, value AS count, last_error_message
            FROM system.errors
            ORDER BY last_error_time DESC
            """
        case .disks:
            """
            SELECT name, path, free_space, total_space, round(100 - free_space / greatest(total_space, 1) * 100, 1) AS used_percent,
                   keep_free_space, type
            FROM system.disks
            """
        case .settings:
            "SELECT name, value, default, description FROM system.settings WHERE changed ORDER BY name"
        case .metrics:
            "SELECT metric, value, description FROM system.metrics ORDER BY metric"
        }
    }

    /// A row's kill statement, from its values by column name (`nil`: none for this view).
    func killStatement(_ value: (String) -> String?) -> String? {
        switch self {
        case .processes, .recentQueries:
            guard let id = value("query_id") else { return nil }
            return "KILL QUERY WHERE query_id = \(CHSQL.quotedString(id)) ASYNC"
        case .mutations:
            guard let database = value("database"), let table = value("table"), let id = value("mutation_id") else { return nil }
            return "KILL MUTATION WHERE database = \(CHSQL.quotedString(database)) AND table = \(CHSQL.quotedString(table)) AND mutation_id = \(CHSQL.quotedString(id))"
        default:
            return nil
        }
    }

    /// What killing the selected rows is called.
    var killTitle: String? {
        switch self {
        case .processes: String(localized: "Kill Query")
        case .mutations: String(localized: "Kill Mutation")
        default: nil
        }
    }

    /// The view a statement shows, if it's one of these as they were run.
    static func view(of sql: String) -> ServerView? {
        allCases.first { $0.sql == sql }
    }
}
