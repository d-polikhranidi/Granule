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
let client = CHClient(endpoint: endpoint, password: environment["CH_PASSWORD"] ?? password ?? "")
let info = try await client.connect()
print("ClickHouse \(info.version), zone \(info.timeZone)")

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

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
    print(String(format: "run %d: %d rows, %d columns in %.3f s (first rows %.3f s), received %.1f MB (%.0f MB/s), kept %.1f MB, %.1f M rows/s",
                 run, stats.rows, last.names.count, time, stats.firstRows.map(seconds) ?? 0, Double(stats.receivedBytes) / 1e6,
                 Double(stats.receivedBytes) / 1e6 / time, Double(stats.resultBytes) / 1e6, Double(stats.rows) / 1e6 / time))
}
