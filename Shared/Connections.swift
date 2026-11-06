import ClickHouseCore
import Foundation
import Security

/// The servers the user added: kept in the app's defaults, their passwords
/// in the Keychain.
final class Connections {
    static let shared = Connections()

    private static let key = "Connections"
    private(set) var endpoints: [CHEndpoint] = []
    /// Called when the list changed.
    var onChange: [() -> Void] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([CHEndpoint].self, from: data) {
            endpoints = saved
        }
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
        Keychain.removePassword(for: endpoint.id)
        save()
    }

    func move(from source: Int, to destination: Int) {
        guard endpoints.indices.contains(source) else { return }
        let endpoint = endpoints.remove(at: source)
        endpoints.insert(endpoint, at: min(destination, endpoints.count))
        save()
    }

    func password(for endpoint: CHEndpoint) -> String { Keychain.password(for: endpoint.id) ?? "" }

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
    private static let service = "by.digitalglobe.Clickhouse-Viewer.connection"

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
    }

    init(endpoint: CHEndpoint) {
        let folder = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let history = folder.appending(path: "History", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        file = history.appending(path: endpoint.id.uuidString + ".json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Entry].self, from: data) { entries = saved }
    }

    func add(_ sql: String, rows: Int?, seconds: Double?) {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.removeAll { $0.sql == trimmed }
        entries.insert(Entry(sql: trimmed, date: Date(), rows: rows, seconds: seconds), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
    }
}
