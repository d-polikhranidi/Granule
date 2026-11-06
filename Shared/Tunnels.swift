import ClickHouseCore
import ClickHouseSSH
import Foundation

/// Servers behind an SSH bastion: the tunnel opened before connecting, the
/// bastion's password or private key in the Keychain.
extension Connections {
    /// The bastion's password, or its private key's text.
    func sshSecret(for endpoint: CHEndpoint) -> String {
        #if DEBUG
        if let secret = Self.debugSSHSecrets[endpoint.id] { return secret }
        #endif
        return Keychain.string(for: endpoint.id, suffix: ".ssh") ?? ""
    }

    #if DEBUG
    /// The secrets of bastions given at launch (`-ViewerSSH`), not kept.
    static var debugSSHSecrets: [UUID: String] = [:]

    /// `-ViewerSSH ssh://user:password@host:port`: the `-ViewerURL` server reached
    /// through that bastion (its host is then as the bastion sees it).
    static func debugBastion(for endpoint: inout CHEndpoint) {
        guard let text = UserDefaults.standard.string(forKey: "ViewerSSH"), let url = URLComponents(string: text), let host = url.host else { return }
        endpoint.ssh = CHSSHBastion(host: host, port: url.port ?? 22, user: url.user ?? NSUserName())
        debugSSHSecrets[endpoint.id] = url.password ?? ""
    }
    #endif

    static func setSSHSecret(_ secret: String, for id: UUID) {
        if secret.isEmpty {
            Keychain.removeData(for: id, suffix: ".ssh")
        } else {
            Keychain.setData(Data(secret.utf8), for: id, suffix: ".ssh")
        }
    }

    /// Reaches the endpoint's server through its bastion, when it has one: the
    /// tunnel opened, and the client routed through it while it lives. The
    /// bastion's host key is kept in the saved connection the first time; it's
    /// returned (`nil` without a bastion). `secret`: the form's, not yet saved.
    @discardableResult
    func route(_ client: CHClient, for endpoint: CHEndpoint, secret: String? = nil) async throws -> String? {
        guard let bastion = endpoint.ssh else { return nil }
        let secret = secret ?? sshSecret(for: endpoint)
        // A window's copy may be older than the key kept since (a tab opened later).
        let known = bastion.knownHostKey ?? endpoints.first(where: { $0.id == endpoint.id })?.ssh?.knownHostKey
        let settings = CHSSHTunnel.Settings(host: bastion.host, port: bastion.port, user: bastion.user,
                                            password: bastion.keyName == nil ? secret : nil,
                                            privateKey: bastion.keyName == nil ? nil : secret,
                                            knownHostKey: known)
        let tunnel = try await CHSSHTunnel.open(settings, target: endpoint.host, targetPort: endpoint.port)
        client.route(throughLocalPort: tunnel.localPort, keeping: tunnel)
        if known == nil, var saved = endpoints.first(where: { $0.id == endpoint.id }), saved.ssh != nil {
            saved.ssh?.knownHostKey = tunnel.hostKey
            save(saved, password: nil)
        }
        return tunnel.hostKey
    }
}
