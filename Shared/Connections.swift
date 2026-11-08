import ClickHouseCore
import CryptoKit
import Foundation
import Security
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The servers the user added: kept in the app's defaults, their passwords
/// in the Keychain.
final class Connections {
    static let shared = Connections()

    #if DEBUG
    /// `-ViewerForm testfail`, `ssh` and `playground` run on a list and Keychain entries of their own (the
    /// user's aren't touched, and nothing made by another build is read).
    static let isChecking = ["testfail", "ssh", "playground"].contains(UserDefaults.standard.string(forKey: "ViewerForm"))
        || UserDefaults.standard.string(forKey: "ViewerImport") != nil
    private static let key = isChecking ? "ConnectionsForChecks" : "Connections"
    #else
    private static let key = "Connections"
    #endif
    private(set) var endpoints: [CHEndpoint] = []
    /// Called when the list changed.
    var onChange: [() -> Void] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([CHEndpoint].self, from: data) {
            endpoints = saved
        }
        #if DEBUG
        // The last check's connections gone, with all that was kept for them.
        if Self.isChecking {
            endpoints.forEach { Self.forget($0.id) }
            endpoints = []
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
        #endif
    }

    private func save() {
        if let data = try? JSONEncoder().encode(endpoints) { UserDefaults.standard.set(data, forKey: Self.key) }
        onChange.forEach { $0() }
    }

    /// Adds an endpoint or changes the one with its id; its password if given.
    func save(_ endpoint: CHEndpoint, password: String?) {
        if let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) {
            endpoints[index] = endpoint
        } else {
            endpoints.append(endpoint)
        }
        if let password { Keychain.setPassword(password, for: endpoint.id) }
        save()
    }

    func remove(_ endpoint: CHEndpoint) {
        endpoints.removeAll { $0.id == endpoint.id }
        Self.forget(endpoint.id)
        save()
    }

    /// Whether the connection is in the list (not removed, not a server opened without saving it).
    func keeps(_ id: UUID) -> Bool { endpoints.contains { $0.id == id } }

    /// ClickHouse's public playground in the list, offered while it's empty: a server to try
    /// the app on (play.clickhouse.com, the user `explorer` without a password, read only).
    /// The one there already if it is.
    func addPlayground() -> CHEndpoint {
        if let there = endpoints.first(where: { $0.host == "play.clickhouse.com" && $0.user == "explorer" }) { return there }
        let playground = CHEndpoint(name: uniqueName(String(localized: "ClickHouse Playground"), except: nil), host: "play.clickhouse.com",
                                    port: 443, isSecure: true, user: "explorer", isReadOnly: true)
        save(playground, password: "")
        return playground
    }

    /// Everything kept for a connection: its password, SSH secret and client certificate,
    /// its windows' places and editors' texts (the defaults named with its id), its history.
    static func forget(_ id: UUID) {
        Keychain.removePassword(for: id)
        Keychain.removeData(for: id, suffix: ".ssh")
        removeClientCertificate(for: id)
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.contains(id.uuidString) { defaults.removeObject(forKey: key) }
        QueryHistory.remove(for: id)
    }

    #if DEBUG
    /// `-ViewerURL`'s server: the same id for the same URL, so test runs share one window
    /// place and history instead of leaving another set each time.
    static func debugID(for url: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(url.utf8)))
        return digest.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress) as UUID }
    }
    #endif

    func move(from source: Int, to destination: Int) {
        guard endpoints.indices.contains(source) else { return }
        let endpoint = endpoints.remove(at: source)
        endpoints.insert(endpoint, at: min(destination, endpoints.count))
        save()
    }

    func password(for endpoint: CHEndpoint) -> String { Keychain.password(for: endpoint.id) ?? "" }

    /// Whether another connection than `id` has this name (letter case aside).
    func isNameTaken(_ name: String, except id: UUID?) -> Bool {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return endpoints.contains { $0.id != id && $0.name.trimmingCharacters(in: .whitespaces).lowercased() == wanted }
    }

    /// `base`, or `base 2`, `base 3`, … : a name no other connection has.
    func uniqueName(_ base: String, except id: UUID?) -> String {
        let base = base.trimmingCharacters(in: .whitespaces)
        guard isNameTaken(base, except: id) else { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !self.isNameTaken($0, except: id) }!
    }

    /// clickhouse-client's connections added to the list, each named as there (or by its host,
    /// as a new one is), its password kept; those in the list already (the same host, port,
    /// user and database) left out.
    func add(_ imported: [CHClientConfig.Connection]) -> (added: [CHEndpoint], skipped: Int) {
        var added: [CHEndpoint] = [], skipped = 0
        for connection in imported {
            var endpoint = connection.endpoint
            let isThere = endpoints.contains {
                $0.host.lowercased() == endpoint.host.lowercased() && $0.port == endpoint.port && $0.user == endpoint.user
                    && $0.database == endpoint.database
            }
            if isThere {
                skipped += 1
                continue
            }
            if endpoint.name.isEmpty {
                endpoint.name = suggestedName(host: endpoint.host, except: nil)
                endpoint.nameIsSuggested = true
            } else {
                endpoint.name = uniqueName(endpoint.name, except: nil)
            }
            save(endpoint, password: connection.password ?? "")
            added.append(endpoint)
        }
        return (added, skipped)
    }

    /// What an import did, as an alert says it.
    static func importSummary(of found: [CHClientConfig.Connection], added: [CHEndpoint], skipped: Int) -> (title: String, detail: String) {
        guard !found.isEmpty else {
            return (String(localized: "No connections in this file"),
                    String(localized: "clickhouse-client keeps them under connections_credentials, or its server under host."))
        }
        var lines: [String] = []
        if !added.isEmpty { lines.append(added.map(\.name).joined(separator: ", ")) }
        if skipped > 0 {
            lines.append(skipped == 1 ? String(localized: "One was in the list already.")
                                      : String(localized: "\(skipped) were in the list already."))
        }
        let moved = found.filter { $0.nativePort != nil && added.map(\.host).contains($0.endpoint.host) }
        if !moved.isEmpty {
            lines.append(String(localized: "clickhouse-client's native ports became the HTTP interface's (9000 → 8123, 9440 → 8443): change them if the server listens elsewhere."))
        }
        let title = added.isEmpty ? String(localized: "No new connections")
            : added.count == 1 ? String(localized: "Imported a connection") : String(localized: "Imported \(added.count) connections")
        return (title, lines.joined(separator: "\n\n"))
    }

    /// The name a connection gets until one is typed: the host's, or New server.
    func suggestedName(host: String, except id: UUID?) -> String {
        let host = host.trimmingCharacters(in: .whitespaces)
        let base = host.isEmpty || host == "localhost" ? String(localized: "New server")
            : host.hasSuffix(".clickhouse.cloud") ? String(host.prefix { $0 != "." }) : host
        return uniqueName(base, except: id)
    }

    /// The client certificate kept for an endpoint, ready for TLS.
    func clientIdentity(for endpoint: CHEndpoint) -> CHClientIdentity? {
        guard endpoint.clientCertificate != nil, let data = Keychain.data(for: endpoint.id, suffix: ".p12") else { return nil }
        return try? CHClientIdentity(pkcs12: data, password: Keychain.string(for: endpoint.id, suffix: ".p12-password") ?? "")
    }

    /// A PKCS#12 file's certificate kept for an endpoint (its password checked
    /// first); the certificate's name, to show.
    static func storeClientCertificate(_ data: Data, password: String, for id: UUID) throws -> String {
        let identity = try CHClientIdentity(pkcs12: data, password: password)
        Keychain.setData(data, for: id, suffix: ".p12")
        Keychain.setData(Data(password.utf8), for: id, suffix: ".p12-password")
        return identity.summary
    }

    static func removeClientCertificate(for id: UUID) {
        Keychain.removeData(for: id, suffix: ".p12")
        Keychain.removeData(for: id, suffix: ".p12-password")
    }
}

/// Passwords in the Keychain, by connection.
enum Keychain {
    #if DEBUG
    private static let service = "by.digitalglobe.Clickhouse-Viewer.connection" + (Connections.isChecking ? ".checks" : "")
    #else
    private static let service = "by.digitalglobe.Clickhouse-Viewer.connection"
    #endif

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }

    static func password(for id: UUID) -> String? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String, for id: UUID) {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(id)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func removePassword(for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
        removeData(for: id, suffix: ".p12")
        removeData(for: id, suffix: ".p12-password")
        removeData(for: id, suffix: ".ssh")
    }

    // Other secrets of a connection (a client certificate, an SSH key), by a suffix of its account.

    private static func query(_ id: UUID, suffix: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString + suffix]
    }

    static func data(for id: UUID, suffix: String) -> Data? {
        var query = query(id, suffix: suffix)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func string(for id: UUID, suffix: String) -> String? {
        data(for: id, suffix: suffix).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func setData(_ data: Data, for id: UUID, suffix: String) {
        let status = SecItemUpdate(query(id, suffix: suffix) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(id, suffix: suffix)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func removeData(for id: UUID, suffix: String) {
        SecItemDelete(query(id, suffix: suffix) as CFDictionary)
    }
}

/// The statements run on a connection, newest first: the editor's history.
final class QueryHistory {
    static let limit = 300
    private let file: URL
    private(set) var entries: [Entry] = []

    struct Entry: Codable, Hashable {
        var sql: String
        var date: Date
        var rows: Int?
        var seconds: Double?
        /// The server's id of this run, and of the run of the same statement before it:
        /// Query Details compares them (from `system.query_log`).
        var queryID: String?
        var previousQueryID: String?
    }

    init(endpoint: CHEndpoint) {
        file = Self.file(for: endpoint.id)
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Entry].self, from: data) { entries = saved }
    }

    private static func file(for id: UUID) -> URL {
        let folder = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let history = folder.appending(path: "History", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        return history.appending(path: id.uuidString + ".json")
    }

    /// A removed connection's history.
    static func remove(for id: UUID) {
        try? FileManager.default.removeItem(at: file(for: id))
    }

    /// Keeps a statement run; the run of it before (if any) is remembered for comparing.
    @discardableResult
    func add(_ sql: String, rows: Int?, seconds: Double?, queryID: String? = nil) -> Entry? {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let previous = entries.first { $0.sql == trimmed }?.queryID
        entries.removeAll { $0.sql == trimmed }
        let entry = Entry(sql: trimmed, date: Date(), rows: rows, seconds: seconds, queryID: queryID, previousQueryID: previous)
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
        return entry
    }
}

/// Statements kept by name (Query > Save Query…), for every connection: one statement
/// often runs on more than one server (staging, then production). A JSON file in
/// Application Support, its queries in the order of their names.
final class SavedQueries {
    static let shared = SavedQueries()

    struct Query: Codable, Hashable, Identifiable {
        var id = UUID()
        var name: String
        var sql: String
        var date = Date()
    }

    private(set) var queries: [Query] = []
    /// Called when the list changed.
    var onChange: [() -> Void] = []
    private let file: URL

    private init() {
        let folder = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        var name = "Saved Queries.json"
        #if DEBUG
        // `-ViewerSavedQueries <name>`: a file of the check's own, the user's list untouched.
        if let check = UserDefaults.standard.string(forKey: "ViewerSavedQueries") { name = "Saved Queries \(check).json" }
        #endif
        file = folder.appending(path: name)
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Query].self, from: data) { queries = saved }
    }

    func query(named name: String) -> Query? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return queries.first { $0.name.lowercased() == wanted }
    }

    /// Keeps a statement under a name; one of that name already is replaced.
    func save(_ sql: String, as name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let index = queries.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            queries[index].sql = sql
            queries[index].name = name
            queries[index].date = Date()
        } else {
            queries.append(Query(name: name, sql: sql))
        }
        store()
    }

    /// Gives a saved query another name; `false` when another one has that name.
    @discardableResult
    func rename(_ id: UUID, to name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let index = queries.firstIndex(where: { $0.id == id }) else { return false }
        if let other = query(named: name), other.id != id { return false }
        queries[index].name = name
        store()
        return true
    }

    func remove(_ id: UUID) {
        queries.removeAll { $0.id == id }
        store()
    }

    private func store() {
        queries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let data = try? JSONEncoder().encode(queries) { try? data.write(to: file, options: .atomic) }
        onChange.forEach { $0() }
    }

    /// A name for a statement: its first words.
    static func suggestedName(for sql: String) -> String {
        let words = sql.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        return words.count > 50 ? String(words.prefix(50)) + "…" : words
    }

    /// A statement on one line, for lists: its whitespace folded, its first characters.
    static func oneLine(_ sql: String, limit: Int = 200) -> String {
        let folded = sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return folded.count > limit ? String(folded.prefix(limit)) + "…" : folded
    }
}

extension CHEnvironment {
    var title: String {
        switch self {
        case .local: String(localized: "Local")
        case .development: String(localized: "Development")
        case .testing: String(localized: "Testing")
        case .staging: String(localized: "Staging")
        case .production: String(localized: "Production")
        }
    }

    var color: PlatformColor {
        switch self {
        case .local: .systemGray
        case .development: .systemBlue
        case .testing: .systemTeal
        case .staging: .systemOrange
        case .production: .systemRed
        }
    }
}

