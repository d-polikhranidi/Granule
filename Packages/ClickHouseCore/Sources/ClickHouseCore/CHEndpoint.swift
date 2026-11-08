import CryptoKit
import Foundation
import Security

/// Where a ClickHouse server is and how to reach it: its HTTP(S) interface,
/// the user, the default database, how its certificate is trusted. The
/// password isn't here: it's in the Keychain (`CHKeychain`).
public struct CHEndpoint: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// The name the user gave it.
    public var name: String
    public var host: String
    public var port: Int
    /// HTTPS (8443) rather than HTTP (8123).
    public var isSecure: Bool
    public var user: String
    public var database: String
    /// Queries that change nothing only (`readonly`), whatever the user may do.
    public var isReadOnly: Bool
    public var trust: CHTrust
    /// How results are compressed on their way.
    public var compression: CHCompression = .automatic
    /// The client certificate's name, when the server asks for one (the
    /// certificate itself is in the Keychain).
    public var clientCertificate: String?
    /// The SSH server the server is reached through, when it's behind one.
    public var ssh: CHSSHBastion?
    /// What the server is for, shown by its color (production in red), or none.
    public var environment: CHEnvironment?
    /// The name was made for it (New server, the host's), not typed: the form
    /// shows it as the field's prompt, so typing starts a name of one's own.
    public var nameIsSuggested: Bool?

    public init(id: UUID = UUID(), name: String = "", host: String = "localhost", port: Int = 8123, isSecure: Bool = false,
                user: String = "default", database: String = "", isReadOnly: Bool = false, trust: CHTrust = .system,
                compression: CHCompression = .automatic) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.isSecure = isSecure
        self.user = user
        self.database = database
        self.isReadOnly = isReadOnly
        self.trust = trust
        self.compression = compression
    }

    /// The name shown: its own, or the user and host.
    public var title: String { name.isEmpty ? "\(user)@\(host)" : name }

    /// Whether it's a ClickHouse Cloud service (its services sleep when idle
    /// and wake on the first request, which takes a while).
    public var isCloud: Bool { host.hasSuffix(".clickhouse.cloud") }

    /// Whether results come compressed (ClickHouse's frames, LZ4 or ZSTD): not on
    /// this Mac or a local network, where compressing them costs the server
    /// more time than sending them (50M rows over loopback: 1.7 s plain, 3.5 s
    /// in LZ4), and where frames would hold rows back (the server sends a
    /// frame once it has 1 MB).
    public var compressesResults: Bool {
        switch compression {
        case .lz4, .zstd: return true
        case .none: return false
        // Through a bastion, the way is the bastion's (the server's own name is as it sees it).
        case .automatic: return !Self.isLocal(ssh?.host ?? host)
        }
    }

    /// A loopback or private address, or a name on the local network.
    static func isLocal(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name == "localhost" || name.hasSuffix(".local") || name.hasSuffix(".localhost") || name == "::1" { return true }
        if name.hasPrefix("fe80:") || name.hasPrefix("fd") || name.hasPrefix("fc") { return name.contains(":") }
        let parts = name.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    /// The server's HTTP interface (through a bastion: as the bastion reaches it).
    public var url: URL? {
        var components = URLComponents()
        components.scheme = isSecure ? "https" : "http"
        components.host = host
        components.port = port
        components.path = "/"
        return components.url
    }

    /// An endpoint from a URL the user pasted: `https://user:password@host:8443/database`,
    /// `clickhouse://…` (`?secure=true`), or a bare host; the password, if it has one.
    public static func parse(_ text: String) -> (endpoint: CHEndpoint, password: String?)? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else { return nil }
        let items = components.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name.lowercased() == name }?.value }
        var endpoint = CHEndpoint(host: host)
        switch components.scheme?.lowercased() {
        case "https": endpoint.isSecure = true
        case "clickhouse", "ch", "clickhouses":
            endpoint.isSecure = components.scheme?.lowercased() == "clickhouses" || ["true", "1"].contains(item("secure")?.lowercased() ?? "")
        default: break
        }
        // A Cloud service is always over TLS.
        if host.hasSuffix(".clickhouse.cloud") { endpoint.isSecure = true }
        // The native protocol's ports (9000, 9440) mean the server: its HTTP ports.
        switch components.port {
        case nil: endpoint.port = endpoint.isSecure ? 8443 : 8123
        case 9000: endpoint.port = 8123
        case 9440: endpoint.port = 8443
        case let port?: endpoint.port = port
        }
        if let user = components.user, !user.isEmpty { endpoint.user = user.removingPercentEncoding ?? user }
        if let user = item("user") { endpoint.user = user }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        endpoint.database = item("database") ?? path
        let password = components.password?.removingPercentEncoding ?? item("password")
        components.password = nil
        return (endpoint, password)
    }
}

/// A client certificate and its key, for servers that ask for one (mTLS):
/// from a PKCS#12 file (.p12, .pfx) and its password.
public struct CHClientIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    public let certificates: [SecCertificate]

    public enum Failure: Error, Equatable {
        case wrongPassword
        case unreadable(OSStatus)
    }

    public init(pkcs12 data: Data, password: String) throws {
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        guard status == errSecSuccess else { throw status == errSecAuthFailed ? Failure.wrongPassword : Failure.unreadable(status) }
        guard let first = (items as? [[String: Any]])?.first, let identity = first[kSecImportItemIdentity as String] else {
            throw Failure.unreadable(errSecItemNotFound)
        }
        self.identity = identity as! SecIdentity
        // The chain after the client's own certificate (the server may need the intermediates).
        let chain = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        certificates = Array(chain.dropFirst())
    }

    /// The certificate's subject, to show which one it is.
    public var summary: String {
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        return certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? ""
    }
}

/// Answers a server's TLS challenges: its certificate by the endpoint's
/// trust (for the given host name: the real one when the connection goes
/// through a tunnel), and a request for a client certificate with ours.
enum CHAuthentication {
    static func answer(_ challenge: URLAuthenticationChallenge, trust: CHTrust, identity: CHClientIdentity?, hostname: String?)
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let serverTrust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
            if let hostname { SecTrustSetPolicies(serverTrust, SecPolicyCreateSSL(true, hostname as CFString)) }
            if case .system = trust, hostname == nil { return (.performDefaultHandling, nil) }
            return trust.evaluate(serverTrust) ? (.useCredential, URLCredential(trust: serverTrust)) : (.cancelAuthenticationChallenge, nil)
        case NSURLAuthenticationMethodClientCertificate:
            guard let identity else { return (.performDefaultHandling, nil) }
            return (.useCredential, URLCredential(identity: identity.identity, certificates: identity.certificates, persistence: .forSession))
        default:
            return (.performDefaultHandling, nil)
        }
    }
}

/// How results are compressed on their way from the server.
public enum CHCompression: String, Codable, Sendable, Hashable, CaseIterable {
    /// Not on this Mac or a local network, ZSTD otherwise: a third of LZ4's bytes is worth
    /// its time on any link slower than some 5 Gbit/s (LZ4 from servers before 26.9).
    case automatic
    /// ClickHouse's LZ4 frames (`compress=1`).
    case lz4
    /// ZSTD frames: about a third of LZ4's bytes, a little slower to make and to read (5M
    /// rows on 26.10: 26 MB in 0.43 s, LZ4 81 MB in 0.34 s, over loopback). Servers before
    /// 26.9 send LZ4 over HTTP whatever is asked.
    case zstd
    case none
}

/// What a connection's server is for: its color in the list and on its
/// window, so a production server isn't taken for a test one.
public enum CHEnvironment: String, Codable, Sendable, Hashable, CaseIterable {
    case local, development, testing, staging, production
}

/// An SSH server ("bastion", "jump host") a ClickHouse server is reached
/// through: its own address is the one the bastion reaches. The password or
/// the private key is in the Keychain.
public struct CHSSHBastion: Codable, Sendable, Hashable {
    public var host: String
    public var port: Int
    public var user: String
    /// The private key's file name when signing in with a key (`nil`: a password).
    public var keyName: String?
    /// The bastion's host key, kept the first time it's reached (`ssh-ed25519 AAAA…`).
    public var knownHostKey: String?

    public init(host: String, port: Int = 22, user: String, keyName: String? = nil, knownHostKey: String? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.keyName = keyName
        self.knownHostKey = knownHostKey
    }
}

/// How a server's certificate is trusted over HTTPS.
public enum CHTrust: Codable, Sendable, Hashable {
    /// The system's trusted authorities.
    case system
    /// Only this certificate (its SHA-256, hex): a self-signed one.
    case pinned(String)
    /// Certificates issued by this authority (its DER bytes), and the system's.
    case authority(Data)

    /// Whether a server's trust is accepted, and the credential to answer with.
    func evaluate(_ serverTrust: SecTrust) -> Bool {
        switch self {
        case .system:
            return SecTrustEvaluateWithError(serverTrust, nil)
        case .pinned(let fingerprint):
            guard let leaf = (SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate])?.first else { return false }
            return Self.fingerprint(of: leaf) == fingerprint.lowercased().filter(\.isHexDigit)
        case .authority(let der):
            guard let authority = SecCertificateCreateWithData(nil, der as CFData) else { return false }
            SecTrustSetAnchorCertificates(serverTrust, [authority] as CFArray)
            SecTrustSetAnchorCertificatesOnly(serverTrust, false)
            return SecTrustEvaluateWithError(serverTrust, nil)
        }
    }

    /// A certificate's SHA-256, lowercase hex.
    public static func fingerprint(of certificate: SecCertificate) -> String {
        let data = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A server's version, to know the settings it takes.
public struct CHVersion: Sendable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var text: String

    public init(_ text: String) {
        self.text = text
        let parts = text.split(separator: ".").compactMap { Int($0) }
        major = parts.first ?? 0
        minor = parts.count > 1 ? parts[1] : 0
    }

    /// At least `major.minor`.
    public func isAtLeast(_ major: Int, _ minor: Int) -> Bool { (self.major, self.minor) >= (major, minor) }

    public static func < (lhs: CHVersion, rhs: CHVersion) -> Bool { (lhs.major, lhs.minor) < (rhs.major, rhs.minor) }
    public static func == (lhs: CHVersion, rhs: CHVersion) -> Bool { (lhs.major, lhs.minor) == (rhs.major, rhs.minor) }

    public var description: String { text }
}

/// What the viewer learns of a server when it connects.
public struct CHServerInfo: Sendable {
    public var version: CHVersion
    /// The server's (or session's) time zone: times without one in their type are shown in it.
    public var timeZone: String
    public var user: String
    /// The user's `readonly` (1: no settings can be changed in a request either).
    public var readonly: Int
    /// The name the server gives itself (its host name, or the Cloud's).
    public var displayName: String

    public var zone: TimeZone { TimeZone(identifier: timeZone) ?? TimeZone(identifier: "UTC")! }
}

/// An error the server sent: its code, name and message.
public struct CHServerError: Error, Sendable, Equatable, CustomStringConvertible {
    public var code: Int
    /// The code's name (`UNKNOWN_TABLE`), if the text has it.
    public var name: String?
    /// The message without the `Code: …. DB::Exception:` before it and the version after it.
    public var message: String
    /// The text as the server sent it.
    public var text: String

    public init(text: String) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = self.text
        var code = 0
        if message.hasPrefix("Code: "), let dot = message.firstIndex(of: ".") {
            code = Int(message[message.index(message.startIndex, offsetBy: 6)..<dot]) ?? 0
            message = String(message[message.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        for prefix in ["DB::Exception: ", "DB::ErrnoException: ", "DB::NetException: "] where message.hasPrefix(prefix) {
            message = String(message.dropFirst(prefix.count))
        }
        // "… (UNKNOWN_TABLE) (version 26.6.1.1193 (official build))"
        if let version = message.range(of: " (version ", options: .backwards) { message = String(message[..<version.lowerBound]) }
        var name: String?
        if message.hasSuffix(")"), let open = message.range(of: " (", options: .backwards) {
            let candidate = message[open.upperBound..<message.index(before: message.endIndex)]
            if !candidate.isEmpty, candidate.allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber }) {
                name = String(candidate)
                message = String(message[..<open.lowerBound])
            }
        }
        self.code = code
        self.name = name
        self.message = message
    }

    public var description: String { name.map { "\(message) (\($0))" } ?? message }
}
