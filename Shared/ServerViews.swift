import ClickHouseCore
import Foundation

/// What the server is doing, as tables: the statements behind the sidebar's
/// Server section. Their rows sort, search and sum like any result's; live
/// ones refresh every two seconds; queries and mutations can be killed.
nonisolated enum ServerView: String, CaseIterable, Hashable, Sendable {
    case health, processes, recentQueries, queryPatterns, failedQueries, merges, mutations, tableSizes, columnSizes, replicas,
         replicationQueue, dictionaries, errors, disks, settings, metrics

    var title: String {
        switch self {
        case .health: String(localized: "Health")
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
        case .dictionaries: String(localized: "Dictionaries")
        case .errors: String(localized: "Errors")
        case .disks: String(localized: "Disks")
        case .settings: String(localized: "Changed Settings")
        case .metrics: String(localized: "Metrics")
        }
    }

    var symbol: String {
        switch self {
        case .health: "stethoscope"
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
        case .dictionaries: "character.book.closed"
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

    /// The viewer's own queries' mark (progress, checks, these views): this user's are
    /// left out of them; another user's viewer still shows, to be seen and killed.
    private static let ownComment = CHSQL.quotedString(CHClient.backgroundComment)

    var sql: String {
        switch self {
        case .health:
            Self.healthSQL(cluster: nil)
        case .processes:
            """
            SELECT query_id, user, elapsed, read_rows, read_bytes, total_rows_approx, memory_usage, peak_memory_usage,
                   written_rows, is_cancelled, query_kind, query
            FROM system.processes
            WHERE query NOT LIKE '%system.processes%' AND NOT (Settings['log_comment'] = \(Self.ownComment) AND user = currentUser())
            ORDER BY elapsed DESC
            """
        case .recentQueries:
            """
            SELECT event_time, type, query_duration_ms, read_rows, read_bytes, result_rows, memory_usage, user,
                   exception_code, query_kind, query_id, query
            FROM system.query_log
            WHERE event_date >= yesterday() AND event_time > now() - INTERVAL 1 HOUR AND type != 'QueryStart'
              AND NOT (log_comment = \(Self.ownComment) AND user = currentUser())
            ORDER BY event_time DESC
            LIMIT 100000
            """
        case .queryPatterns:
            """
            SELECT count() AS runs, sum(query_duration_ms) AS total_ms, round(avg(query_duration_ms)) AS avg_ms,
                   round(quantile(0.5)(query_duration_ms)) AS p50_ms, round(quantile(0.9)(query_duration_ms)) AS p90_ms,
                   round(quantile(0.99)(query_duration_ms)) AS p99_ms,
                   max(query_duration_ms) AS max_ms, sum(read_rows) AS read_rows, sum(read_bytes) AS read_bytes,
                   max(memory_usage) AS max_memory, normalized_query_hash, any(query) AS example
            FROM system.query_log
            WHERE event_date >= yesterday() AND event_time > now() - INTERVAL 1 DAY AND type = 'QueryFinish'
              AND NOT (log_comment = \(Self.ownComment) AND user = currentUser())
            GROUP BY normalized_query_hash
            ORDER BY total_ms DESC
            LIMIT 1000
            """
        case .failedQueries:
            """
            SELECT event_time, exception_code, exception, query_duration_ms, user, query_id, query
            FROM system.query_log
            WHERE event_date >= yesterday() AND event_time > now() - INTERVAL 1 DAY
              AND type IN ('ExceptionBeforeStart', 'ExceptionWhileProcessing') AND NOT (log_comment = \(Self.ownComment) AND user = currentUser())
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
        case .dictionaries:
            """
            SELECT database, name, status, type, element_count, bytes_allocated, loading_duration, last_successful_update_time,
                   query_count, hit_rate, found_rate, source, origin, last_exception
            FROM system.dictionaries
            ORDER BY last_exception = '', status = 'LOADED', database, name
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

    /// The statement across a cluster's servers: each system table read on
    /// every replica (`clusterAllReplicas`), the server's name first (`host`),
    /// aggregates per server.
    func sql(cluster: String?) -> String {
        guard let cluster else { return sql }
        if self == .health { return Self.healthSQL(cluster: cluster) }
        var text = sql
        text = text.replacingOccurrences(of: #"FROM system\.(\w+)"#, with: "FROM clusterAllReplicas(\(CHSQL.quotedString(cluster)), system.$1)",
                                         options: .regularExpression)
        if let select = text.range(of: "SELECT ") { text.replaceSubrange(select, with: "SELECT hostName() AS host, ") }
        if let group = text.range(of: "GROUP BY ") { text.replaceSubrange(group, with: "GROUP BY host, ") }
        return text
    }

    /// Health: what needs a look, one row a finding, errors first (nothing when all is
    /// well): replicas behind, read only or out of their Keeper session; partitions with
    /// so many parts that inserts slow down (the server's `parts_to_delay_insert`) or fail;
    /// mutations that fail or run for over an hour; the replication queue's entries tried
    /// again and again; detached parts; disks nearly full; the server's memory nearly all
    /// used; inserts delayed; dictionaries that failed to load; queries over ten minutes
    /// and merges over an hour. Across a cluster each check reads every replica. (No scalar
    /// subqueries: 23.8's analyzer loses a column made with one in a UNION's branch.)
    static func healthSQL(cluster: String?) -> String {
        func from(_ table: String) -> String {
            cluster.map { "clusterAllReplicas(\(CHSQL.quotedString($0)), system.\(table))" } ?? "system.\(table)"
        }
        let host = cluster == nil ? "" : "hostName() AS host, ", byHost = cluster == nil ? "" : "host, "
        let checks = [
            """
            SELECT \(host)if(is_readonly OR is_session_expired OR absolute_delay > 600, 'Error', 'Warning') AS status, 'Replica' AS check,
                   concat(database, '.', table) AS subject,
                   multiIf(is_readonly, 'read only', is_session_expired, 'Keeper session expired',
                           concat(toString(absolute_delay), ' s behind')) AS value,
                   concat(toString(queue_size), ' in its queue, ', toString(active_replicas), ' of ', toString(total_replicas),
                          ' replicas active', if(zookeeper_exception = '', '', concat(': ', zookeeper_exception))) AS detail
            FROM \(from("replicas"))
            WHERE is_readonly OR is_session_expired OR absolute_delay > 60 OR queue_size > 100
            """,
            """
            SELECT \(byHost)if(parts >= delay, 'Error', 'Warning'), 'Parts', concat(database, '.', table),
                   concat(toString(parts), ' parts in partition ', partition_id),
                   concat('inserts slow down at ', toString(delay), ' (parts_to_delay_insert): merges are behind, or inserts too small and too many')
            FROM (SELECT \(host)database, table, partition_id, count() AS parts FROM \(from("parts")) WHERE active
                  GROUP BY \(byHost)database, table, partition_id) AS counted
            CROSS JOIN (SELECT toUInt64(value) AS delay FROM system.merge_tree_settings WHERE name = 'parts_to_delay_insert') AS limits
            WHERE parts >= delay / 2
            """,
            """
            SELECT \(host)if(latest_fail_reason = '', 'Warning', 'Error'), 'Mutation', concat(database, '.', table),
                   concat(mutation_id, ': ', substring(command, 1, 120)),
                   if(latest_fail_reason = '', concat('running for ', toString(intDiv(dateDiff('second', create_time, now()), 60)), ' min, ',
                                                     toString(parts_to_do), ' parts to do'), latest_fail_reason)
            FROM \(from("mutations"))
            WHERE NOT is_done AND (latest_fail_reason != '' OR create_time < now() - INTERVAL 1 HOUR)
            """,
            """
            SELECT \(host)'Warning', 'Replication queue', concat(database, '.', table),
                   concat(toString(count()), ' entries tried up to ', toString(max(num_tries)), ' times'),
                   any(last_exception)
            FROM \(from("replication_queue"))
            WHERE num_tries > 100 OR (last_exception != '' AND num_tries > 10)
            GROUP BY \(byHost)database, table
            """,
            """
            SELECT \(host)'Warning', 'Detached parts', concat(database, '.', table), concat(toString(count()), ' detached'),
                   concat('reason: ', if(reason = '', 'detached by hand', reason))
            FROM \(from("detached_parts"))
            GROUP BY \(byHost)database, table, reason
            """,
            """
            SELECT \(host)if(free_space < total_space / 20, 'Error', 'Warning'), 'Disk', name,
                   concat(toString(round(100 - free_space / total_space * 100, 1)), '% used'),
                   concat(formatReadableSize(free_space), ' free of ', formatReadableSize(total_space), ' at ', path)
            FROM \(from("disks"))
            WHERE total_space > 0 AND free_space < total_space / 10
            """,
            """
            SELECT \(host)'Warning', 'Memory', 'server', concat(toString(round(maxIf(value, metric = 'MemoryResident') / maxIf(value, metric = 'OSMemoryTotal') * 100)), '% used'),
                   concat(formatReadableSize(maxIf(value, metric = 'MemoryResident')), ' of ', formatReadableSize(maxIf(value, metric = 'OSMemoryTotal')))
            FROM \(from("asynchronous_metrics"))
            WHERE metric IN ('MemoryResident', 'OSMemoryTotal')
            \(cluster == nil ? "" : "GROUP BY host")
            HAVING maxIf(value, metric = 'OSMemoryTotal') > 0 AND maxIf(value, metric = 'MemoryResident') > maxIf(value, metric = 'OSMemoryTotal') * 0.9
            """,
            """
            SELECT \(host)'Warning', 'Inserts', 'server', concat(toString(value), ' delayed now'),
                   'a partition has too many parts: inserts wait for merges'
            FROM \(from("metrics"))
            WHERE metric = 'DelayedInserts' AND value > 0
            """,
            """
            SELECT \(host)'Error', 'Dictionary', concat(database, if(database = '', '', '.'), name), toString(status), last_exception
            FROM \(from("dictionaries"))
            WHERE last_exception != ''
            """,
            """
            SELECT \(host)'Warning', 'Query', query_id, concat('running for ', toString(round(elapsed)), ' s by ', user), substring(query, 1, 200)
            FROM \(from("processes"))
            WHERE elapsed > 600 AND NOT (Settings['log_comment'] = \(ownComment) AND user = currentUser())
            """,
            """
            SELECT \(host)'Warning', 'Merge', concat(database, '.', table), concat('running for ', toString(round(elapsed / 60)), ' min'),
                   concat(toString(round(progress * 100)), '% done, ', toString(num_parts), ' parts into ', result_part_name)
            FROM \(from("merges"))
            WHERE elapsed > 3600
            """,
        ]
        let columns = (cluster == nil ? "" : "host, ") + "status, check, subject, value, detail"
        return "SELECT \(columns) FROM (\n" + checks.joined(separator: "\nUNION ALL\n") + "\n)\nORDER BY status = 'Error' DESC, check, subject"
    }

    /// A row's kill statement, from its values by column name (`nil`: none
    /// for this view), on every server of the cluster if given.
    func killStatement(cluster: String? = nil, _ value: (String) -> String?) -> String? {
        let onCluster = cluster.map { " ON CLUSTER \(CHSQL.quotedName($0))" } ?? ""
        switch self {
        case .processes, .recentQueries:
            guard let id = value("query_id") else { return nil }
            return "KILL QUERY\(onCluster) WHERE query_id = \(CHSQL.quotedString(id)) ASYNC"
        case .mutations:
            guard let database = value("database"), let table = value("table"), let id = value("mutation_id") else { return nil }
            return "KILL MUTATION\(onCluster) WHERE database = \(CHSQL.quotedString(database)) AND table = \(CHSQL.quotedString(table)) AND mutation_id = \(CHSQL.quotedString(id))"
        default:
            return nil
        }
    }

    /// The clusters a server knows with more than itself in them (their names).
    static func clusters(_ client: CHClient) async -> [String] {
        let rows = (try? await client.result("""
            SELECT cluster FROM system.clusters GROUP BY cluster HAVING count() > 1 OR countIf(is_local = 0) > 0 ORDER BY cluster
            """))?.rows() ?? []
        return rows.compactMap(\.first)
    }

    /// What killing the selected rows is called.
    var killTitle: String? {
        switch self {
        case .processes: String(localized: "Kill Query")
        case .mutations: String(localized: "Kill Mutation")
        default: nil
        }
    }


}
