import CHDecode
import Foundation

/// The numbers a chart is drawn from: a column's values as numbers, their
/// range, and many points folded into a bucket per pixel (least, most, sum
/// and count of each), so millions of rows draw as fast as a few.
public enum CHChartMath {
    public struct Buckets: Sendable {
        public var least: [Double]
        public var most: [Double]
        public var sum: [Double]
        public var counts: [UInt32]

        /// A bucket's mean, NaN for an empty one.
        public func mean(_ index: Int) -> Double { counts[index] == 0 ? .nan : sum[index] / Double(counts[index]) }
    }

    /// The least and most of the values (NaN left out), `nil` for none.
    public static func range(_ values: [Double]) -> ClosedRange<Double>? {
        var least = 0.0, most = 0.0
        values.withUnsafeBufferPointer { ch_range($0.baseAddress, $0.count, &least, &most) }
        guard !least.isNaN, !most.isNaN else { return nil }
        return least...most
    }

    public static func isAscending(_ values: [Double]) -> Bool {
        values.withUnsafeBufferPointer { ch_is_ascending($0.baseAddress, $0.count) != 0 }
    }

    /// Points (x[i], y[i]) in `count` buckets of x over `range`.
    public static func bucket(x: [Double], y: [Double], range: ClosedRange<Double>, count: Int) -> Buckets {
        var buckets = Buckets(least: [Double](repeating: .infinity, count: count), most: [Double](repeating: -.infinity, count: count),
                              sum: [Double](repeating: 0, count: count), counts: [UInt32](repeating: 0, count: count))
        x.withUnsafeBufferPointer { x in
            y.withUnsafeBufferPointer { y in
                ch_bucket(x.baseAddress, y.baseAddress, min(x.count, y.count), range.lowerBound, range.upperBound, count,
                          &buckets.least, &buckets.most, &buckets.sum, &buckets.counts)
            }
        }
        return buckets
    }
}

extension CHResult {
    /// A column's values as numbers, row after row (or of `rows`, in their
    /// order): NaN for NULL and values that aren't numbers.
    public func numbers(column: Int, rows: [Int]? = nil) -> [Double] {
        var values = [Double](repeating: .nan, count: rows?.count ?? rowCount)
        values.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            if let rows {
                for (index, row) in rows.enumerated() where row >= 0 && row < rowCount {
                    let (block, inBlock) = locate(row)
                    blocks[block].columns[column].numbers(rows: inBlock..<inBlock + 1, into: base + index)
                }
            } else {
                forEachBlock(in: 0..<rowCount) { block, range, offset in
                    block.columns[column].numbers(rows: range, into: base + offset)
                }
            }
        }
        return values
    }

    /// A column's values as text, row after row (or of `rows`): the chart's categories.
    public func texts(column: Int, rows: [Int]? = nil, timeZone: TimeZone) -> [String] {
        let context = CHTextContext(defaultTimeZone: timeZone)
        if let rows {
            return rows.map { row in
                guard row >= 0, row < rowCount else { return "" }
                let (block, inBlock) = locate(row)
                return blocks[block].columns[column].text(inBlock, context: context)
            }
        }
        var texts: [String] = []
        texts.reserveCapacity(rowCount)
        var written = CHTexts()
        forEachBlock(in: 0..<rowCount) { block, range, _ in
            written.removeAll()
            block.columns[column].appendTexts(rows: range, context: context, to: &written)
            for index in 0..<written.count { texts.append(written.withText(index) { String(decoding: $0, as: UTF8.self) }) }
        }
        return texts
    }
}
