import Foundation

extension CHSQL {
    /// Something wrong in a statement: where (UTF-16, in the statement; `nil`
    /// when the server names no place), what, and the names it may have meant.
    public struct Problem: Sendable, Equatable {
        public enum Severity: Sendable, Equatable { case error, warning }

        public var range: NSRange?
        public var message: String
        public var suggestions: [String]
        public var severity: Severity
        /// Found by the server (else by the viewer, from the text alone).
        public var isFromServer: Bool

        public init(range: NSRange?, message: String, suggestions: [String] = [], severity: Severity = .error, isFromServer: Bool = false) {
            self.range = range
            self.message = message
            self.suggestions = suggestions
            self.severity = severity
            self.isFromServer = isFromServer
        }
    }

    /// What can be told from a statement's text alone, at once: strings,
    /// quoted names and comments left open, brackets that don't pair,
    /// parameters without a type.
    public static func localProblems(in statement: String) -> [Problem] {
        let text = statement as NSString
        var problems: [Problem] = []
        var open: [(UInt16, NSRange)] = []
        for token in tokens(statement) {
            let value = text.substring(with: token.range)
            switch token.kind {
            case .string, .quotedIdentifier:
                let quote = value.utf16.first ?? 0
                if !Self.isClosed(value, quote: quote) {
                    problems.append(Problem(range: token.range, message: token.kind == .string
                        ? String(localized: "This string has no closing quote.") : String(localized: "This name has no closing quote.")))
                }
            case .comment:
                if value.hasPrefix("/*"), !value.hasSuffix("*/") || value.count < 4 {
                    problems.append(Problem(range: NSRange(location: token.range.location, length: 2),
                                            message: String(localized: "This comment isn't closed (*/).")))
                }
            case .parameter:
                if !value.hasSuffix("}") {
                    problems.append(Problem(range: token.range, message: String(localized: "This parameter has no closing brace.")))
                } else if !value.contains(":") {
                    problems.append(Problem(range: token.range, message: String(localized: "A parameter is {name:Type}: this one has no type.")))
                }
            case .punctuation:
                guard let unit = value.utf16.first, value.utf16.count == 1 else { continue }
                switch unit {
                case 0x28, 0x5B: open.append((unit, token.range))
                case 0x29, 0x5D:
                    let opener: UInt16 = unit == 0x29 ? 0x28 : 0x5B
                    if let last = open.last, last.0 == opener {
                        open.removeLast()
                    } else {
                        problems.append(Problem(range: token.range, message: String(localized: "This bracket closes none.")))
                    }
                default: break
                }
            default:
                break
            }
        }
        for (unit, range) in open {
            problems.append(Problem(range: range, message: unit == 0x28 ? String(localized: "This bracket isn't closed: no ).")
                                    : String(localized: "This bracket isn't closed: no ].")))
        }
        return problems
    }

    private static func isClosed(_ token: String, quote: UInt16) -> Bool {
        let units = Array(token.utf16)
        guard units.count >= 2, units.last == quote else { return false }
        // A last quote escaped by a backslash doesn't close (doubled quotes do).
        var backslashes = 0
        var index = units.count - 2
        while index > 0, units[index] == 0x5C {
            backslashes += 1
            index -= 1
        }
        return backslashes % 2 == 0
    }

    /// Whether a statement may hold a scalar subquery, `(SELECT …)` where a
    /// value goes: the server runs those to check a statement (IN, FROM and
    /// JOIN subqueries it doesn't).
    public static func mayHaveScalarSubquery(_ statement: String) -> Bool {
        let text = statement as NSString
        let words = tokens(statement).filter { $0.kind != .whitespace && $0.kind != .comment }
        for (index, token) in words.enumerated() where index + 1 < words.count && text.substring(with: token.range) == "(" {
            let next = text.substring(with: words[index + 1].range).uppercased()
            guard next == "SELECT" || next == "WITH" else { continue }
            let before = index > 0 ? text.substring(with: words[index - 1].range).uppercased() : ""
            if !["IN", "FROM", "JOIN", "UNION", "ALL", "DISTINCT", "AS", "(", "EXCEPT", "INTERSECT"].contains(before) { return true }
        }
        return false
    }
}

extension CHClient {
    /// The server's verdict on a statement without running it: its syntax
    /// (`EXPLAIN AST`, for any statement), then for queries the names and
    /// types it uses (`EXPLAIN QUERY TREE`; `EXPLAIN PLAN` before 24.3).
    /// Checking names runs a statement's scalar subqueries, so it's done
    /// only within `limit` seconds and when `checksNames`; a check the limits
    /// stop says nothing. Problems' ranges are in the statement.
    public func check(_ statement: String, checksNames: Bool = true, limit: Double = 1, database: String? = nil) async throws -> [CHSQL.Problem] {
        // A user with readonly = 1 can't set the limits: names only without scalar subqueries.
        var settings = ["readonly": "2", "cancel_http_readonly_queries_on_client_close": "1",
                        "max_execution_time": String(limit), "timeout_overflow_mode": "throw",
                        "max_rows_to_read": "10000000", "read_overflow_mode": "throw"]
        if !maySetSettings { settings = [:] }
        // (The answer isn't needed: Null, unless the statement names its own format.)
        settings["default_format"] = "Null"
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        // EXPLAIN of an EXPLAIN isn't a statement: those are checked when run.
        guard !trimmed.isEmpty, !trimmed.uppercased().hasPrefix("EXPLAIN") else { return [] }
        let syntax = "EXPLAIN AST "
        do {
            _ = try await plainText(syntax + statement, settings: settings)
        } catch let error as CHServerError {
            return Self.problems(from: error, in: statement, prefix: syntax).map { [$0] } ?? []
        }
        let isQuery = CHSQL.kind(of: statement) == .read
        guard checksNames, maySetSettings || !CHSQL.mayHaveScalarSubquery(statement) else { return [] }
        // Statements that write: their table and columns by the schema, their expressions by the analyzer.
        guard isQuery else {
            var analysis = settings
            analysis["default_format"] = nil
            return try await checkWrite(statement, database: database, settings: analysis)
        }
        guard let error = try await namesError(of: statement, settings: settings) else { return [] }
        // (The place in the request: after the EXPLAIN's words, which the error doesn't say: the name is looked for.)
        return Self.problems(from: error, in: statement, prefix: nil).map { [$0] } ?? []
    }

    /// The analyzer's error on a query's names and types, without running it
    /// (`EXPLAIN QUERY TREE`; `EXPLAIN PLAN` before 24.3 or with the analyzer
    /// off); `nil` for none, or when the limits stopped it.
    func namesError(of query: String, settings: [String: String]) async throws -> CHServerError? {
        let modern = serverInfo?.version.isAtLeast(24, 3) ?? true
        var forms = modern ? ["EXPLAIN QUERY TREE ", "EXPLAIN PLAN "] : ["EXPLAIN PLAN "]
        var settings = settings
        settings["default_format"] = "Null"
        while let form = forms.first {
            forms.removeFirst()
            do {
                _ = try await plainText(form + query, settings: settings)
                return nil
            } catch let error as CHServerError {
                // Not the user's: the limits stopped it, or the analyzer is off (QUERY TREE needs it).
                if [159, 158, 307, 241, 394, 160].contains(error.code) { return nil }
                if error.code == 48 || error.message.localizedCaseInsensitiveContains("analyzer"), !forms.isEmpty { continue }
                return error
            }
        }
        return nil
    }

    /// A server error as a problem of the statement: the place a syntax
    /// error gives (a UTF-8 offset from 1 in the request), or the name an
    /// error quotes (`countr`), and the names it suggests.
    /// `prefix`: what the request had before the statement (`nil`: the
    /// request wasn't the statement, a place in it says nothing of the statement's).
    static func problems(from error: CHServerError, in statement: String, prefix: String?) -> CHSQL.Problem? {
        let text = statement as NSString
        var message = error.message
        var range: NSRange?
        if let prefix, let match = message.range(of: #"failed at position (\d+)"#, options: .regularExpression),
           let position = Int(message[match].split(separator: " ").last ?? "") {
            let offset = position - 1 - prefix.utf8.count
            if offset >= 0, let location = Self.utf16Offset(ofUTF8: offset, in: statement) {
                let token = CHSQL.tokens(statement).first { NSLocationInRange(location, $0.range) && $0.kind != .whitespace }
                range = token?.range ?? NSRange(location: min(location, max(0, text.length - 1)), length: text.length > 0 ? 1 : 0)
            }
            // "Syntax error: failed at position 34 (BY): BY country. Expected one of: …" → "Syntax error at BY. Expected one of: …"
            let near = range.map { text.substring(with: $0) } ?? ""
            var rest = String(message[match.upperBound...])
            if let close = rest.range(of: "): ") {
                rest = String(rest[close.upperBound...])
                if let stop = rest.range(of: ". ") { rest = String(rest[stop.upperBound...]) } else { rest = "" }
            }
            message = near.isEmpty ? String(localized: "Syntax error.") : String(localized: "Syntax error at \(near).")
            if !rest.isEmpty { message += " " + Self.shortened(rest) }
        }
        // "… `countr` in scope SELECT …. Maybe you meant: ['country']." (24.3+), or older servers':
        // "Missing columns: 'numbr' while processing query: '…', required columns: …, maybe you meant: 'number'."
        // "Unknown function cuont: Or unknown aggregate function cuont. Maybe you meant: ['count']: While processing cuont()."
        let original = message
        var suggestions: [String] = []
        if let maybe = message.range(of: "maybe you meant: ", options: .caseInsensitive) {
            var list = message[maybe.upperBound...]
            if list.hasPrefix("[") { list = list.dropFirst().prefix { $0 != "]" } } else { list = list.prefix { $0 != ":" && $0 != "(" } }
            suggestions = list.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"`.")) }.filter { !$0.isEmpty }
            message = String(message[..<maybe.lowerBound])
        }
        for marker in [" in scope ", ". In scope ", ": In scope ", ": while executing ", ". While processing ", ": While processing ",
                       " while processing query", ", required columns", ": Or unknown aggregate function"] {
            if let scope = message.range(of: marker, options: .caseInsensitive) { message = String(message[..<scope.lowerBound]) }
        }
        message = message.trimmingCharacters(in: CharacterSet(charactersIn: " .:,")) + "."
        if range == nil {
            // The name the error is about: quoted (`x`, 'x'), or after "Unknown function", found among the statement's tokens.
            var names: [String] = []
            for quote in ["`", "'"] {
                var rest = Substring(original)
                while let open = rest.range(of: quote), let close = rest[open.upperBound...].range(of: quote) {
                    names.append(String(rest[open.upperBound..<close.lowerBound]))
                    rest = rest[close.upperBound...]
                }
            }
            for lead in ["Unknown function ", "Unknown identifier: ", "Unknown table expression identifier ", "Unknown data type family: "] {
                if let found = original.range(of: lead) {
                    names.append(String(original[found.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }))
                }
            }
            let tokens = CHSQL.tokens(statement).filter { $0.kind != .whitespace }
            for name in names where !name.isEmpty {
                if let token = tokens.first(where: {
                    let text = text.substring(with: $0.range)
                    return text == name || text == "`\(name)`" || text == "\"\(name)\""
                }) {
                    range = token.range
                    break
                }
            }
        }
        // The server's suggestions, the nearest to the wrong name first.
        if let range, suggestions.count > 1 {
            let wrong = text.substring(with: range)
            let ranked = closest(wrong, among: suggestions, limit: suggestions.count, within: Int.max)
            suggestions = ranked + suggestions.filter { !ranked.contains($0) }
        }
        return CHSQL.Problem(range: range, message: message, suggestions: suggestions, isFromServer: true)
    }

    /// "Expected one of: a, b, c, …": the first few.
    private static func shortened(_ text: String) -> String {
        guard let colon = text.range(of: "Expected one of: ") else { return text }
        let items = text[colon.upperBound...].components(separatedBy: ", ")
        guard items.count > 8 else { return text }
        return "Expected one of: " + items.prefix(8).joined(separator: ", ") + ", …"
    }

    /// A UTF-16 offset in a text for a UTF-8 one.
    static func utf16Offset(ofUTF8 offset: Int, in text: String) -> Int? {
        let utf8 = text.utf8
        guard offset <= utf8.count, let index = utf8.index(utf8.startIndex, offsetBy: offset, limitedBy: utf8.endIndex) else { return nil }
        return text.utf16.distance(from: text.utf16.startIndex, to: index.samePosition(in: text.utf16) ?? text.utf16.endIndex)
    }
}
