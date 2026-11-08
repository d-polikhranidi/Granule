import Foundation

/// A text laid out by the server's own formatter.
public struct CHFormatted: Sendable {
    /// The statements laid out, joined by `;` and a blank line.
    public var text: String
    /// Whether the text had comments: neither the formatter nor the joining keeps them.
    public var droppedComments: Bool
}

extension CHClient {
    /// Statements laid out by the server's `formatQuery` (keywords upper-cased, a
    /// clause a line, parameters kept), one at a time since it takes one. Comments
    /// don't survive it. A server without the function fails with Code 46.
    public func format(_ text: String) async throws -> CHFormatted {
        let source = text as NSString
        var parts: [String] = []
        for range in CHSQL.statements(text) {
            let statement = source.substring(with: range)
            let laidOut = try await plainText("SELECT formatQuery(\(CHSQL.quotedString(statement))) FORMAT TSVRaw", background: true)
            parts.append(laidOut.hasSuffix("\n") ? String(laidOut.dropLast()) : laidOut)
        }
        // Nothing but comments or spaces: left as it is (it was replaced by nothing).
        guard !parts.isEmpty else { return CHFormatted(text: text, droppedComments: false) }
        // A semicolon after the last statement stays.
        let closed = text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(";")
        return CHFormatted(text: parts.joined(separator: ";\n\n") + (closed ? ";" : ""),
                           droppedComments: CHSQL.tokens(text).contains { $0.kind == .comment })
    }
}
