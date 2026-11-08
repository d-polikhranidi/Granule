import ClickHouseCore
import Foundation

// ch-bench: a query's result read as the viewer reads it, timed.
//   swift run -c release ch-bench "<SQL>" [runs]
// The server: CH_URL (http://localhost:18123), CH_USER (default), CH_PASSWORD.
let arguments = CommandLine.arguments.dropFirst()
guard let sql = arguments.first else {
    print("usage: ch-bench \"<SQL>\" [runs]")
    exit(1)
}
let runs = arguments.dropFirst().first.flatMap(Int.init) ?? 3
let environment = ProcessInfo.processInfo.environment
guard var (endpoint, password) = CHEndpoint.parse(environment["CH_URL"] ?? "http://localhost:18123") else { exit(1) }
endpoint.user = environment["CH_USER"] ?? endpoint.user
// `CH_COMPRESSION=lz4|zstd|none`: the frames asked for (a local server sends none by itself).
if let compression = environment["CH_COMPRESSION"].flatMap(CHCompression.init(rawValue:)) { endpoint.compression = compression }
let client = CHClient(endpoint: endpoint, password: environment["CH_PASSWORD"] ?? password ?? "")
let info = try await client.connect()
print("ClickHouse \(info.version), zone \(info.timeZone)")

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

// `CH_BENCH_TEXT=1`: also each column's values written as text (what search reads), one thread.
let timesText = environment["CH_BENCH_TEXT"] == "1"

for run in 1...runs {
    var last: CHResult?
    var stats: CHQueryStats?
    for try await event in client.execute(sql) {
        switch event {
        case .result(let result): last = result
        case .finished(let finished): stats = finished
        }
    }
    guard let stats, let last else { continue }
    let time = seconds(stats.elapsed)
    if timesText {
        let context = CHTextContext(defaultTimeZone: info.zone)
        var writer = CHTextWriter()
        for (index, name) in last.names.enumerated() {
            let start = ContinuousClock.now
            var bytes = 0
            for block in last.blocks {
                let column = block.columns[index]
                for row in 0..<block.rowCount { bytes += column.withText(row, context: context, writer: &writer) { $0.count } }
            }
            let time = seconds(ContinuousClock.now - start)
            let bulkStart = ContinuousClock.now
            var texts = CHTexts(), bulkBytes = 0
            for block in last.blocks {
                texts.removeAll()
                block.columns[index].appendTexts(rows: 0..<block.rowCount, context: context, to: &texts)
                bulkBytes += texts.bytes.count
            }
            let bulk = seconds(ContinuousClock.now - bulkStart)
            print(String(format: "  %@ (%@): %.0f ns a value one by one, %.1f ns at once, %d bytes (%d)", name, last.typeNames[index],
                         time * 1e9 / Double(stats.rows), bulk * 1e9 / Double(stats.rows), bytes, bulkBytes))
        }
    }
    print(String(format: "run %d: %d rows, %d columns in %.3f s (first rows %.3f s), received %.1f MB (%.0f MB/s), kept %.1f MB, %.1f M rows/s",
                 run, stats.rows, last.names.count, time, stats.firstRows.map(seconds) ?? 0, Double(stats.receivedBytes) / 1e6,
                 Double(stats.receivedBytes) / 1e6 / time, Double(stats.resultBytes) / 1e6, Double(stats.rows) / 1e6 / time))
}
