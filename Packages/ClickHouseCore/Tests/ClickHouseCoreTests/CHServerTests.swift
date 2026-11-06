import ClickHouseCore
import Foundation
import Testing

/// Tests against a running server: `CH_TEST_URL` (e.g. http://localhost:18123),
/// `CH_TEST_PASSWORD`. Skipped without one. A server for them:
/// `docker run -d --name chviewer-dev -p 18123:8123 -e CLICKHOUSE_PASSWORD=viewer clickhouse/clickhouse-server`.
enum TestServer {
    static let client: CHClient? = {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["CH_TEST_URL"], let (endpoint, password) = CHEndpoint.parse(url) else { return nil }
        return CHClient(endpoint: endpoint, password: environment["CH_TEST_PASSWORD"] ?? password ?? "")
    }()

    static var isAvailable: Bool { client != nil }

    static func connected() async throws -> CHClient {
        let client = try #require(client)
        try await client.connect(timeout: 10)
        return client
    }
}

@Suite(.enabled(if: TestServer.isAvailable, "CH_TEST_URL names no server"), .serialized)
struct CHServerTests {
    /// Settings that let the tests make every type.
    static let typeSettings = [
        "allow_experimental_variant_type": "1", "allow_experimental_dynamic_type": "1", "enable_json_type": "1",
        "enable_time_time64_type": "1", "allow_suspicious_low_cardinality_types": "1",
    ]

    /// Values of every type: the text the viewer writes is the server's own (`TSVRaw`).
    static let expressions: [String] = [
        "number", "toInt8(number) - 1", "toInt16(-300 + number)", "toInt32(-70000 * number)", "toInt64(-9223372036854775807 + number)",
        "toUInt64(18446744073709551615 - number)", "toInt128('-170141183460469231731687303715884105728')", "toUInt128(number * 1000000007)",
        "toInt256('-57896044618658097711785492504343953926634992332820282019728792003956564819968')",
        "toUInt256('115792089237316195423570985008687907853269984665640564039457584007913129639935')",
        "number * 1.5", "1 / (number + 3)", "toFloat32(number / 7)", "1e16 * (number + 1)", "1e21 * (number + 1)", "1e-7 / (number + 1)",
        "-0.", "inf", "-inf", "nan", "toBFloat16(0.1 + number)",
        "toDecimal32(number - 1.25, 2)", "toDecimal64('-0.05', 3)", "toDecimal128('12345678901234567890.123456789', 9)",
        "toDecimal256('-1.5', 40)", "toDecimal64(number, 4)",
        "toDate('2026-01-02') + number", "toDate32('1900-01-01') + number", "toDateTime('2026-03-29 00:30:00', 'Europe/Berlin') + 3600 * number",
        "toDateTime('2026-01-02 03:04:05')", "toDateTime64('1969-12-31 23:59:59.123', 3, 'UTC') + number",
        "toDateTime64('2026-01-02 03:04:05.123456789', 9, 'Asia/Kolkata')", "toDateTime('2026-10-25 01:30:00', 'Europe/London') + 1800 * number",
        "'-01:02:03.5'::Time64(1)", "CAST(360000 + number AS Time)",
        "'text ' || toString(number)", "''", "'tab\\there'", "'quote '' and \\\\ slash'", "'Юникод и 中文'",
        "toFixedString('ab', 4)", "toUUID('01234567-89ab-cdef-0123-456789abcdef')", "generateUUIDv4(number) = generateUUIDv4(number)",
        "toIPv4('1.2.3.4')", "toIPv6('2001:db8::1')", "toIPv6('1.2.3.4')",
        "true", "number % 2 = 0", "CAST('b', 'Enum8(\\'a\\' = 1, \\'b\\' = 2)')", "CAST(number + 1, 'Enum16(\\'x\\' = 1, \\'y\\' = 1000, \\'z\\' = 2, \\'w\\' = 3)')",
        "toIntervalSecond(number)",
        "if(number = 1, NULL, number)", "if(number = 0, NULL, 'not null')", "NULL",
        "toLowCardinality(toString(number % 2))", "toLowCardinality(if(number = 1, NULL, toString(number)))",
        "[number, number + 1]", "[]::Array(UInt8)", "['a''b', 'c\\\\d', 'e\\tf']", "[[1, 2], [3]]", "[NULL, 1]",
        "[toLowCardinality('x'), toLowCardinality('y')]", "[toDate('2026-01-02')]", "[toDateTime('2026-01-02 03:04:05', 'UTC')]",
        "map('k', number, 'l', 2)", "map('k', NULL::Nullable(Int8))", "map(1, [toUUID('01234567-89ab-cdef-0123-456789abcdef')])",
        "(1, 'x')", "(1.5, NULL)::Tuple(Float64, Nullable(String))", "(number, 'y')::Tuple(a UInt64, b String)",
        "[(1, 'a')]::Nested(x UInt8, y String)", "(1.5, 2.5)::Point", "[(0, 0), (1, 1)]::Ring",
        "if(number = 0, 42::Variant(String, UInt64), if(number = 1, 'str'::Variant(String, UInt64), NULL))",
        "if(number = 0, 42::Dynamic, if(number = 1, 'str'::Dynamic, NULL::Dynamic))",
        "[1, 2]::Dynamic", "toLowCardinality('lc')::Dynamic",
        "'{\"a\": 1, \"b\": {\"c\": \"x\"}}'::JSON",
    ]

    @Test func valuesAreWrittenAsTheServerWritesThem() async throws {
        let client = try await TestServer.connected()
        // Only the settings this server has (older ones lack the newer types').
        let known = Set(try await client.plainText("SELECT name FROM system.settings FORMAT TSV").split(separator: "\n").map(String.init))
        let typeSettings = Self.typeSettings.filter { known.contains($0.key) }
        var skipped: [String] = []
        for expression in Self.expressions {
            let sql = "SELECT \(expression) AS v FROM numbers(3)"
            let result: CHResult
            do {
                result = try await client.result(sql, settings: typeSettings)
            } catch let error as CHServerError where [46, 50, 36, 43, 44, 48, 70].contains(error.code) {
                // A type or function this server doesn't have (unknown function, type, setting value, …).
                skipped.append(expression)
                continue
            }
            var settings = typeSettings
            settings["output_format_tsv_crlf_end_of_line"] = "0"
            let expected = try await client.plainText(sql + " FORMAT TSVRaw", settings: settings)
                .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map { line -> String in
                    // TSVRaw's NULL is \N; FixedString shows its zeros, the viewer doesn't.
                    var text = line == "\\N" ? "NULL" : String(line)
                    if result.types.first.map({ if case .fixedString = $0.base { true } else { false } }) == true {
                        while text.hasSuffix("\0") { text.removeLast() }
                    }
                    return text
                }
            let context = CHTextContext(defaultTimeZone: client.serverInfo?.zone ?? .gmt)
            var texts: [String] = []
            for block in result.blocks {
                for row in 0..<block.rowCount { texts.append(block.columns[0].text(row, context: context)) }
            }
            #expect(texts == expected, "\(expression) as \(result.typeNames.first ?? "?")")
            // The same text written at once (NULL: none).
            var bulk: [String] = []
            for block in result.blocks {
                var written = CHTexts()
                block.columns[0].appendTexts(rows: 0..<block.rowCount, context: context, to: &written)
                for row in 0..<written.count {
                    bulk.append(block.columns[0].isNull(row) ? "NULL" : written.withText(row) { String(decoding: $0, as: UTF8.self) })
                }
            }
            #expect(bulk == texts, "\(expression) at once")
        }
        // Most expressions run on every server (23.8 lacks Variant, Dynamic, JSON, Time, BFloat16).
        #expect(skipped.count <= 12, "skipped: \(skipped)")
    }

    @Test func numbersSortAndSumByValue() async throws {
        let client = try await TestServer.connected()
        let result = try await client.result("""
            SELECT toInt32(number) - 2 AS i, toDecimal64(number, 2) / 4 AS d, toDate('2026-01-01') + number AS day,
                   toDateTime64('2026-01-01 00:00:00.5', 1, 'UTC') + number AS t, if(number = 1, NULL, number) AS n,
                   toLowCardinality(if(number = 2, NULL, toString(number))) AS l, 'x' AS s
            FROM numbers(4)
            """)
        let block = try #require(result.blocks.first)
        func numbers(_ column: Int) -> [Double] {
            var values = [Double](repeating: 0, count: 4)
            values.withUnsafeMutableBufferPointer { block.columns[column].numbers(rows: 0..<4, into: $0.baseAddress!) }
            return values
        }
        #expect(numbers(0) == [-2, -1, 0, 1])
        #expect(numbers(1) == [0, 0.25, 0.5, 0.75])
        #expect(numbers(2) == [1767225600, 1767312000, 1767398400, 1767484800])
        #expect(numbers(3) == [1767225600.5, 1767225601.5, 1767225602.5, 1767225603.5])
        #expect(numbers(4)[0] == 0 && numbers(4)[1].isNaN && numbers(4)[3] == 3)
        #expect(numbers(5).filter { !$0.isNaN }.isEmpty)
        #expect(numbers(6).filter { !$0.isNaN }.isEmpty)
    }

    @Test func blocksAndDictionariesOverManyRows() async throws {
        let client = try await TestServer.connected()
        // More distinct values than a dictionary takes at once (several parts in a block).
        let result = try await client.result("SELECT toLowCardinality(toString(number)) AS l, number FROM numbers(200000)",
                                             settings: ["max_block_size": "200000", "low_cardinality_max_dictionary_size": "1000"])
        #expect(result.rowCount == 200_000)
        let context = CHTextContext(defaultTimeZone: .gmt)
        var mismatches = 0
        for block in result.blocks {
            for row in stride(from: 0, to: block.rowCount, by: 997) where block.columns[0].text(row, context: context) != block.columns[1].text(row, context: context) {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
        let (block, row) = result.locate(123_456)
        #expect(result.blocks[block].columns[1].text(row, context: context) == "123456")
    }

    @Test func anErrorAfterRowsIsTheServers() async throws {
        let client = try await TestServer.connected()
        await #expect(throws: CHServerError.self) {
            _ = try await client.result("SELECT throwIf(number = 300000) FROM numbers(1000000)", settings: ["max_block_size": "1000"])
        }
        do {
            _ = try await client.result("SELECT * FROM no_such_table_here")
            Issue.record("no error")
        } catch let error as CHServerError {
            #expect(error.code == 60)
            #expect(error.name == "UNKNOWN_TABLE")
        }
    }

    @Test func unreadableColumnsAreSaid() async throws {
        let client = try await TestServer.connected()
        do {
            _ = try await client.result("SELECT uniqState(number) AS u FROM numbers(3)")
            Issue.record("no error")
        } catch let error as CHClientError {
            #expect(error == .unsupportedType(column: "u", type: "AggregateFunction(uniq, UInt64)"))
        }
    }

    @Test func theLimitStopsTheResult() async throws {
        let client = try await TestServer.connected()
        var options = CHQueryOptions()
        options.maxRows = 100_000
        var stats: CHQueryStats?
        for try await event in client.execute("SELECT number FROM numbers(10000000)", options: options) {
            if case .finished(let finished) = event { stats = finished }
        }
        let finished = try #require(stats)
        #expect(finished.reachedLimit)
        #expect(finished.rows >= 100_000 && finished.rows < 10_000_000)
    }

    @Test(.timeLimit(.minutes(1))) func cancellingStopsTheQueryOnTheServer() async throws {
        let client = try await TestServer.connected()
        var options = CHQueryOptions()
        let id = options.queryID
        options.settings = ["max_block_size": "1"]
        let query = Task {
            for try await event in client.execute("SELECT sleepEachRow(0.05), number FROM numbers(100000)", options: options) {
                if case .result(let result) = event, result.rowCount > 0 { break }
            }
        }
        try await query.value
        // Closing the connection (readonly = 2) or KILL QUERY: gone within a second or two.
        var running = true
        for _ in 0..<20 where running {
            try await Task.sleep(for: .milliseconds(200))
            let text = try await client.plainText("SELECT count() FROM system.processes WHERE query_id = \(CHSQL.quotedString(id)) FORMAT TSV")
            running = text.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
        }
        #expect(!running)
    }

    @Test func framesAndPlainBytesGiveTheSameRows() async throws {
        let plain = try await TestServer.connected()
        var endpoint = plain.endpoint
        endpoint.compression = .lz4
        let framed = CHClient(endpoint: endpoint, password: ProcessInfo.processInfo.environment["CH_TEST_PASSWORD"] ?? "")
        try await framed.connect()
        let sql = "SELECT number, toString(number) AS s, toLowCardinality(toString(number % 7)) AS l FROM numbers(300000)"
        let one = try await plain.result(sql), other = try await framed.result(sql)
        #expect(one.rowCount == 300_000 && other.rowCount == 300_000)
        let context = CHTextContext(defaultTimeZone: .gmt)
        for row in stride(from: 0, to: 300_000, by: 4_999) {
            let (a, ra) = one.locate(row), (b, rb) = other.locate(row)
            for column in 0..<3 {
                #expect(one.blocks[a].columns[column].text(ra, context: context) == other.blocks[b].columns[column].text(rb, context: context))
            }
        }
    }

    @Test func exportWritesTheServersFormat() async throws {
        let client = try await TestServer.connected()
        let file = FileManager.default.temporaryDirectory.appending(path: "chviewer-export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: file) }
        let written = try await client.download("SELECT number, toString(number) AS s FROM numbers(100000)", format: "CSVWithNames", to: file)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(written == text.utf8.count)
        #expect(text.hasPrefix("\"number\",\"s\"\n0,\"0\"\n1,\"1\"\n"))
        #expect(text.split(separator: "\n").count == 100_001)
    }
}

/// A user with readonly = 1 (no settings in a request): created by the tests' user if it may.
@Suite(.enabled(if: TestServer.isAvailable, "CH_TEST_URL names no server"), .serialized)
struct CHReadonlyUserTests {
    static func reader() async throws -> CHClient? {
        let admin = try await TestServer.connected()
        do {
            _ = try await admin.plainText("CREATE USER IF NOT EXISTS viewer_test_reader IDENTIFIED BY 'reader' SETTINGS readonly = 1")
            _ = try await admin.plainText("GRANT SELECT ON *.* TO viewer_test_reader")
        } catch {
            return nil
        }
        var endpoint = admin.endpoint
        endpoint.user = "viewer_test_reader"
        let client = CHClient(endpoint: endpoint, password: "reader")
        let info = try await client.connect()
        #expect(info.readonly == 1)
        return client
    }

    @Test func readsWithoutSettings() async throws {
        guard let client = try await Self.reader() else { return }
        let result = try await client.result("""
            SELECT number, toDateTime('2026-03-29 00:30:00', 'Europe/Berlin') AS t, toLowCardinality(toString(number)) AS l
            FROM numbers(100000)
            """)
        #expect(result.rowCount == 100_000)
        #expect(result.typeNames[1] == "DateTime('Europe/Berlin')")
        let context = CHTextContext(defaultTimeZone: .gmt)
        #expect(result.blocks[0].columns[1].text(0, context: context) == "2026-03-29 00:30:00")
    }

    @Test func theLimitHoldsOnTheViewersSide() async throws {
        guard let client = try await Self.reader() else { return }
        var options = CHQueryOptions()
        options.maxBytes = 4 << 20
        var stats: CHQueryStats?
        for try await event in client.execute("SELECT number FROM numbers(50000000)", options: options) {
            if case .finished(let finished) = event { stats = finished }
        }
        let finished = try #require(stats)
        #expect(finished.reachedLimit)
        #expect(finished.rows < 50_000_000 && finished.resultBytes >= 4 << 20)
    }

    @Test func exportsInTheServersFormat() async throws {
        guard let client = try await Self.reader() else { return }
        let file = FileManager.default.temporaryDirectory.appending(path: "chviewer-reader-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await client.download("SELECT number FROM numbers(3)", format: "CSV", to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "0\n1\n2\n")
    }
}
