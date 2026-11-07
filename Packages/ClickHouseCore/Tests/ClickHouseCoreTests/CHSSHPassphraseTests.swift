#if os(macOS)
import Foundation
import NIOSSH
import Testing
@testable import ClickHouseSSH

/// Keys with a passphrase as ssh-keygen writes them, made by it for each run (none are
/// kept in the repository): unlocked, they give the public keys `ssh-keygen -y` gives.
/// Three, for three ways of encrypting: ssh-keygen's default (aes256-ctr), AES-GCM (its
/// tag after the sealed section) and AES-CBC; ed25519 and ECDSA (their private sections differ).
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen"), "no ssh-keygen"))
struct CHSSHPassphraseTests {
    static let keygen = "/usr/bin/ssh-keygen"
    static let passphrase = "granule test"

    /// A key made now (`ssh-keygen -t … -Z …`) and its public key, in a folder of its own.
    static func makeKey(type: [String], cipher: String?) throws -> (text: String, publicKey: String) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "granule-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "key").path
        try run(["-q"] + type + (cipher.map { ["-Z", $0] } ?? []) + ["-N", passphrase, "-C", "", "-f", file])
        let publicKey = try run(["-y", "-P", passphrase, "-f", file]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (try String(contentsOfFile: file, encoding: .utf8), publicKey)
    }

    @discardableResult
    static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: keygen)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        return String(decoding: data, as: UTF8.self)
    }

    @Test(arguments: [
        (["-t", "ed25519"], nil as String?),
        (["-t", "ecdsa", "-b", "256"], "aes256-gcm@openssh.com"),
        (["-t", "ed25519"], "aes256-cbc"),
    ])
    func keysWithAPassphraseAreUnlocked(type: [String], cipher: String?) throws {
        let (text, publicKey) = try Self.makeKey(type: type, cipher: cipher)
        #expect(CHSSHKey.needsPassphrase(text))
        #expect(throws: CHSSHKey.Failure.needsPassphrase) { try CHSSHKey.parse(text) }
        #expect(throws: CHSSHKey.Failure.wrongPassphrase) { try CHSSHKey.unlocked(text, passphrase: "not it") }
        let unlocked = try CHSSHKey.unlocked(text, passphrase: Self.passphrase)
        #expect(!CHSSHKey.needsPassphrase(unlocked))
        let key = try CHSSHKey.parse(unlocked)
        #expect(String(openSSHPublicKey: key.publicKey) == publicKey)
        // A key without one comes back as it is.
        #expect(try CHSSHKey.unlocked(unlocked, passphrase: "anything") == unlocked.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test func pemWithAPassphraseIsSaid() {
        let pem = "-----BEGIN EC PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,00\n\nAAAA\n-----END EC PRIVATE KEY-----"
        #expect(throws: CHSSHKey.Failure.unsupportedEncryption("PEM")) { try CHSSHKey.parse(pem) }
    }
}
#endif
