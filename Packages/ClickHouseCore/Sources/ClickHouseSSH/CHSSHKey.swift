import CHBcrypt
import CommonCrypto
import Crypto
import Foundation
import NIOSSH

/// A private key from its text as OpenSSH writes it (`-----BEGIN OPENSSH
/// PRIVATE KEY-----`: ed25519 and ECDSA P-256/384/521), or an ECDSA key in PEM
/// (`BEGIN EC PRIVATE KEY`, `BEGIN PRIVATE KEY`). A key with a passphrase is
/// unlocked once (`unlocked(_:passphrase:)`) and kept so, as `ssh-add
/// --apple-use-keychain` keeps its passphrase in the Keychain.
public enum CHSSHKey {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// RSA and DSA keys: the SSH library signs with ed25519 and ECDSA only.
        case unsupportedType(String)
        /// A key with a passphrase: `unlocked(_:passphrase:)` first.
        case needsPassphrase
        case wrongPassphrase
        /// A passphrase's encryption not read: PEM's (`Proc-Type: 4,ENCRYPTED`, PKCS#8), or another cipher.
        case unsupportedEncryption(String)
        case unreadable

        public var description: String {
            switch self {
            case .unsupportedType(let type):
                String(localized: "\(type) keys aren't supported: use an ed25519 or ECDSA key (ssh-keygen -t ed25519).", bundle: .module)
            case .needsPassphrase:
                String(localized: "This key has a passphrase.", bundle: .module)
            case .wrongPassphrase:
                String(localized: "That isn't this key's passphrase.", bundle: .module)
            case .unsupportedEncryption(let kind):
                String(localized: "Keys encrypted as \(kind) can't be read: ssh-keygen -p -f <key> writes the key again in OpenSSH's own format.", bundle: .module)
            case .unreadable:
                String(localized: "The key can't be read: it should be an OpenSSH private key.", bundle: .module)
            }
        }
    }

    /// Whether the key needs its passphrase (`parse` throws `needsPassphrase` for it).
    public static func needsPassphrase(_ text: String) -> Bool {
        guard let data = openSSHData(text), var reader = Optional(Reader(data)),
              reader.take(magic.count) == magic, let cipher = try? reader.string() else { return false }
        return cipher != "none"
    }

    /// The key without its passphrase, in OpenSSH's format (kept as such): the bcrypt KDF's
    /// key and IV (`ch_bcrypt_pbkdf`), the private section decrypted (AES-CTR, AES-CBC or
    /// AES-GCM, as ssh-keygen writes them) and checked.
    public static func unlocked(_ text: String, passphrase: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("Proc-Type: 4,ENCRYPTED") { throw Failure.unsupportedEncryption("PEM") }
        if trimmed.contains("BEGIN ENCRYPTED PRIVATE KEY") { throw Failure.unsupportedEncryption("PKCS#8") }
        guard let data = openSSHData(trimmed) else { throw Failure.unreadable }
        var reader = Reader(data)
        guard reader.take(magic.count) == magic else { throw Failure.unreadable }
        let cipher = try reader.string(), kdf = try reader.string(), options = try reader.bytes()
        guard cipher != "none" else { return trimmed }
        guard try reader.uint32() == 1 else { throw Failure.unreadable }
        let publicBlob = try reader.bytes(), sealed = try reader.bytes()
        let (keyLength, ivLength): (Int, Int) = switch cipher {
        case "aes256-ctr", "aes256-cbc": (32, 16)
        case "aes192-ctr", "aes192-cbc": (24, 16)
        case "aes128-ctr", "aes128-cbc": (16, 16)
        case "aes256-gcm@openssh.com": (32, 12)
        case "aes128-gcm@openssh.com": (16, 12)
        default: throw Failure.unsupportedEncryption(cipher)
        }
        guard kdf == "bcrypt" else { throw Failure.unsupportedEncryption(kdf) }
        var kdfReader = Reader(Data(options))
        let salt = try kdfReader.bytes(), rounds = try kdfReader.uint32()
        guard !passphrase.isEmpty else { throw Failure.wrongPassphrase }
        var derived = [UInt8](repeating: 0, count: keyLength + ivLength)
        let passBytes = Array(passphrase.utf8)
        let status = passBytes.withUnsafeBufferPointer { pass in
            salt.withUnsafeBufferPointer { salt in
                ch_bcrypt_pbkdf(UnsafeRawPointer(pass.baseAddress!).assumingMemoryBound(to: CChar.self), pass.count,
                                salt.baseAddress, salt.count, &derived, derived.count, rounds)
            }
        }
        guard status == 0 else { throw Failure.unreadable }
        defer { derived.withUnsafeMutableBytes { _ = memset($0.baseAddress!, 0, $0.count) } }
        let key = Array(derived.prefix(keyLength)), iv = Array(derived.suffix(ivLength))
        var section: [UInt8]
        if cipher.hasSuffix("gcm@openssh.com") {
            // The tag follows the sealed section.
            guard let tag = reader.take(16) else { throw Failure.unreadable }
            do {
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: sealed, tag: tag)
                section = Array(try AES.GCM.open(box, using: SymmetricKey(data: key)))
            } catch {
                throw Failure.wrongPassphrase
            }
        } else {
            section = try crypt(sealed, key: key, iv: iv, mode: cipher.hasSuffix("ctr") ? CCMode(kCCModeCTR) : CCMode(kCCModeCBC))
        }
        // Two equal random numbers open the section: a wrong passphrase gives two others.
        var check = Reader(Data(section))
        guard try check.uint32() == (try check.uint32()) else { throw Failure.wrongPassphrase }
        var plain = Data(magic)
        func append(_ bytes: [UInt8]) {
            plain.append(contentsOf: withUnsafeBytes(of: UInt32(bytes.count).bigEndian, Array.init))
            plain.append(contentsOf: bytes)
        }
        append(Array("none".utf8))
        append(Array("none".utf8))
        append([])
        plain.append(contentsOf: [0, 0, 0, 1])
        append(publicBlob)
        append(section)
        section.withUnsafeMutableBytes { _ = memset($0.baseAddress!, 0, $0.count) }
        let lines = plain.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n" + lines + "\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    private static let magic = Array("openssh-key-v1".utf8) + [0]

    private static func openSSHData(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("BEGIN OPENSSH PRIVATE KEY") else { return nil }
        let body = trimmed.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body)
    }

    /// AES in CTR or CBC (no padding: the section is a whole number of blocks).
    private static func crypt(_ input: [UInt8], key: [UInt8], iv: [UInt8], mode: CCMode) throws -> [UInt8] {
        var cryptor: CCCryptorRef?
        let created = CCCryptorCreateWithMode(CCOperation(kCCDecrypt), mode, CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                              iv, key, key.count, nil, 0, 0,
                                              mode == CCMode(kCCModeCTR) ? CCModeOptions(kCCModeOptionCTR_BE) : 0, &cryptor)
        guard created == kCCSuccess, let cryptor else { throw Failure.unreadable }
        defer { CCCryptorRelease(cryptor) }
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        guard CCCryptorUpdate(cryptor, input, input.count, &output, output.count, &moved) == kCCSuccess, moved == input.count else {
            throw Failure.unreadable
        }
        return output
    }

    public static func parse(_ text: String) throws -> NIOSSHPrivateKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("BEGIN RSA PRIVATE KEY") { throw Failure.unsupportedType("RSA") }
        if trimmed.contains("BEGIN DSA PRIVATE KEY") { throw Failure.unsupportedType("DSA") }
        if trimmed.contains("Proc-Type: 4,ENCRYPTED") { throw Failure.unsupportedEncryption("PEM") }
        if trimmed.contains("BEGIN ENCRYPTED PRIVATE KEY") { throw Failure.unsupportedEncryption("PKCS#8") }
        if trimmed.contains("BEGIN EC PRIVATE KEY") || trimmed.contains("BEGIN PRIVATE KEY") {
            if let key = try? P256.Signing.PrivateKey(pemRepresentation: trimmed) { return NIOSSHPrivateKey(p256Key: key) }
            if let key = try? P384.Signing.PrivateKey(pemRepresentation: trimmed) { return NIOSSHPrivateKey(p384Key: key) }
            if let key = try? P521.Signing.PrivateKey(pemRepresentation: trimmed) { return NIOSSHPrivateKey(p521Key: key) }
            throw Failure.unreadable
        }
        guard let data = openSSHData(trimmed) else { throw Failure.unreadable }
        return try openSSH(data)
    }

    /// "openssh-key-v1": the cipher, KDF, the keys' public blobs, then the private section.
    private static func openSSH(_ data: Data) throws -> NIOSSHPrivateKey {
        var reader = Reader(data)
        guard reader.take(magic.count) == magic else { throw Failure.unreadable }
        let cipher = try reader.string(), _ = try reader.string(), _ = try reader.bytes()
        guard cipher == "none" else { throw Failure.needsPassphrase }
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
