import ClickHouseCore
import CoreGraphics
import Foundation
import Gingham

/// The chart of the result shown: its columns (chosen by itself for a new
/// result, then by the user), the rows the search found, folded to the
/// chart's width in the background, then drawn.
final class ChartController {
    let view = ChartView(frame: .zero)
    /// The column along x, the measures (up to three), the kind.
    private(set) var x: Int?
    private(set) var ys: [Int] = []
    var kind: ChartModel.Kind = .automatic { didSet { invalidate() } }
    /// Called when the columns changed (the bar's menus show them).
    var onChange: () -> Void = {}

    private var header: [String] = []
    private var building: Task<Void, Never>?
    private var built: String?
    private var lastBuild = ContinuousClock.now - .seconds(10)

    /// The columns a user can chart: (index, name), and which are numbers.
    private(set) var columns: [(index: Int, name: String, isNumber: Bool)] = []

    func choose(x: Int) {
        self.x = x
        ys.removeAll { $0 == x }
        if ys.isEmpty, let first = columns.first(where: { $0.isNumber && $0.index != x }) { ys = [first.index] }
        invalidate()
    }

    /// A measure added or taken out (three at most: one axis, colors told apart).
    func toggle(y: Int) {
        if let index = ys.firstIndex(of: y) {
            if ys.count > 1 { ys.remove(at: index) }
        } else {
            ys.append(y)
            if ys.count > 3 { ys.removeFirst() }
        }
        invalidate()
    }

    private func invalidate() {
        built = nil
        onChange()
    }

    /// The chart brought up to date with the result and the rows shown
    /// (`table` filtered: its rows), at most twice a second while rows come.
    func update(source: ResultTableSource?, table: GHTableView, isRunning: Bool, timeZone: TimeZone) {
        guard let source else {
            view.model = nil
            return
        }
        let result = source.result
        if result.names != header {
            header = result.names
            columns = result.names.indices.map { ($0, result.names[$0], result.types[$0].sortsAsNumber) }
            let automatic = ChartModel.automaticColumns(result)
            x = automatic?.x
            ys = automatic?.ys ?? []
            built = nil
            onChange()
        }
        guard let x, !ys.isEmpty else {
            view.model = nil
            return
        }
        let width = view.plotWidthInPixels
        let filtered = table.rowFilter != nil
        let signature = "\(result.rowCount) \(filtered ? table.numberOfRows : -1) \(x) \(ys) \(kind) \(width) \(isRunning)"
        guard signature != built else { return }
        guard !isRunning || ContinuousClock.now - lastBuild > .milliseconds(500) else { return }
        built = signature
        lastBuild = ContinuousClock.now
        let rows = filtered ? table.shownSourceRows() : nil
        let xType = result.types[x]
        let ys = self.ys, kind = self.kind
        building?.cancel()
        building = Task { [weak self] in
            let model = await Task.detached(priority: .userInitiated) {
                ChartModel.build(result: result, rows: rows, x: x, ys: ys, kind: kind, buckets: width, timeZone: timeZone)
            }.value
            guard let self, !Task.isCancelled else { return }
            view.timeZone = ChartModel.zone(of: xType, server: timeZone)
            view.model = model
        }
    }
}
