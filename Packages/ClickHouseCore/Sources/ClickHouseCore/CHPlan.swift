import Foundation

/// A query's plan as the server makes it (`EXPLAIN PLAN json = 1, indexes = 1`):
/// steps from the result down to the reads, and for each read of a
/// MergeTree table the indexes it used and how many parts and granules each
/// left of those before it.
public struct CHPlanNode: Sendable, Equatable {
    public var type: String
    public var description: String
    /// The indexes a read used, in the order they filtered.
    public var indexes: [CHPlanIndex]
    /// Other things the server says of the step (`Parts`, `Granules`, …).
    public var details: [String: String]
    public var children: [CHPlanNode]

    /// The reads under it (itself included), depth first.
    public var reads: [CHPlanNode] {
        (indexes.isEmpty && !type.hasPrefix("ReadFrom") ? [] : [self]) + children.flatMap(\.reads)
    }
}

public struct CHPlanIndex: Sendable, Equatable {
    /// MinMax, Partition, PrimaryKey, Skip (its name in `name`), …
    public var type: String
    public var name: String?
    public var keys: [String]
    public var condition: String?
    public var initialParts: Int?
    public var selectedParts: Int?
    public var initialGranules: Int?
    public var selectedGranules: Int?

    /// The share of granules it skipped, 0...1, if it says.
    public var skipped: Double? {
        guard let before = initialGranules, let after = selectedGranules, before > 0 else { return nil }
        return 1 - Double(after) / Double(before)
    }
}

extension CHPlanNode {
    /// The plan from the server's JSON (an array of one `{"Plan": …}`).
    public init?(json text: String) {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data),
              let plan = ((object as? [[String: Any]])?.first ?? object as? [String: Any])?["Plan"] as? [String: Any] else { return nil }
        self.init(plan)
    }

    init(_ node: [String: Any]) {
        type = node["Node Type"] as? String ?? "?"
        description = node["Description"] as? String ?? ""
        indexes = (node["Indexes"] as? [[String: Any]] ?? []).map { index in
            CHPlanIndex(type: index["Type"] as? String ?? "?", name: index["Name"] as? String,
                        keys: index["Keys"] as? [String] ?? [], condition: index["Condition"] as? String,
                        initialParts: Self.int(index["Initial Parts"]), selectedParts: Self.int(index["Selected Parts"]),
                        initialGranules: Self.int(index["Initial Granules"]), selectedGranules: Self.int(index["Selected Granules"]))
        }
        children = (node["Plans"] as? [[String: Any]] ?? []).map(CHPlanNode.init)
        var details: [String: String] = [:]
        for (key, value) in node where !["Node Type", "Node Id", "Description", "Indexes", "Plans", "Header", "Actions"].contains(key) {
            switch value {
            case let text as String: details[key] = text
            case let number as NSNumber: details[key] = number.stringValue
            case let list as [Any]: details[key] = list.map { "\($0)" }.joined(separator: ", ")
            default: break
            }
        }
        self.details = details
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text)
        default: nil
        }
    }
}

extension CHClient {
    /// A query's plan with the indexes its reads use, without running it.
    public func plan(of query: String) async throws -> CHPlanNode {
        let text = try await plainText("EXPLAIN PLAN json = 1, indexes = 1, description = 1\n\(query)\nFORMAT TSVRaw",
                                       settings: maySetSettings ? ["readonly": "2", "max_execution_time": "10"] : [:])
        guard let plan = CHPlanNode(json: text) else { throw CHClientError.malformed("a plan the viewer can't read") }
        return plan
    }
}
