import Foundation

/// ClickHouse SQL as the editor needs it: tokens (for colors), statements
/// (split at semicolons outside strings and comments), what a statement
/// does (reads or writes), its `FORMAT` clause and its `{name:Type}` parameters.
public enum CHSQL {
    public enum TokenKind: Sendable, Equatable {
        case whitespace, comment, string, quotedIdentifier, number, keyword, identifier, parameter, punctuation, semicolon
    }

    public struct Token: Sendable, Equatable {
        public var kind: TokenKind
        /// Where it is in the text, in UTF-16 units (NSString's ranges).
        public var range: NSRange
    }

    /// The text's tokens, in order, every unit in one.
    public static func tokens(_ text: String) -> [Token] {
        let units = Array(text.utf16)
        var tokens: [Token] = []
        var at = 0
        func add(_ kind: TokenKind, from start: Int) {
            tokens.append(Token(kind: kind, range: NSRange(location: start, length: at - start)))
        }
        while at < units.count {
            let start = at
            let unit = units[at]
            let next = at + 1 < units.count ? units[at + 1] : 0
            switch unit {
            case 0x20, 0x09, 0x0A, 0x0D:
                while at < units.count, [0x20, 0x09, 0x0A, 0x0D].contains(units[at]) { at += 1 }
                add(.whitespace, from: start)
            case 0x2D where next == 0x2D, 0x23 where next == 0x20 || next == 0x21:
                // -- comment, # comment, #! (a shebang line)
                while at < units.count, units[at] != 0x0A { at += 1 }
                add(.comment, from: start)
            case 0x2F where next == 0x2A:
                at += 2
                while at < units.count, !(units[at] == 0x2A && at + 1 < units.count && units[at + 1] == 0x2F) { at += 1 }
                at = min(units.count, at + 2)
                add(.comment, from: start)
            case 0x27, 0x60, 0x22:
                // 'string', `identifier`, "identifier": backslash escapes, a doubled quote is one.
                at += 1
                while at < units.count {
                    if units[at] == 0x5C {
                        at += 2
                        continue
                    }
                    if units[at] == unit {
                        if at + 1 < units.count, units[at + 1] == unit {
                            at += 2
                            continue
                        }
                        at += 1
                        break
                    }
                    at += 1
                }
                at = min(at, units.count)
                add(unit == 0x27 ? .string : .quotedIdentifier, from: start)
            case 0x7B:
                // {name:Type}
                at += 1
                while at < units.count, units[at] != 0x7D, units[at] != 0x0A { at += 1 }
                if at < units.count, units[at] == 0x7D { at += 1 }
                add(.parameter, from: start)
            case 0x3B:
                at += 1
                add(.semicolon, from: start)
            case 0x30...0x39:
                while at < units.count, isNumberUnit(units[at]) || ((units[at] == 0x2B || units[at] == 0x2D) && (units[at - 1] | 0x20) == 0x65) {
                    at += 1
                }
                add(.number, from: start)
            default:
                if isNameUnit(unit) {
                    while at < units.count, isNameUnit(units[at]) || (0x30...0x39).contains(units[at]) { at += 1 }
                    let word = String(utf16CodeUnits: Array(units[start..<at]), count: at - start).uppercased()
                    add(keywords.contains(word) ? .keyword : .identifier, from: start)
                } else {
                    at += 1
                    add(.punctuation, from: start)
                }
            }
        }
        return tokens
    }

    private static func isNameUnit(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit == 0x24 || unit >= 0x80
    }

    private static func isNumberUnit(_ unit: UInt16) -> Bool {
        (unit >= 0x30 && unit <= 0x39) || unit == 0x2E || unit == 0x5F || (unit | 0x20) == 0x65 || (unit | 0x20) == 0x78
            || ((unit | 0x20) >= 0x61 && (unit | 0x20) <= 0x66)
    }

    /// The statements of a text: their ranges (UTF-16), without the
    /// semicolons, skipping those of only whitespace and comments.
    public static func statements(_ text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var start: Int?
        var end = 0
        for token in tokens(text) {
            switch token.kind {
            case .semicolon:
                if let first = start { ranges.append(NSRange(location: first, length: end - first)) }
                start = nil
            case .whitespace, .comment:
                continue
            default:
                if start == nil { start = token.range.location }
                end = NSMaxRange(token.range)
            }
        }
        if let first = start { ranges.append(NSRange(location: first, length: end - first)) }
        return ranges
    }

    /// The statement at a place in the text (the one the cursor is in or
    /// just after), `nil` if there's none.
    public static func statement(at location: Int, in text: String) -> NSRange? {
        let ranges = statements(text)
        if let inside = ranges.first(where: { $0.location <= location && location <= NSMaxRange($0) }) { return inside }
        // After the last one, or in the gap before the next: the one before.
        return ranges.last(where: { NSMaxRange($0) <= location }) ?? ranges.first
    }

    /// What a statement does, by its first word.
    public enum Kind: Sendable, Equatable {
        /// SELECT, WITH, SHOW, DESCRIBE, EXPLAIN, EXISTS, CHECK: rows to show.
        case read
        /// Anything else: INSERT, CREATE, ALTER, SET, KILL, …
        case other
    }

    public static func kind(of statement: String) -> Kind {
        guard let word = firstWord(of: statement) else { return .other }
        return ["SELECT", "WITH", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "EXISTS", "CHECK", "VALUES", "FROM", "TABLE"].contains(word)
            ? .read : .other
    }

    /// Whether a statement destroys or rewrites what's there: DROP, TRUNCATE,
    /// DELETE and UPDATE, ALTER (its mutations and its schema changes), DETACH,
    /// RENAME, EXCHANGE, KILL, REPLACE and CREATE OR REPLACE, OPTIMIZE (FINAL,
    /// DEDUPLICATE), RESTORE, SYSTEM DROP … REPLICA. A production server's asks
    /// for its name first.
    public static func isDestructive(_ statement: String) -> Bool {
        let words = leadingWords(of: statement, count: 4)
        guard let first = words.first else { return false }
        if ["DROP", "TRUNCATE", "DELETE", "UPDATE", "ALTER", "DETACH", "RENAME", "EXCHANGE", "KILL", "REPLACE", "OPTIMIZE", "RESTORE"]
            .contains(first) { return true }
        if first == "CREATE", words.count >= 3, words[1] == "OR", words[2] == "REPLACE" { return true }
        return first == "SYSTEM" && words.count >= 3 && words[1] == "DROP" && words.contains("REPLICA")
    }

    /// Whether a query stops reading once it has its rows, as `EXPLAIN ESTIMATE` doesn't
    /// tell: a LIMIT of its own (not of a subquery) without ORDER BY, GROUP BY, DISTINCT,
    /// LIMIT … BY, a window, a UNION or an aggregate function there, which read everything first.
    public static func stopsEarly(_ query: String) -> Bool {
        let text = query as NSString
        let words = tokens(query).filter { $0.kind != .whitespace && $0.kind != .comment }
        var depth = 0
        var limited = false
        for (index, token) in words.enumerated() {
            let word = text.substring(with: token.range)
            if token.kind == .punctuation {
                if word == "(" { depth += 1 } else if word == ")" { depth = max(0, depth - 1) }
                continue
            }
            guard depth == 0, token.kind == .keyword || token.kind == .identifier else { continue }
            let upper = word.uppercased()
            if ["ORDER", "GROUP", "DISTINCT", "OVER", "UNION", "INTERSECT", "EXCEPT"].contains(upper) { return false }
            if upper == "BY", limited { return false }
            if upper == "LIMIT" { limited = true }
            // An aggregate over the rows: count(), sumIf(), uniqExact(), …
            if index + 1 < words.count, text.substring(with: words[index + 1].range) == "(" {
                let name = word.lowercased()
                if ["min", "max", "any", "avg", "median", "argmin", "argmax", "corr", "varpop", "stddevpop"].contains(name)
                    || ["count", "sum", "uniq", "quantile", "group", "topk", "avg", "anylast", "anyheavy", "argmin", "argmax", "min", "max"]
                        .contains(where: { name.hasPrefix($0) && name != "minus" && !name.hasPrefix("maxim") && !name.hasPrefix("minim") }) {
                    return false
                }
            }
        }
        return limited
    }

    /// The table, view or dictionary a CREATE statement makes (its name, without its database
    /// or quotes), `nil` for other statements: a script's later statements use what it makes.
    public static func createdName(of statement: String) -> String? {
        let text = statement as NSString
        let words = tokens(statement).filter { $0.kind != .whitespace && $0.kind != .comment }
        func word(_ index: Int) -> String { index < words.count ? text.substring(with: words[index].range) : "" }
        guard word(0).uppercased() == "CREATE" else { return nil }
        var index = 1
        while !["TABLE", "VIEW", "DICTIONARY"].contains(word(index).uppercased()) {
            // A database, a user, a function: no table.
            guard ["OR", "REPLACE", "TEMPORARY", "MATERIALIZED"].contains(word(index).uppercased()) else { return nil }
            index += 1
        }
        index += 1
        if word(index).uppercased() == "IF" { index += 3 }
        if word(index + 1) == "." { index += 2 }
        guard index < words.count, [.identifier, .keyword, .quotedIdentifier].contains(words[index].kind) else { return nil }
        let name = word(index)
        return words[index].kind == .quotedIdentifier ? String(name.dropFirst().dropLast()) : name
    }

    /// A statement's first word, upper-cased (comments and brackets before it skipped).
    public static func firstWord(of statement: String) -> String? {
        leadingWords(of: statement, count: 1).first
    }

    /// A statement's first words, upper-cased (comments and punctuation skipped).
    private static func leadingWords(of statement: String, count: Int) -> [String] {
        let text = statement as NSString
        return tokens(statement).lazy.filter { $0.kind != .whitespace && $0.kind != .comment && $0.kind != .punctuation }
            .prefix(count).map { text.substring(with: $0.range).uppercased() }
    }

    /// The format a statement's own `FORMAT` clause asks for (its last
    /// `FORMAT name` outside strings and comments), `nil` without one.
    public static func formatClause(of statement: String) -> String? {
        let words = tokens(statement).filter { $0.kind != .whitespace && $0.kind != .comment }
        let text = statement as NSString
        guard words.count >= 2 else { return nil }
        for index in stride(from: words.count - 2, through: 0, by: -1) where words[index].kind == .keyword {
            guard text.substring(with: words[index].range).uppercased() == "FORMAT" else { continue }
            let name = words[index + 1]
            guard name.kind == .identifier || name.kind == .keyword else { return nil }
            return text.substring(with: name.range)
        }
        return nil
    }

    /// A query parameter of a statement: `{name:Type}`.
    public struct Parameter: Sendable, Hashable {
        public var name: String
        public var type: String
    }

    /// The statement's parameters, each once, in order.
    public static func parameters(of statement: String) -> [Parameter] {
        let text = statement as NSString
        var seen = Set<String>(), parameters: [Parameter] = []
        for token in tokens(statement) where token.kind == .parameter {
            let inner = text.substring(with: NSRange(location: token.range.location + 1, length: max(0, token.range.length - 2)))
            guard let colon = inner.firstIndex(of: ":") else { continue }
            let name = inner[..<colon].trimmingCharacters(in: .whitespaces)
            let type = inner[inner.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !type.isEmpty, seen.insert(name).inserted else { continue }
            parameters.append(Parameter(name: name, type: type))
        }
        return parameters
    }

    /// A name quoted for SQL where it needs it (`back quotes`).
    public static func quotedName(_ name: String) -> String {
        let plain = !name.isEmpty && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
            && !(name.first?.isNumber ?? true)
        return plain ? name : "`" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`") + "`"
    }

    /// A string literal.
    public static func quotedString(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// Words shown as keywords (ClickHouse's own list is longer: the
    /// server's `system.keywords` adds the rest for completion).
    public static let keywords: Set<String> = [
        "ADD", "AFTER", "ALIAS", "ALL", "ALTER", "AND", "ANTI", "ANY", "ARRAY", "AS", "ASC", "ASOF", "ATTACH", "BETWEEN", "BOTH", "BY",
        "CASE", "CAST", "CHECK", "CLEAR", "CLUSTER", "CODEC", "COLUMN", "COMMENT", "CONSTRAINT", "CREATE", "CROSS", "CUBE", "DATABASE",
        "DATABASES", "DEFAULT", "DELETE", "DESC", "DESCENDING", "DESCRIBE", "DETACH", "DICTIONARY", "DISTINCT", "DROP", "ELSE", "END",
        "ENGINE", "EXCEPT", "EXISTS", "EXPLAIN", "FALSE", "FILL", "FINAL", "FIRST", "FOR", "FORMAT", "FROM", "FULL", "FUNCTION", "GLOBAL",
        "GRANT", "GROUP", "HAVING", "IF", "ILIKE", "IN", "INDEX", "INNER", "INSERT", "INTERSECT", "INTERVAL", "INTO", "IS", "JOIN", "KEY",
        "KILL", "LAST", "LEFT", "LIKE", "LIMIT", "LIVE", "LOCAL", "MATERIALIZED", "MODIFY", "NOT", "NULL", "NULLS", "OFFSET", "ON",
        "OPTIMIZE", "OR", "ORDER", "OUTER", "OVER", "PARTITION", "PARTITIONS", "POPULATE", "PREWHERE", "PRIMARY", "PROJECTION", "QUERY",
        "RENAME", "REPLACE", "REVOKE", "RIGHT", "ROLLUP", "SAMPLE", "SELECT", "SEMI", "SET", "SETTINGS", "SHOW", "SYNC", "SYSTEM", "TABLE",
        "TABLES", "TEMPORARY", "THEN", "TO", "TOP", "TOTALS", "TRUE", "TRUNCATE", "TTL", "UNION", "UPDATE", "USE", "USING", "VALUES",
        "VIEW", "WATCH", "WHEN", "WHERE", "WINDOW", "WITH", "ASYNC", "STEP", "INTERPOLATE", "QUALIFY",
    ]
}
