import Crypto
import Foundation
import NIOSSH

/// A private key from its text as OpenSSH writes it (`-----BEGIN OPENSSH
/// PRIVATE KEY-----`: ed25519 and ECDSA P-256/384/521, without a passphrase),
/// or an ECDSA key in PEM (`BEGIN EC PRIVATE KEY`, `BEGIN PRIVATE KEY`).
public enum CHSSHKey {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// RSA and DSA keys: the SSH library signs with ed25519 and ECDSA only.
        case unsupportedType(String)
        /// A key with a passphrase (not read yet).
        case encrypted
        case unreadable

        public var description: String {
            switch self {
            case .unsupportedType(let type):
                String(localized: "\(type) keys aren't supported: use an ed25519 or ECDSA key (ssh-keygen -t ed25519).")
            case .encrypted:
                String(localized: "Keys with a passphrase aren't supported yet: use a key without one, or a password.")
            case .unreadable:
                String(localized: "The key can't be read: it should be an OpenSSH private key.")
            }
        }
    }

    public static func parse(_ text: String) throws -> NIOSSHPrivateKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("BEGIN RSA PRIVATE KEY") { throw Failure.unsupportedType("RSA") }
        if trimmed.contains("BEGIN DSA PRIVATE KEY") { throw Failure.unsupportedType("DSA") }
        if trimmed.contains("BEGIN ENCRYPTED PRIVATE KEY") || trimmed.contains("Proc-Type: 4,ENCRYPTED") { throw Failure.encrypted }
        if trimmed.contains("BEGIN EC PRIVATE KEY") || trimmed.contains("BEGIN PRIVATE KEY") {
            if let key = try? P256.Signing.PrivateKey(pemRepresentation: trimmed) { return NIOSSHPrivateKey(p256Key: key) }
            if let key = try? P384.Signing.PrivateKey(pemRepresentation: trimmed) { return NIOSSHPrivateKey(p384Key: key) }
            if let key = try? P521.Signing.PrivateKey(pemRepresentation: trimmed) { return NIOSSHPrivateKey(p521Key: key) }
            throw Failure.unreadable
        }
        guard trimmed.contains("BEGIN OPENSSH PRIVATE KEY") else { throw Failure.unreadable }
        let body = trimmed.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: body) else { throw Failure.unreadable }
        return try openSSH(data)
    }

    /// "openssh-key-v1": the cipher, KDF, the keys' public blobs, then the private section.
    private static func openSSH(_ data: Data) throws -> NIOSSHPrivateKey {
        var reader = Reader(data)
        let magic = Array("openssh-key-v1".utf8) + [0]
        guard reader.take(magic.count) == magic else { throw Failure.unreadable }
        let cipher = try reader.string(), _ = try reader.string(), _ = try reader.bytes()
        guard cipher == "none" else { throw Failure.encrypted }
        guard try reader.uint32() == 1 else { throw Failure.unreadable }
        _ = try reader.bytes()
        var section = Reader(Data(try reader.bytes()))
        guard try section.uint32() == (try section.uint32()) else { throw Failure.unreadable }
        let type = try section.string()
        switch type {
        case "ssh-ed25519":
            _ = try section.bytes()
            let secret = try section.bytes()
            guard secret.count == 64 else { throw Failure.unreadable }
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32)))
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            _ = try section.string()
            _ = try section.bytes()
            // The scalar, an mpint: a leading zero byte keeps it positive.
            var scalar = try section.bytes()
            while scalar.first == 0, scalar.count > 1 { scalar.removeFirst() }
            func padded(_ length: Int) -> [UInt8] { [UInt8](repeating: 0, count: max(0, length - scalar.count)) + scalar }
            switch type {
            case "ecdsa-sha2-nistp256": return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: padded(32)))
            case "ecdsa-sha2-nistp384": return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: padded(48)))
            default: return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: padded(66)))
            }
        case "ssh-rsa": throw Failure.unsupportedType("RSA")
        case "ssh-dss": throw Failure.unsupportedType("DSA")
        default: throw Failure.unsupportedType(type)
        }
    }

    /// SSH's wire forms: uint32 big-endian, strings and blobs with their length first.
    private struct Reader {
        private let data: [UInt8]
        private var at = 0

        init(_ data: Data) { self.data = Array(data) }

        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, at + count <= data.count else { return nil }
            defer { at += count }
            return Array(data[at..<(at + count)])
        }

        mutating func uint32() throws -> UInt32 {
            guard let bytes = take(4) else { throw Failure.unreadable }
            return bytes.reduce(0) { $0 << 8 | UInt32($1) }
        }

        mutating func bytes() throws -> [UInt8] {
            let count = Int(try uint32())
            guard let bytes = take(count) else { throw Failure.unreadable }
            return bytes
        }

        mutating func string() throws -> String {
            String(decoding: try bytes(), as: UTF8.self)
        }
    }
}
