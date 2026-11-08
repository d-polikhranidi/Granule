import Foundation

/// A statement that writes, as far as checking it needs: INSERT (its table,
/// columns, rows of VALUES or its SELECT), ALTER TABLE (its commands: DELETE,
/// UPDATE, and those on columns) or a lightweight DELETE FROM. Places are
/// UTF-16 ranges in the statement.
struct CHWriteStatement {
    struct Name {
        var name: String
        var range: NSRange
    }

    struct Table {
        var database: String?
        var name: Name
    }

    enum Command {
        case delete(condition: NSRange)
        /// Assignments (the column, its expression) and the condition.
        case update(assignments: [(Name, NSRange)], condition: NSRange)
        case addColumn(Name, ifNotExists: Bool)
        /// DROP, MODIFY, CLEAR, COMMENT, MATERIALIZE or RENAME COLUMN (with its new name).
        case column(verb: String, Name, ifExists: Bool, renamedTo: Name?)
        case other
    }

    enum Kind {
        /// The columns listed (`nil`: the table's), rows of VALUES (each one's
        /// range and count of values), or the SELECT's range.
        case insert(columns: [Name]?, rows: [(NSRange, Int)], select: NSRange?)
        case alter([Command])
        case delete(condition: NSRange)
    }

    var table: Table
    var kind: Kind

    // MARK: Parsing

    private struct Word {
        let token: CHSQL.Token
        let text: String
        var upper: String { text.uppercased() }
    }

    static func parse(_ statement: String) -> CHWriteStatement? {
        let source = statement as NSString
        let words = CHSQL.tokens(statement).filter { $0.kind != .whitespace && $0.kind != .comment }
            .map { Word(token: $0, text: source.substring(with: $0.range)) }
        var at = 0
        func peek(_ offset: Int = 0) -> Word? { at + offset < words.count ? words[at + offset] : nil }
        func take(_ upper: String) -> Bool {
            guard peek()?.upper == upper else { return false }
            at += 1
            return true
        }
        func name() -> Name? {
            guard let word = peek(), word.token.kind == .identifier || word.token.kind == .quotedIdentifier || word.token.kind == .keyword else { return nil }
            at += 1
            return Name(name: unquoted(word.text), range: word.token.range)
        }
        func table() -> Table? {
            guard let first = name() else { return nil }
            if peek()?.text == ".", let second = peek(1), second.token.kind == .identifier || second.token.kind == .quotedIdentifier || second.token.kind == .keyword {
                at += 2
                return Table(database: first.name, name: Name(name: unquoted(second.text), range: second.token.range))
            }
            return Table(database: nil, name: first)
        }
        func skipCluster() {
            if take("ON"), take("CLUSTER") { _ = name() }
        }
        /// The range from here to (not with) a word at depth 0 that `stop` says ends it.
        func expression(until stop: (Word) -> Bool) -> NSRange? {
            let start = at
            var depth = 0
            while let word = peek() {
                if depth == 0, stop(word) { break }
                if ["(", "["].contains(word.text) { depth += 1 }
                if [")", "]"].contains(word.text) { depth -= 1 }
                at += 1
            }
            guard at > start else { return nil }
            let first = words[start].token.range, last = words[at - 1].token.range
            return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        }

        switch peek()?.upper {
        case "INSERT":
            at += 1
            guard take("INTO") else { return nil }
            _ = take("TABLE")
            guard peek()?.upper != "FUNCTION", let target = table() else { return nil }
            var columns: [Name]?
            if peek()?.text == "(" {
                at += 1
                var listed: [Name] = []
                while let word = peek(), word.text != ")" {
                    if word.text == "," {
                        at += 1
                        continue
                    }
                    // A list that isn't plain names (`* EXCEPT (x)`): not checked.
                    guard word.token.kind == .identifier || word.token.kind == .quotedIdentifier || word.token.kind == .keyword,
                          let listedName = name() else {
                        listed = []
                        columns = nil
                        while let rest = peek(), rest.text != ")" { at += 1 }
                        break
                    }
                    listed.append(listedName)
                }
                _ = take(")")
                if !listed.isEmpty { columns = listed }
            }
            if take("SETTINGS") { _ = expression { ["VALUES", "SELECT", "WITH", "FORMAT"].contains($0.upper) } }
            if take("VALUES") {
                var rows: [(NSRange, Int)] = []
                while let word = peek() {
                    if word.text == "," {
                        at += 1
                        continue
                    }
                    guard word.text == "(" else { break }
                    let start = word.token.range.location
                    at += 1
                    var depth = 1, values = 0, sawValue = false
                    while let inner = peek(), depth > 0 {
                        if ["(", "["].contains(inner.text) { depth += 1 }
                        if [")", "]"].contains(inner.text) { depth -= 1 }
                        if depth == 0 { break }
                        if depth == 1, inner.text == "," { values += 1 } else { sawValue = true }
                        at += 1
                    }
                    let end = peek().map { NSMaxRange($0.token.range) } ?? source.length
                    _ = take(")")
                    rows.append((NSRange(location: start, length: end - start), sawValue ? values + 1 : 0))
                }
                return CHWriteStatement(table: target, kind: .insert(columns: columns, rows: rows, select: nil))
            }
            if let word = peek(), ["SELECT", "WITH"].contains(word.upper) || (word.text == "(" && ["SELECT", "WITH"].contains(peek(1)?.upper ?? "")) {
                let range = NSRange(location: word.token.range.location, length: source.length - word.token.range.location)
                let select = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                return CHWriteStatement(table: target, kind: .insert(columns: columns, rows: [],
                                                                     select: NSRange(location: range.location, length: (select as NSString).length)))
            }
            // FORMAT …: the rows follow as data.
            return CHWriteStatement(table: target, kind: .insert(columns: columns, rows: [], select: nil))
        case "ALTER":
            at += 1
            guard take("TABLE"), let target = table() else { return nil }
            skipCluster()
            var commands: [Command] = []
            let endsCommand: (Word) -> Bool = { $0.text == "," || $0.upper == "SETTINGS" }
            while let word = peek(), word.upper != "SETTINGS" {
                if word.text == "," {
                    at += 1
                    continue
                }
                let verb = word.upper
                at += 1
                switch verb {
                case "DELETE":
                    if take("IN") { _ = expression { $0.upper == "WHERE" } }
                    guard take("WHERE"), let condition = expression(until: endsCommand) else {
                        commands.append(.other)
                        _ = expression(until: endsCommand)
                        continue
                    }
                    commands.append(.delete(condition: condition))
                case "UPDATE":
                    var assignments: [(Name, NSRange)] = []
                    while let column = name() {
                        guard take("="), let value = expression(until: { $0.text == "," || $0.upper == "WHERE" || $0.upper == "IN" }) else { break }
                        assignments.append((column, value))
                        if !take(",") { break }
                    }
                    if take("IN") { _ = expression { $0.upper == "WHERE" } }
                    guard take("WHERE"), let condition = expression(until: endsCommand), !assignments.isEmpty else {
                        commands.append(.other)
                        _ = expression(until: endsCommand)
                        continue
                    }
                    commands.append(.update(assignments: assignments, condition: condition))
                case "ADD", "DROP", "MODIFY", "CLEAR", "COMMENT", "MATERIALIZE", "RENAME":
                    guard take("COLUMN") else {
                        commands.append(.other)
                        _ = expression(until: endsCommand)
                        continue
                    }
                    var ifExists = false, ifNotExists = false
                    if take("IF") {
                        if take("NOT") { ifNotExists = true }
                        ifExists = take("EXISTS")
                    }
                    guard let column = name() else { break }
                    var renamed: Name?
                    if verb == "RENAME", take("TO") { renamed = name() }
                    commands.append(verb == "ADD" ? .addColumn(column, ifNotExists: ifNotExists)
                                    : .column(verb: verb, column, ifExists: ifExists, renamedTo: renamed))
                    _ = expression(until: endsCommand)
                default:
                    commands.append(.other)
                    _ = expression(until: endsCommand)
                }
            }
            return CHWriteStatement(table: target, kind: .alter(commands))
        case "DELETE":
            at += 1
            guard take("FROM"), let target = table() else { return nil }
            skipCluster()
            if take("IN") { _ = expression { $0.upper == "WHERE" } }
            guard take("WHERE"), let condition = expression(until: { $0.upper == "SETTINGS" }) else { return nil }
            return CHWriteStatement(table: target, kind: .delete(condition: condition))
        default:
            return nil
        }
    }

    private static func unquoted(_ name: String) -> String {
        guard name.count >= 2, let first = name.first, first == "`" || first == "\"" else { return name }
        return String(name.dropFirst().dropLast())
    }
}

extension CHClient {
    /// A column of a table as checking writes needs it.
    struct CheckedColumn {
        var name: String
        /// DEFAULT, MATERIALIZED, ALIAS, EPHEMERAL (empty for none).
        var kind: String
        /// In the sorting, primary or partition key: it can't be updated.
        var isKey: Bool
    }

    /// What the server won't tell of a statement that writes without running
    /// it: its table and columns checked by the schema (read now: the
    /// sidebar's may be old), the number of values, and its expressions
    /// (WHERE, UPDATE's values, INSERT's SELECT) by the analyzer, as a SELECT
    /// that reads the same table. `database`: the session's current one.
    func checkWrite(_ statement: String, database: String?, settings: [String: String]) async throws -> [CHSQL.Problem] {
        guard let write = CHWriteStatement.parse(statement) else { return [] }
        let text = statement as NSString
        let databaseSQL = (write.table.database ?? database).map(CHSQL.quotedString) ?? "currentDatabase()"
        let qualified = (write.table.database ?? database).map { CHSQL.quotedName($0) + "." } ?? ""
        let tableSQL = qualified + CHSQL.quotedName(write.table.name.name)
        // A temporary table lives in the session alone: not checked.
        if statement.range(of: "TEMPORARY TABLE", options: .caseInsensitive) != nil { return [] }
        let columnRows = try await result("""
            SELECT name, default_kind, is_in_sorting_key OR is_in_primary_key OR is_in_partition_key
            FROM system.columns WHERE database = \(databaseSQL) AND table = \(CHSQL.quotedString(write.table.name.name)) ORDER BY position
            """).rows()
        let columns = columnRows.compactMap { $0.count >= 3 ? CheckedColumn(name: $0[0], kind: $0[1], isKey: $0[2] == "1") : nil }
        if columns.isEmpty {
            let tables = try await result("SELECT name FROM system.tables WHERE database = \(databaseSQL)").rows().compactMap(\.first)
            if !tables.contains(write.table.name.name) {
                return [CHSQL.Problem(range: write.table.name.range,
                                      message: String(localized: "There's no table \(write.table.name.name) in this database.", bundle: .module),
                                      suggestions: Self.closest(write.table.name.name, among: tables), isFromServer: true)]
            }
            // A view or a table without columns in the list: nothing more to tell.
            return []
        }
        let names = columns.map(\.name)
        let byName = Dictionary(columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var problems: [CHSQL.Problem] = []
        func noColumn(_ column: CHWriteStatement.Name) {
            problems.append(CHSQL.Problem(range: column.range, message: String(localized: "There's no column \(column.name) in \(write.table.name.name).", bundle: .module),
                                          suggestions: Self.closest(column.name, among: names), isFromServer: true))
        }
        /// The analyzer's verdict on expressions over the table: `SELECT … FROM table WHERE …`.
        func analyze(values: [NSRange], condition: NSRange?) async throws {
            let selected = values.isEmpty ? "1" : values.map { text.substring(with: $0) }.joined(separator: ", ")
            let condition = condition.map { "\nWHERE " + text.substring(with: $0) } ?? ""
            let select = "SELECT \(selected)\nFROM \(tableSQL)\(condition)"
            if let error = try await namesError(of: select, settings: settings) {
                guard var problem = Self.problems(from: error, in: statement, prefix: nil) else { return }
                // The table's nearest columns, if the server named none.
                if problem.suggestions.isEmpty, let range = problem.range {
                    problem.suggestions = Self.closest(text.substring(with: range), among: names)
                }
                problems.append(problem)
            }
        }
        switch write.kind {
        case .insert(let listed, let rows, let select):
            for column in listed ?? [] {
                guard let known = byName[column.name] else {
                    noColumn(column)
                    continue
                }
                if known.kind == "MATERIALIZED" || known.kind == "ALIAS" {
                    problems.append(CHSQL.Problem(range: column.range,
                                                  message: String(localized: "\(column.name) is an \(known.kind) column: its values are computed, not inserted.", bundle: .module),
                                                  isFromServer: true))
                }
            }
            guard problems.isEmpty else { return problems }
            // The values a row takes: the columns listed, or the table's that aren't computed.
            let hasEphemeral = columns.contains { $0.kind == "EPHEMERAL" }
            let expected = listed?.count ?? (hasEphemeral ? nil : columns.filter { $0.kind != "MATERIALIZED" && $0.kind != "ALIAS" }.count)
            if let expected {
                for (range, count) in rows where count != expected {
                    problems.append(CHSQL.Problem(range: range, message: String(localized: "This row has \(count) values: the insert takes \(expected).", bundle: .module),
                                                  isFromServer: true))
                }
            }
            if let select {
                // The SELECT's columns, by the analyzer, without running it (its names are checked too).
                do {
                    let described = try await result("DESCRIBE (\n\(text.substring(with: select))\n)", settings: settings)
                    if let expected, described.rowCount != expected {
                        problems.append(CHSQL.Problem(range: NSRange(location: select.location, length: min(6, select.length)),
                                                      message: String(localized: "The SELECT gives \(described.rowCount) columns: the insert takes \(expected).", bundle: .module),
                                                      isFromServer: true))
                    }
                } catch let error as CHServerError {
                    if ![159, 158, 307, 241, 394, 160].contains(error.code), let problem = Self.problems(from: error, in: statement, prefix: nil) {
                        problems.append(problem)
                    }
                }
            }
        case .alter(let commands):
            for command in commands {
                switch command {
                case .delete(let condition):
                    try await analyze(values: [], condition: condition)
                case .update(let assignments, let condition):
                    var good = true
                    for (column, _) in assignments {
                        guard let known = byName[column.name] else {
                            noColumn(column)
                            good = false
                            continue
                        }
                        if known.isKey {
                            problems.append(CHSQL.Problem(range: column.range,
                                                          message: String(localized: "\(column.name) is in the table's key: it can't be updated.", bundle: .module),
                                                          isFromServer: true))
                        } else if known.kind == "MATERIALIZED" || known.kind == "ALIAS" {
                            problems.append(CHSQL.Problem(range: column.range,
                                                          message: String(localized: "\(column.name) is an \(known.kind) column: it can't be updated.", bundle: .module),
                                                          isFromServer: true))
                        }
                    }
                    if good { try await analyze(values: assignments.map(\.1), condition: condition) }
                case .addColumn(let column, let ifNotExists):
                    if byName[column.name] != nil, !ifNotExists {
                        problems.append(CHSQL.Problem(range: column.range, message: String(localized: "\(write.table.name.name) has a column \(column.name) already.", bundle: .module),
                                                      isFromServer: true))
                    }
                case .column(_, let column, let ifExists, let renamed):
                    if byName[column.name] == nil, !ifExists { noColumn(column) }
                    if let renamed, byName[renamed.name] != nil {
                        problems.append(CHSQL.Problem(range: renamed.range, message: String(localized: "\(write.table.name.name) has a column \(renamed.name) already.", bundle: .module),
                                                      isFromServer: true))
                    }
                case .other:
                    break
                }
            }
        case .delete(let condition):
            try await analyze(values: [], condition: condition)
        }
        return problems
    }

    /// The names nearest a misspelt one (edit distance), the nearest first.
    static func closest(_ name: String, among names: [String], limit: Int = 3, within: Int? = nil) -> [String] {
        let target = Array(name.lowercased())
        let allowed = within ?? max(2, target.count / 3)
        return names.compactMap { candidate -> (String, Int)? in
            let distance = editDistance(target, Array(candidate.lowercased()))
            return distance <= allowed && candidate != name ? (candidate, distance) : nil
        }
        .sorted { ($0.1, $0.0) < ($1.1, $1.0) }.prefix(limit).map(\.0)
    }

    /// Edits from one name to another: a letter added, removed, changed, or
    /// two neighbours swapped (cuont → count is one).
    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1) }
            }
        }
        return table[a.count][b.count]
    }
}
