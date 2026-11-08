import Foundation

/// The connections of clickhouse-client's configuration (`~/.clickhouse-client/config.xml`
/// or `config.yaml`): its `connections_credentials`, and the server it connects to by
/// default (its top-level `host`), as the viewer's connections. clickhouse-client speaks the
/// native protocol: its ports (9000, 9440) become the HTTP interface's (8123, 8443), and
/// ClickHouse Cloud's hosts are reached over HTTPS.
public enum CHClientConfig {
    public struct Connection: Sendable, Equatable {
        public var endpoint: CHEndpoint
        public var password: String?
        /// The native protocol's port it named, if it was changed for HTTP's.
        public var nativePort: Int?
    }

    /// The connections of a configuration file's contents (XML, or YAML when it isn't XML).
    public static func connections(in data: Data) -> [Connection] {
        let text = String(decoding: data, as: UTF8.self)
        let entries = text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") ? XMLEntries.read(data) : yamlEntries(text)
        return entries.compactMap(connection(from:))
    }

    /// A connection's fields as the file names them (`name`, `hostname`, `port`, …).
    typealias Entry = [String: String]

    static func connection(from entry: Entry) -> Connection? {
        guard let host = (entry["hostname"] ?? entry["host"] ?? entry["name"]).map({ $0.trimmingCharacters(in: .whitespaces) }),
              !host.isEmpty else { return nil }
        let isCloud = host.hasSuffix(".clickhouse.cloud")
        let named = entry["port"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        var isSecure = isCloud || ["1", "true", "yes"].contains(entry["secure"]?.lowercased() ?? "") || named == 9440
        let port: Int
        switch named {
        case 8123?, 8443?: port = named!
            isSecure = isSecure || named == 8443
        case nil, 9000?, 9440?: port = isSecure ? 8443 : 8123
        case let other?: port = other
        }
        var endpoint = CHEndpoint(name: entry["name"] ?? "", host: host, port: port, isSecure: isSecure,
                                  user: entry["user"].flatMap { $0.isEmpty ? nil : $0 } ?? "default", database: entry["database"] ?? "")
        if endpoint.name.isEmpty || endpoint.name == host { endpoint.name = "" }
        let nativePort = named.flatMap { $0 == port ? nil : $0 }
        return Connection(endpoint: endpoint, password: entry["password"], nativePort: nativePort)
    }

    // MARK: XML

    /// `<connections_credentials><connection>…</connection></connections_credentials>` and the
    /// root's own `host`, `port`, `user`, `password`, `secure`, `database`.
    final class XMLEntries: NSObject, XMLParserDelegate {
        private var path: [String] = []
        private var text = ""
        private var current: Entry?
        private var root: Entry = [:]
        private var entries: [Entry] = []
        private static let fields: Set<String> = ["name", "hostname", "host", "port", "secure", "user", "password", "database"]

        static func read(_ data: Data) -> [Entry] {
            let reader = XMLEntries()
            let parser = XMLParser(data: data)
            parser.delegate = reader
            guard parser.parse() || !reader.entries.isEmpty else { return [] }
            return (reader.root["host"] != nil ? [reader.root] : []) + reader.entries
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            path.append(name)
            text = ""
            if name == "connection", path.dropLast().last == "connections_credentials" { current = [:] }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { path.removeLast() }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            if name == "connection", current != nil, path.dropLast().last == "connections_credentials" {
                entries.append(current!)
                current = nil
            } else if current != nil, path.count >= 2, path[path.count - 2] == "connection", Self.fields.contains(name) {
                current?[name] = value
            } else if path.count == 2, Self.fields.contains(name), name != "name", name != "hostname" {
                root[name] = value
            }
        }
    }

    // MARK: YAML

    /// The same from YAML: a line a field, nested by indentation, `connection` a list
    /// (`- name: …`) or a single mapping. Only what clickhouse-client's files hold.
    static func yamlEntries(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var root: Entry = [:]
        var current: Entry?
        var credentialsIndent: Int?
        var itemIndent: Int?
        func unquoted(_ value: Substring) -> String {
            let value = value.trimmingCharacters(in: .whitespaces)
            // A quoted value ends at its closing quote: a " #" inside is the value's ('abc #123').
            if let quote = value.first, quote == "'" || quote == "\"",
               let close = value.dropFirst().firstIndex(of: quote) {
                return String(value[value.index(after: value.startIndex)..<close])
            }
            if let comment = value.range(of: " #") { return value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces) }
            return value
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            let content = line.drop { $0 == " " }
            guard !content.isEmpty, !content.hasPrefix("#") else { continue }
            let indent = line.count - content.count
            var body = content
            var startsItem = false
            if body.hasPrefix("- ") {
                startsItem = true
                body = body.dropFirst(2).drop { $0 == " " }
            }
            guard let colon = body.firstIndex(of: ":") else { continue }
            let key = body[..<colon].trimmingCharacters(in: .whitespaces)
            let value = unquoted(body[body.index(after: colon)...])
            if let credentials = credentialsIndent {
                if indent <= credentials, !startsItem {
                    // Out of the section.
                    if let entry = current { entries.append(entry) }
                    current = nil
                    credentialsIndent = nil
                    itemIndent = nil
                } else {
                    if key == "connection", !startsItem, value.isEmpty { continue }
                    if startsItem || current == nil || (itemIndent.map { indent < $0 } ?? false) {
                        if let entry = current { entries.append(entry) }
                        current = [:]
                        itemIndent = indent + (startsItem ? 2 : 0)
                    }
                    current?[key] = value
                    continue
                }
            }
            if key == "connections_credentials", value.isEmpty {
                credentialsIndent = indent
            } else if indent == 0 {
                root[key] = value
            }
        }
        if let entry = current { entries.append(entry) }
        root["name"] = nil
        return (root["host"] != nil ? [root.filter { ["host", "port", "user", "password", "secure", "database"].contains($0.key) }] : []) + entries
    }
}
