import Foundation

extension CHClient {
    /// A query's result columns the viewer can't read (`AggregateFunction` states and the
    /// like), as the server describes the result without running it (`DESCRIBE (…)`, marked
    /// as the viewer's own): all of them rewritten at once, not one run each.
    public func unreadableColumns(of query: String, parameters: [String: String] = [:],
                                  sessionID: String? = nil) async throws -> [(name: String, type: String)] {
        let text = try await plainText("DESCRIBE (\n\(query)\n) FORMAT TSVRaw", sessionID: sessionID, parameters: parameters, background: true)
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return nil }
            let type = CHType(parsing: String(fields[1]))
            guard !type.isReadable || (!readsJSONAsText && type.containsJSON) else { return nil }
            return (String(fields[0]), String(fields[1]))
        }
    }
}
