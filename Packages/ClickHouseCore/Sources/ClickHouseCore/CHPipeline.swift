import Foundation

/// A query's pipeline as the server builds it (`EXPLAIN PIPELINE graph = 1,
/// compact = 1`, read from its DOT): processors (`ExpressionTransform × 10`),
/// the plan step each belongs to, and the streams between them.
public struct CHPipeline: Sendable, Equatable {
    public struct Node: Sendable, Equatable {
        public var id: String
        public var label: String
        /// The plan step (the DOT's cluster) it's part of.
        public var step: String
    }

    public struct Edge: Sendable, Equatable {
        public var from: String
        public var to: String
        /// How many streams (`× 10`), empty for one.
        public var label: String
    }

    public var nodes: [Node]
    public var edges: [Edge]

    /// The pipeline from the server's DOT (only what ClickHouse writes in it).
    public init(dot: String) {
        var nodes: [Node] = [], edges: [Edge] = []
        var step = ""
        for line in dot.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("subgraph") {
                step = ""
            } else if line.hasPrefix("label") && !line.contains("->") {
                // label ="ReadFromMergeTree";
                step = Self.quoted(line) ?? step
            } else if let arrow = line.range(of: "->") {
                let from = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let rest = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                let to = String(rest.prefix { !$0.isWhitespace && $0 != "[" && $0 != ";" })
                edges.append(Edge(from: from, to: to, label: Self.quoted(String(rest)) ?? ""))
            } else if line.first == "n", let bracket = line.firstIndex(of: "["), let label = Self.quoted(String(line[bracket...])) {
                nodes.append(Node(id: line[..<bracket].trimmingCharacters(in: .whitespaces), label: label, step: step))
            }
        }
        self.nodes = nodes
        self.edges = edges
    }

    /// The text in the first pair of double quotes (backslash escapes kept as their character).
    private static func quoted(_ text: String) -> String? {
        guard let open = text.firstIndex(of: "\"") else { return nil }
        var result = "", escaped = false
        for character in text[text.index(after: open)...] {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return result
            } else {
                result.append(character)
            }
        }
        return nil
    }

    /// Each node's layer: the longest way to it from a source (sources are 0).
    public var layers: [String: Int] {
        var layer: [String: Int] = [:]
        var incoming = Dictionary(grouping: edges, by: \.to)
        var pending = nodes.map(\.id).filter { incoming[$0] == nil }
        for id in pending { layer[id] = 0 }
        var remaining = Dictionary(grouping: edges, by: \.to).mapValues(\.count)
        let outgoing = Dictionary(grouping: edges, by: \.from)
        while let id = pending.popLast() {
            for edge in outgoing[id] ?? [] {
                layer[edge.to] = max(layer[edge.to] ?? 0, (layer[id] ?? 0) + 1)
                remaining[edge.to, default: 1] -= 1
                if remaining[edge.to] == 0 { pending.append(edge.to) }
            }
        }
        // (A cycle, which a pipeline doesn't have: its nodes at the end.)
        let last = (layer.values.max() ?? 0) + 1
        for node in nodes where layer[node.id] == nil { layer[node.id] = last }
        incoming.removeAll()
        return layer
    }
}

extension CHClient {
    /// A query's pipeline, without running it.
    public func pipeline(of query: String) async throws -> CHPipeline {
        let text = try await plainText("EXPLAIN PIPELINE graph = 1, compact = 1\n\(query)\nFORMAT TSVRaw",
                                       settings: maySetSettings ? ["readonly": "2", "max_execution_time": "10"] : [:])
        let pipeline = CHPipeline(dot: text)
        guard !pipeline.nodes.isEmpty else { throw CHClientError.malformed("a pipeline the viewer can't read") }
        return pipeline
    }
}
