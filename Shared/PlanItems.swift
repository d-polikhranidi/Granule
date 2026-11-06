import ClickHouseCore
import Foundation

/// A plan as rows of an outline: steps from the result down to the reads,
/// and under each read the indexes, each with the granules it left.
final class PlanItem {
    let title: String
    let detail: String
    let symbol: String
    /// The condition an index checks (shown on a line of its own).
    let note: String?
    let children: [PlanItem]

    init(title: String, detail: String, symbol: String, note: String? = nil, children: [PlanItem] = []) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.note = note
        self.children = children
    }

    convenience init(_ node: CHPlanNode) {
        let title = node.description.isEmpty ? node.type : "\(node.type) · \(node.description)"
        var children = node.indexes.map(PlanItem.init(index:))
        children += node.children.map(PlanItem.init)
        self.init(title: title, detail: PlanItem.readSummary(node) ?? "", symbol: PlanItem.symbol(node.type), children: children)
    }

    convenience init(index: CHPlanIndex) {
        let name = index.name.map { "\(index.type) \($0)" } ?? index.type
        let keys = index.keys.isEmpty ? "" : " (\(index.keys.joined(separator: ", ")))"
        var parts: [String] = []
        if let before = index.initialGranules, let after = index.selectedGranules {
            parts.append(String(localized: "granules \(before.formatted()) → \(after.formatted())"))
        }
        if let before = index.initialParts, let after = index.selectedParts, before != after {
            parts.append(String(localized: "parts \(before.formatted()) → \(after.formatted())"))
        }
        if let skipped = index.skipped { parts.append(String(localized: "skips \(skipped.formatted(.percent.precision(.fractionLength(0...1))))")) }
        self.init(title: name + keys, detail: parts.joined(separator: " · "), symbol: "line.3.horizontal.decrease", note: index.condition)
    }

    /// A read's funnel: the granules and parts it reads of those it has.
    static func readSummary(_ node: CHPlanNode) -> String? {
        guard let first = node.indexes.first, let last = node.indexes.last,
              let before = first.initialGranules, let after = last.selectedGranules else { return nil }
        let share = before > 0 ? Double(after) / Double(before) : 1
        var text = String(localized: "reads \(after.formatted()) of \(before.formatted()) granules (\(share.formatted(.percent.precision(.fractionLength(0...2)))))")
        if let parts = first.initialParts, let selected = last.selectedParts {
            text += " · " + String(localized: "\(selected.formatted()) of \(parts.formatted()) parts")
        }
        return text
    }

    /// The plan's reads in a line: what the query reads of each table.
    static func summary(of plan: CHPlanNode) -> String {
        let reads = plan.reads.compactMap { node -> String? in
            guard let funnel = readSummary(node) else { return nil }
            return (node.description.isEmpty ? node.type : node.description) + ": " + funnel
        }
        return reads.isEmpty ? String(localized: "No index narrows the reads.") : reads.joined(separator: "; ")
    }

    private static func symbol(_ type: String) -> String {
        switch type {
        case let read where read.hasPrefix("ReadFrom"): "tablecells"
        case "Aggregating", "MergingAggregated": "sum"
        case "Sorting", "MergingSorted": "arrow.up.arrow.down"
        case "Limit", "Offset": "line.3.horizontal.decrease.circle"
        case "Filter": "line.3.horizontal.decrease"
        case "Join", "JoiningStep": "arrow.triangle.merge"
        case "Union": "square.stack"
        case "CreatingSets", "CreatingSet": "list.bullet.rectangle"
        default: "function"
        }
    }
}
