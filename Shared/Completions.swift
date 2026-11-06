import ClickHouseCore
import Foundation

/// The words the editor completes: the server's own list (`system.completions`,
/// 25.8+: columns, tables, functions, settings, keywords, formats, …) or,
/// from older servers, the same gathered from their system tables.
final class Completions {
    struct Word {
        let text: String
        /// What it is (column, function, keyword, …): the order among equal prefixes.
        let rank: Int
    }

    /// Words sorted by their lowercase text.
    private var words: [Word] = []
    private var lowercased: [String] = []

    var isEmpty: Bool { words.isEmpty }

    /// Loaded once a connection is up (in the background; the editor works without them).
    static func load(_ client: CHClient) async -> Completions {
        let completions = Completions()
        var found: [(String, String)] = []
        if client.serverInfo?.version.isAtLeast(25, 8) == true,
           let result = try? await client.result("SELECT word, context FROM system.completions LIMIT 200000") {
            found = result.rows().compactMap { $0.count >= 2 ? ($0[0], $0[1]) : nil }
        }
        if found.isEmpty {
            let sources = [
                ("SELECT name, 'function' FROM system.functions", "function"),
                ("SELECT name, 'table function' FROM system.table_functions", "table function"),
                ("SELECT name, 'setting' FROM system.settings", "setting"),
                ("SELECT name, 'format' FROM system.formats", "format"),
                ("SELECT name, 'data type' FROM system.data_type_families", "data type"),
                ("SELECT name, 'table engine' FROM system.table_engines", "table engine"),
                ("SELECT name, 'database' FROM system.databases", "database"),
                ("SELECT DISTINCT name, 'table' FROM system.tables LIMIT 50000", "table"),
                ("SELECT DISTINCT name, 'column' FROM system.columns LIMIT 100000", "column"),
            ]
            for (sql, _) in sources {
                guard let result = try? await client.result(sql) else { continue }
                found += result.rows().compactMap { $0.count >= 2 ? ($0[0], $0[1]) : nil }
            }
            found += CHSQL.keywords.map { ($0, "keyword") }
        }
        completions.set(found)
        return completions
    }

    private static func rank(_ context: String) -> Int {
        switch context {
        case "column": 0
        case "table": 1
        case "database": 2
        case "keyword": 3
        case "function", "table function": 4
        case "data type", "format", "table engine": 5
        case "setting", "merge tree setting": 6
        default: 7
        }
    }

    private func set(_ found: [(String, String)]) {
        var best: [String: Word] = [:]
        for (text, context) in found where text.count >= 2 && !text.contains(where: \.isWhitespace) {
            let rank = Self.rank(context)
            if let known = best[text], known.rank <= rank { continue }
            best[text] = Word(text: text, rank: rank)
        }
        words = best.values.sorted { ($0.text.lowercased(), $0.rank) < ($1.text.lowercased(), $1.rank) }
        lowercased = words.map { $0.text.lowercased() }
    }

    /// The columns of the tables the statement reads (offered first), by table.
    private var tableColumns: [String: [String]] = [:]
    private var loading: Set<String> = []

    /// Tables a statement names after FROM and JOIN: `db.table` or `table`.
    static func tables(in statement: String) -> [String] {
        let text = statement as NSString
        let words = CHSQL.tokens(statement).filter { $0.kind != .whitespace && $0.kind != .comment }
        var tables: [String] = []
        var index = 0
        while index < words.count {
            let word = text.substring(with: words[index].range).uppercased()
            if word == "FROM" || word == "JOIN", index + 1 < words.count, [.identifier, .quotedIdentifier].contains(words[index + 1].kind) {
                var name = unquoted(text.substring(with: words[index + 1].range))
                if index + 3 < words.count, text.substring(with: words[index + 2].range) == ".",
                   [.identifier, .quotedIdentifier].contains(words[index + 3].kind) {
                    name += "." + unquoted(text.substring(with: words[index + 3].range))
                    index += 2
                }
                tables.append(name)
            }
            index += 1
        }
        return tables
    }

    private static func unquoted(_ name: String) -> String {
        guard name.count >= 2, let first = name.first, first == "`" || first == "\"" else { return name }
        return String(name.dropFirst().dropLast())
    }

    /// The columns of the tables a statement reads, loaded once each (then `done`).
    func loadColumns(of statement: String, client: CHClient, database: String, done: @escaping @MainActor () -> Void) {
        for table in Self.tables(in: statement) where tableColumns[table] == nil && !loading.contains(table) {
            loading.insert(table)
            let parts = table.split(separator: ".", maxSplits: 1).map(String.init)
            let (db, name) = parts.count == 2 ? (parts[0], parts[1]) : (database, parts[0])
            Task { [weak self] in
                let condition = db.isEmpty ? "database = currentDatabase()" : "database = \(CHSQL.quotedString(db))"
                let result = try? await client.result("SELECT name FROM system.columns WHERE \(condition) AND table = \(CHSQL.quotedString(name))")
                guard let self else { return }
                tableColumns[table] = result?.rows().compactMap(\.first) ?? []
                loading.remove(table)
                done()
            }
        }
    }

    /// Words beginning with `prefix` (small and capital letters alike): the
    /// columns of the statement's tables first, then other columns and
    /// tables, keywords, functions, the rest; the shorter first among them.
    func matches(_ prefix: String, in statement: String = "", limit: Int = 60) -> [String] {
        let key = prefix.lowercased()
        let own = Self.tables(in: statement).flatMap { tableColumns[$0] ?? [] }.filter { $0.lowercased().hasPrefix(key) && $0 != prefix }
        let others = matches(key: key, exact: prefix, limit: limit)
        var seen = Set(own)
        return Array((own.sorted { ($0.count, $0) < ($1.count, $1) } + others.filter { seen.insert($0).inserted }).prefix(limit))
    }

    private func matches(key: String, exact prefix: String, limit: Int) -> [String] {
        let key = prefix.lowercased()
        guard !key.isEmpty else { return [] }
        // The first word not before the prefix.
        var low = 0, high = lowercased.count
        while low < high {
            let middle = (low + high) / 2
            if lowercased[middle] < key { low = middle + 1 } else { high = middle }
        }
        var found: [Word] = []
        var index = low
        while index < lowercased.count, lowercased[index].hasPrefix(key), found.count < 2_000 {
            if lowercased[index] != key || words[index].text != prefix { found.append(words[index]) }
            index += 1
        }
        return found.sorted { ($0.rank, $0.text.count, $0.text) < ($1.rank, $1.text.count, $1.text) }.prefix(limit).map(\.text)
    }

    /// The word being typed before a place in the text: its range (UTF-16).
    static func partialWord(in text: NSString, before location: Int) -> NSRange {
        var start = location
        while start > 0, let scalar = UnicodeScalar(text.character(at: start - 1)), isNameCharacter(scalar) { start -= 1 }
        return NSRange(location: start, length: location - start)
    }

    static func isNameCharacter(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
    }
}
