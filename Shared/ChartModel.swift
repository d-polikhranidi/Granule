import ClickHouseCore
import Foundation

/// What a chart of a result shows, worked out off the main thread: a line
/// of each measure over a time or number column (folded into a bucket per
/// pixel when there are more points than pixels: each bucket's mean, and its
/// least to most as a band), or bars of each measure per category of a
/// text column (summed, the largest 40 and the rest as Other).
nonisolated struct ChartModel: Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case automatic, line, bars
    }

    struct Series: Sendable {
        var name: String
        /// Line: points (x, y) when there are few enough to draw each…
        var points: [(Double, Double)] = []
        /// …or buckets over x: least, mean and most of each (NaN: empty).
        var least: [Double] = []
        var mean: [Double] = []
        var most: [Double] = []
        /// Bars: a value per category.
        var values: [Double] = []
    }

    var kind: Kind
    var xName: String
    var xType: CHType
    /// The range of x (lines), and of y over every series.
    var xRange: ClosedRange<Double>
    var yRange: ClosedRange<Double>
    var categories: [String] = []
    var series: [Series]
    /// The rows charted.
    var rowCount: Int

    var isFolded: Bool { series.first.map { !$0.mean.isEmpty } ?? false }

    /// The columns a chart of a result would take by itself: x the first
    /// time column (else the first number, else the first text one), y the
    /// first numbers after it (up to three).
    static func automaticColumns(_ result: CHResult) -> (x: Int, ys: [Int])? {
        let types = result.types
        let x = types.firstIndex { $0.isTemporal } ?? types.firstIndex { !$0.sortsAsNumber } ?? types.firstIndex { $0.isNumeric }
        guard let x else { return nil }
        let ys = types.indices.filter { $0 != x && types[$0].isNumeric }.prefix(3)
        guard !ys.isEmpty else { return nil }
        return (x, Array(ys))
    }

    /// The chart of a result's `rows` (`nil`: all) by column `x` and columns `ys`, `buckets` wide.
    static func build(result: CHResult, rows: [Int]?, x: Int, ys: [Int], kind: Kind, buckets: Int, timeZone: TimeZone) -> ChartModel? {
        guard x < result.names.count, !ys.isEmpty, ys.allSatisfy({ $0 < result.names.count }) else { return nil }
        let xType = result.types[x]
        let resolved: Kind = kind == .automatic ? (xType.sortsAsNumber ? .line : .bars) : kind
        let count = rows?.count ?? result.rowCount
        if resolved == .bars || !xType.sortsAsNumber {
            return bars(result: result, rows: rows, x: x, ys: ys, timeZone: timeZone, count: count)
        }
        let xs = result.numbers(column: x, rows: rows)
        guard let xRange = CHChartMath.range(xs) else { return nil }
        var series: [Series] = []
        var yLeast = Double.infinity, yMost = -Double.infinity
        let foldsPoints = xs.count > buckets * 2
        // Points drawn as they are come in order of x.
        let order: [Int]? = foldsPoints || CHChartMath.isAscending(xs) ? nil : xs.indices.sorted { xs[$0] < xs[$1] }
        for y in ys {
            let values = result.numbers(column: y, rows: rows)
            var line = Series(name: result.names[y])
            if foldsPoints {
                let folded = CHChartMath.bucket(x: xs, y: values, range: xRange, count: buckets)
                line.least = folded.least.map { $0.isInfinite ? .nan : $0 }
                line.most = folded.most.map { $0.isInfinite ? .nan : $0 }
                line.mean = (0..<buckets).map(folded.mean)
                if let range = CHChartMath.range(line.least) { yLeast = min(yLeast, range.lowerBound) }
                if let range = CHChartMath.range(line.most) { yMost = max(yMost, range.upperBound) }
            } else {
                let indexes = order ?? Array(xs.indices)
                line.points = indexes.compactMap { index in
                    let point = (xs[index], values[index])
                    return point.0.isNaN || point.1.isNaN ? nil : point
                }
                if let range = CHChartMath.range(values) {
                    yLeast = min(yLeast, range.lowerBound)
                    yMost = max(yMost, range.upperBound)
                }
            }
            series.append(line)
        }
        guard yLeast <= yMost else { return nil }
        return ChartModel(kind: .line, xName: result.names[x], xType: xType, xRange: xRange, yRange: Self.paddedRange(yLeast...yMost),
                          series: series, rowCount: count)
    }

    /// Bars: each measure summed per category, the 40 largest (by the first measure), the rest as Other.
    private static func bars(result: CHResult, rows: [Int]?, x: Int, ys: [Int], timeZone: TimeZone, count: Int) -> ChartModel? {
        let labels = result.texts(column: x, rows: rows, timeZone: timeZone)
        var index: [String: Int] = [:], categories: [String] = []
        var rowCategory = [Int](repeating: 0, count: labels.count)
        for (row, label) in labels.enumerated() {
            if let known = index[label] {
                rowCategory[row] = known
            } else {
                index[label] = categories.count
                rowCategory[row] = categories.count
                categories.append(label)
            }
        }
        var sums = ys.map { _ in [Double](repeating: 0, count: categories.count) }
        for (seriesIndex, y) in ys.enumerated() {
            let values = result.numbers(column: y, rows: rows)
            for (row, value) in values.enumerated() where !value.isNaN { sums[seriesIndex][rowCategory[row]] += value }
        }
        var order = Array(categories.indices)
        let limit = 40
        if order.count > limit {
            order.sort { sums[0][$0] > sums[0][$1] }
            let kept = Array(order.prefix(limit - 1)), rest = order.dropFirst(limit - 1)
            var series: [Series] = []
            for (seriesIndex, y) in ys.enumerated() {
                var values = kept.map { sums[seriesIndex][$0] }
                values.append(rest.reduce(0) { $0 + sums[seriesIndex][$1] })
                series.append(Series(name: result.names[y], values: values))
            }
            return finishBars(names: kept.map { categories[$0] } + [String(localized: "Other")], series: series, result: result, x: x, count: count)
        }
        let series = ys.enumerated().map { Series(name: result.names[$0.element], values: sums[$0.offset]) }
        return finishBars(names: categories, series: series, result: result, x: x, count: count)
    }

    private static func finishBars(names: [String], series: [Series], result: CHResult, x: Int, count: Int) -> ChartModel? {
        let all = series.flatMap(\.values)
        guard let range = CHChartMath.range(all) else { return nil }
        // Bars grow from zero.
        let yRange = Self.paddedRange(min(0, range.lowerBound)...max(0, range.upperBound), keepsZero: true)
        return ChartModel(kind: .bars, xName: result.names[x], xType: result.types[x], xRange: 0...Double(max(1, names.count)),
                          yRange: yRange, categories: names, series: series, rowCount: count)
    }

    /// A range with room at the top (and bottom), never empty.
    static func paddedRange(_ range: ClosedRange<Double>, keepsZero: Bool = false) -> ClosedRange<Double> {
        var low = range.lowerBound, high = range.upperBound
        if high == low {
            low -= max(1, abs(low) * 0.1)
            high += max(1, abs(high) * 0.1)
        }
        let pad = (high - low) * 0.05
        if !(keepsZero && low == 0) { low -= pad }
        if !(keepsZero && high == 0) { high += pad }
        return low...high
    }

    // MARK: Ticks

    /// Round values over a range for gridlines and labels (1, 2, 5 × 10^n apart).
    static func ticks(_ range: ClosedRange<Double>, count: Int) -> [Double] {
        let span = range.upperBound - range.lowerBound
        guard span > 0, span.isFinite, count > 0 else { return [] }
        let raw = span / Double(count)
        let power = pow(10, floor(log10(raw)))
        let step = [1.0, 2, 5, 10].map { $0 * power }.first { $0 >= raw } ?? power * 10
        var tick = (range.lowerBound / step).rounded(.up) * step
        var ticks: [Double] = []
        while tick <= range.upperBound + step * 1e-9, ticks.count < 50 {
            ticks.append(abs(tick) < step * 1e-9 ? 0 : tick)
            tick += step
        }
        return ticks
    }

    /// Times (seconds since 1970) at a round step for a time axis, and how to write them.
    static func timeTicks(_ range: ClosedRange<Double>, count: Int, zone: TimeZone) -> (values: [Double], format: Date.FormatStyle) {
        let span = range.upperBound - range.lowerBound
        let steps: [Double] = [1, 5, 15, 30, 60, 300, 900, 1800, 3600, 3 * 3600, 6 * 3600, 12 * 3600, 86_400, 7 * 86_400, 30.4375 * 86_400,
                               91.3125 * 86_400, 365.25 * 86_400]
        let step = steps.first { span / $0 <= Double(count) + 1 } ?? 365.25 * 86_400 * ceil(span / (365.25 * 86_400 * Double(count)))
        let offset = Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: range.lowerBound)))
        var tick = ((range.lowerBound + offset) / step).rounded(.up) * step - offset
        var values: [Double] = []
        while tick <= range.upperBound, values.count < 50 {
            values.append(tick)
            tick += step
        }
        var format = Date.FormatStyle(timeZone: zone)
        if step < 60 {
            format = format.hour().minute().second()
        } else if step < 86_400 {
            format = format.hour().minute()
        } else if step < 28 * 86_400 {
            format = format.month(.abbreviated).day()
        } else if step < 365 * 86_400 {
            format = format.month(.abbreviated).year()
        } else {
            format = format.year()
        }
        return (values, format)
    }

    /// A number as an axis or tooltip writes it: compact (12.9K, 4.2M).
    static func compact(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if abs(value) < 10_000 {
            let digits = abs(value) < 10 && value != value.rounded() ? 2 : (value == value.rounded() ? 0 : 1)
            return value.formatted(.number.precision(.fractionLength(0...digits)))
        }
        return value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    /// The time zone of a time column (its own, or the server's).
    static func zone(of type: CHType, server: TimeZone) -> TimeZone {
        switch type.base {
        case .dateTime(let zone), .dateTime64(_, let zone): zone.flatMap(TimeZone.init(identifier:)) ?? server
        case .date, .date32: TimeZone(identifier: "UTC")!
        default: server
        }
    }
}
