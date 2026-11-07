import ClickHouseCore
import ClickHouseSSH
import UIKit
import UniformTypeIdentifiers

/// A connection's form: a URL pasted fills it in; Save keeps it (the
/// password in the Keychain), Test connects once.
final class ConnectionFormViewController: UIViewController, UITextFieldDelegate, UIDocumentPickerDelegate {
    private var endpoint: CHEndpoint
    private let isNew: Bool

    private let urlField = UITextField()
    private let nameField = UITextField()
    private let hostField = UITextField()
    private let portField = UITextField()
    private let secureSwitch = UISwitch()
    private let userField = UITextField()
    private let passwordField = UITextField()
    private let databaseField = UITextField()
    private let readOnlySwitch = UISwitch()
    private let compressionControl = UISegmentedControl(items: [String(localized: "Automatic"), "LZ4", String(localized: "None")])
    private let fingerprintField = UITextField()
    private let statusLabel = UILabel()
    /// The whole of a long message (the status shows its first paragraph).
    private let statusDetails = UIButton(configuration: .borderless())
    private var statusText = ""
    private let certificateButton = UIButton(configuration: .bordered())
    private let environmentButton = UIButton(configuration: .bordered())
    private var environment: CHEnvironment?
    private let sshSwitch = UISwitch()
    private let sshStack = UIStackView()
    private let sshHostField = UITextField()
    private let sshPortField = UITextField()
    private let sshUserField = UITextField()
    private let sshAuthControl = UISegmentedControl(items: [String(localized: "Password"), String(localized: "Private key")])
    private let sshPasswordField = UITextField()
    private let sshKeyButton = UIButton(configuration: .bordered())
    private let sshHostKeyLabel = UILabel()
    private let sshForgetButton = UIButton(configuration: .borderless())
    private var sshPasswordRow: UIView!
    private var sshKeyRow: UIView!
    private var sshHostKeyRow: UIView!
    /// A private key chosen or pasted, kept in the Keychain on Save.
    private var pendingKey: (name: String, text: String)?
    /// Whether the document picker open is for the SSH key (else the client certificate).
    private var pickingKey = false

    init(endpoint: CHEndpoint, isNew: Bool) {
        self.endpoint = endpoint
        self.isNew = isNew
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isNew ? String(localized: "New Connection") : endpoint.title
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .save, primaryAction: UIAction { [weak self] _ in self?.save() })

        func field(_ field: UITextField, _ placeholder: String, keyboard: UIKeyboardType = .default) -> UITextField {
            field.placeholder = placeholder
            field.borderStyle = .roundedRect
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.keyboardType = keyboard
            field.delegate = self
            return field
        }
        func row(_ title: String, _ control: UIView) -> UIView {
            let label = UILabel()
            label.text = title
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = .secondaryLabel
            let stack = UIStackView(arrangedSubviews: [label, control])
            stack.axis = .vertical
            stack.spacing = 4
            return stack
        }
        func toggle(_ title: String, _ control: UISwitch) -> UIView {
            let label = UILabel()
            label.text = title
            label.numberOfLines = 0
            let stack = UIStackView(arrangedSubviews: [label, control])
            stack.alignment = .center
            return stack
        }
        passwordField.isSecureTextEntry = true
        sshPasswordField.isSecureTextEntry = true
        sshHostKeyLabel.font = .preferredFont(forTextStyle: .footnote)
        sshHostKeyLabel.textColor = .secondaryLabel
        sshHostKeyLabel.lineBreakMode = .byTruncatingMiddle
        var forget = sshForgetButton.configuration ?? .borderless()
        forget.title = String(localized: "Forget")
        sshForgetButton.configuration = forget
        sshForgetButton.addAction(UIAction { [weak self] _ in self?.forgetHostKey() }, for: .primaryActionTriggered)
        sshKeyButton.showsMenuAsPrimaryAction = true
        sshKeyButton.menu = UIMenu(children: [
            UIAction(title: String(localized: "Choose a File…"), image: UIImage(systemName: "folder")) { [weak self] _ in self?.pickKey() },
            UIAction(title: String(localized: "Paste the Key"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.pasteKey() },
        ])
        sshSwitch.addAction(UIAction { [weak self] _ in self?.sshChanged() }, for: .valueChanged)
        sshAuthControl.addAction(UIAction { [weak self] _ in self?.showSSH() }, for: .valueChanged)
        let hostKeyStack = UIStackView(arrangedSubviews: [sshHostKeyLabel, sshForgetButton])
        hostKeyStack.alignment = .center
        hostKeyStack.spacing = 8
        sshPasswordRow = row(String(localized: "SSH password"), field(sshPasswordField, String(localized: "Password")))
        sshKeyRow = row(String(localized: "Private key (ed25519, ECDSA)"), sshKeyButton)
        sshHostKeyRow = row(String(localized: "The SSH server's key, as first seen"), hostKeyStack)
        for view in [row(String(localized: "SSH server"), field(sshHostField, "bastion.example.com", keyboard: .URL)),
                     row(String(localized: "SSH port"), field(sshPortField, "22", keyboard: .numberPad)),
                     row(String(localized: "SSH user"), field(sshUserField, String(localized: "User"))),
                     row(String(localized: "Sign in with"), sshAuthControl),
                     sshPasswordRow!, sshKeyRow!, sshHostKeyRow!] {
            sshStack.addArrangedSubview(view)
        }
        sshStack.axis = .vertical
        sshStack.spacing = 14
        urlField.addAction(UIAction { [weak self] _ in self?.urlChanged() }, for: .editingChanged)
        let stack = UIStackView(arrangedSubviews: [
            row(String(localized: "URL"), field(urlField, String(localized: "Paste a URL: https://user:password@host:8443/db"), keyboard: .URL)),
            row(String(localized: "Name"), field(nameField, String(localized: "Name"))),
            row(String(localized: "Environment (its color on the list and the editor)"), environmentButton),
            row(String(localized: "Host"), field(hostField, "localhost", keyboard: .URL)),
            row(String(localized: "Port"), field(portField, "8123", keyboard: .numberPad)),
            toggle(String(localized: "Use HTTPS"), secureSwitch),
            row(String(localized: "User"), field(userField, "default")),
            row(String(localized: "Password"), field(passwordField, String(localized: "Password"))),
            row(String(localized: "Database"), field(databaseField, String(localized: "the user's default"))),
            toggle(String(localized: "Read only: run no statements that change data"), readOnlySwitch),
            row(String(localized: "Compression"), compressionControl),
            row(String(localized: "Certificate's SHA-256 (only this one trusted; empty: the system's)"), field(fingerprintField, String(localized: "none"))),
            row(String(localized: "Client certificate (for servers that ask for one)"), certificateButton),
            toggle(String(localized: "Through an SSH server (a bastion)"), sshSwitch),
            sshStack,
            statusLabel,
            statusDetails,
            UIButton(configuration: .bordered(), primaryAction: UIAction(title: String(localized: "Test Connection")) { [weak self] _ in self?.test() }),
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 3
        var details = statusDetails.configuration ?? .borderless()
        details.title = String(localized: "Details…")
        details.contentInsets = .zero
        statusDetails.configuration = details
        statusDetails.contentHorizontalAlignment = .leading
        statusDetails.isHidden = true
        statusDetails.addAction(UIAction { [weak self] _ in self?.showStatusDetails() }, for: .primaryActionTriggered)
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
        certificateButton.addAction(UIAction { [weak self] _ in self?.chooseCertificate() }, for: .primaryActionTriggered)
        fill()
    }

    #if DEBUG
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // `-ViewerForm ssh`: scrolled to its end, where the SSH rows are.
        guard UserDefaults.standard.string(forKey: "ViewerForm") == "ssh", let scroll = view.subviews.first as? UIScrollView else { return }
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
    }
    #endif

    /// The environment chosen, and its menu.
    private func showEnvironment() {
        func dot(_ environment: CHEnvironment?) -> UIImage? {
            environment.flatMap { UIImage(systemName: "circle.fill")?.withTintColor($0.color, renderingMode: .alwaysOriginal) }
        }
        var configuration = environmentButton.configuration ?? .bordered()
        configuration.title = environment?.title ?? String(localized: "None")
        configuration.image = dot(environment)
        configuration.imagePadding = 6
        environmentButton.configuration = configuration
        let none = UIAction(title: String(localized: "None"), state: environment == nil ? .on : .off) { [weak self] _ in
            self?.environment = nil
            self?.showEnvironment()
        }
        environmentButton.menu = UIMenu(children: [none] + CHEnvironment.allCases.map { item in
            UIAction(title: item.title, image: dot(item), state: environment == item ? .on : .off) { [weak self] _ in
                // Production turns Read only on (it can be turned off again).
                if item == .production, self?.environment != .production { self?.readOnlySwitch.setOn(true, animated: true) }
                self?.environment = item
                self?.showEnvironment()
            }
        })
        environmentButton.showsMenuAsPrimaryAction = true
    }

    private func showCertificate() {
        var configuration = certificateButton.configuration ?? .bordered()
        configuration.title = endpoint.clientCertificate ?? String(localized: "Choose a .p12 File…")
        configuration.subtitle = endpoint.clientCertificate == nil ? nil : String(localized: "Tap to change or remove")
        certificateButton.configuration = configuration
    }

    private func chooseCertificate() {
        guard endpoint.clientCertificate == nil else {
            let sheet = UIAlertController(title: endpoint.clientCertificate, message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: String(localized: "Choose Another…"), style: .default) { [weak self] _ in self?.pickCertificate() })
            sheet.addAction(UIAlertAction(title: String(localized: "Remove"), style: .destructive) { [weak self] _ in
                guard let self else { return }
                Connections.removeClientCertificate(for: endpoint.id)
                endpoint.clientCertificate = nil
                showCertificate()
            })
            sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
            sheet.popoverPresentationController?.sourceView = certificateButton
            present(sheet, animated: true)
            return
        }
        pickCertificate()
    }

    private func pickCertificate() {
        pickingKey = false
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType(filenameExtension: "p12") ?? .data, UTType(filenameExtension: "pfx") ?? .data])
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        if pickingKey {
            takeKey(String(decoding: data, as: UTF8.self), name: url.lastPathComponent)
            return
        }
        let alert = UIAlertController(title: String(localized: "The password of \(url.lastPathComponent)"), message: nil, preferredStyle: .alert)
        alert.addTextField { $0.isSecureTextEntry = true }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            do {
                endpoint.clientCertificate = try Connections.storeClientCertificate(data, password: alert?.textFields?.first?.text ?? "", for: endpoint.id)
                showCertificate()
            } catch {
                showStatus((error as? CHClientIdentity.Failure) == .wrongPassword
                    ? String(localized: "The file's password is wrong.") : String(localized: "The file isn't a PKCS#12 certificate with its key."), isError: true)
            }
        })
        present(alert, animated: true)
    }

    // MARK: SSH

    private func sshChanged() {
        if sshSwitch.isOn, (sshUserField.text ?? "").isEmpty { sshUserField.text = endpoint.ssh?.user }
        showSSH()
    }

    /// The SSH rows as the form says: hidden when off, the password's or the key's.
    private func showSSH() {
        sshStack.isHidden = !sshSwitch.isOn
        sshPasswordRow.isHidden = sshAuthControl.selectedSegmentIndex != 0
        sshKeyRow.isHidden = sshAuthControl.selectedSegmentIndex != 1
        var configuration = sshKeyButton.configuration ?? .bordered()
        configuration.title = pendingKey?.name ?? endpoint.ssh?.keyName ?? String(localized: "Choose or Paste a Key…")
        sshKeyButton.configuration = configuration
        let hostKey = endpoint.ssh?.knownHostKey
        sshHostKeyRow.isHidden = hostKey == nil
        sshHostKeyLabel.text = hostKey.map(Self.shortKey)
    }

    /// A host key's type and the end of its base64, enough to tell keys apart.
    static func shortKey(_ key: String) -> String {
        let parts = key.split(separator: " ")
        guard parts.count >= 2 else { return key }
        return "\(parts[0]) …\(parts[1].suffix(16))"
    }

    private func pickKey() {
        pickingKey = true
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.delegate = self
        present(picker, animated: true)
    }

    private func pasteKey() {
        guard let text = UIPasteboard.general.string else { return }
        takeKey(text, name: String(localized: "A pasted key"))
    }

    /// A key read and checked now, kept on Save; one with a passphrase is unlocked first
    /// (kept so in the Keychain: the passphrase isn't asked again).
    private func takeKey(_ text: String, name: String) {
        if CHSSHKey.needsPassphrase(text) { return askPassphrase(for: text, name: name, again: false) }
        do {
            _ = try CHSSHKey.parse(text)
            pendingKey = (name, text)
            showStatus("")
        } catch {
            showStatus((error as? CHSSHKey.Failure)?.description ?? CHSSHKey.Failure.unreadable.description, isError: true)
        }
        showSSH()
    }

    private func askPassphrase(for text: String, name: String, again: Bool) {
        let alert = UIAlertController(title: String(localized: "The passphrase of “\(name)”"),
                                      message: again ? CHSSHKey.Failure.wrongPassphrase.description
                                          : String(localized: "The key is kept unlocked in the Keychain: the passphrase isn't asked again."),
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.textContentType = .password
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Unlock"), style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            do {
                takeKey(try CHSSHKey.unlocked(text, passphrase: alert?.textFields?.first?.text ?? ""), name: name)
            } catch CHSSHKey.Failure.wrongPassphrase {
                askPassphrase(for: text, name: name, again: true)
            } catch {
                showStatus((error as? CHSSHKey.Failure)?.description ?? CHSSHKey.Failure.unreadable.description, isError: true)
                showSSH()
            }
        })
        present(alert, animated: true)
    }

    /// The bastion's key forgotten: the next connection takes the one it presents.
    private func forgetHostKey() {
        endpoint.ssh?.knownHostKey = nil
        if !isNew { Connections.shared.save(edited, password: nil) }
        showSSH()
    }

    // MARK: The form

    private func fill() {
        // A name made for the connection (New server, the host's) is the field's placeholder, the field empty.
        nameField.text = endpoint.nameIsSuggested == true ? "" : endpoint.name
        environment = endpoint.environment
        showEnvironment()
        hostField.text = endpoint.host
        portField.text = String(endpoint.port)
        secureSwitch.isOn = endpoint.isSecure
        userField.text = endpoint.user
        passwordField.text = isNew ? "" : Connections.shared.password(for: endpoint)
        databaseField.text = endpoint.database
        readOnlySwitch.isOn = endpoint.isReadOnly
        compressionControl.selectedSegmentIndex = CHCompression.allCases.firstIndex(of: endpoint.compression) ?? 0
        if case .pinned(let fingerprint) = endpoint.trust { fingerprintField.text = fingerprint }
        showCertificate()
        sshSwitch.isOn = endpoint.ssh != nil
        sshHostField.text = endpoint.ssh?.host
        sshPortField.text = String(endpoint.ssh?.port ?? 22)
        sshUserField.text = endpoint.ssh?.user
        sshAuthControl.selectedSegmentIndex = endpoint.ssh?.keyName == nil ? 0 : 1
        sshPasswordField.text = !isNew && endpoint.ssh?.keyName == nil ? Connections.shared.sshSecret(for: endpoint) : ""
        showSSH()
        nameField.placeholder = endpoint.nameIsSuggested == true && !endpoint.name.isEmpty ? endpoint.name
            : Connections.shared.suggestedName(host: endpoint.host, except: endpoint.id)
    }

    private var edited: CHEndpoint {
        var endpoint = endpoint
        // No two connections of one name: a number is added to a name taken.
        let typed = nameField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        if typed.isEmpty {
            endpoint.name = Connections.shared.uniqueName(nameField.placeholder ?? "", except: endpoint.id)
            endpoint.nameIsSuggested = true
        } else {
            endpoint.name = Connections.shared.uniqueName(typed, except: endpoint.id)
            endpoint.nameIsSuggested = nil
        }
        endpoint.environment = environment
        endpoint.host = hostField.text?.trimmingCharacters(in: .whitespaces) ?? "localhost"
        endpoint.isSecure = secureSwitch.isOn
        endpoint.port = Int(portField.text ?? "") ?? (endpoint.isSecure ? 8443 : 8123)
        endpoint.user = (userField.text ?? "").isEmpty ? "default" : userField.text!
        endpoint.database = databaseField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        endpoint.isReadOnly = readOnlySwitch.isOn
        endpoint.compression = CHCompression.allCases[max(0, compressionControl.selectedSegmentIndex)]
        let fingerprint = fingerprintField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        endpoint.trust = fingerprint.isEmpty ? .system : .pinned(fingerprint)
        if sshSwitch.isOn {
            let host = sshHostField.text?.trimmingCharacters(in: .whitespaces) ?? ""
            let port = Int(sshPortField.text ?? "") ?? 22
            var bastion = endpoint.ssh ?? CHSSHBastion(host: host, port: port, user: "")
            // Another bastion: its key is yet to be seen.
            if bastion.host != host || bastion.port != port { bastion.knownHostKey = nil }
            bastion.host = host
            bastion.port = port
            bastion.user = sshUserField.text?.trimmingCharacters(in: .whitespaces) ?? ""
            bastion.keyName = sshAuthControl.selectedSegmentIndex == 1 ? (pendingKey?.name ?? endpoint.ssh?.keyName ?? "") : nil
            endpoint.ssh = bastion
        } else {
            endpoint.ssh = nil
        }
        return endpoint
    }

    /// The bastion's secret as the form says: none without one, its password, or the key chosen.
    private func saveSSHSecret(for endpoint: CHEndpoint) {
        if endpoint.ssh == nil {
            Connections.setSSHSecret("", for: endpoint.id)
        } else if endpoint.ssh?.keyName == nil {
            Connections.setSSHSecret(sshPasswordField.text ?? "", for: endpoint.id)
        } else if let pendingKey {
            Connections.setSSHSecret(pendingKey.text, for: endpoint.id)
        }
    }

    private func urlChanged() {
        guard let text = urlField.text, text.contains(":"), let (parsed, password) = CHEndpoint.parse(text) else { return }
        hostField.text = parsed.host
        portField.text = String(parsed.port)
        secureSwitch.isOn = parsed.isSecure
        userField.text = parsed.user
        databaseField.text = parsed.database
        if let password { passwordField.text = password }
        // Without a name of one's own, the host's is suggested (the field's placeholder).
        if (nameField.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            nameField.placeholder = Connections.shared.suggestedName(host: parsed.host, except: endpoint.id)
        }
    }

    private func save() {
        endpoint = edited
        Connections.shared.save(endpoint, password: passwordField.text ?? "")
        saveSSHSecret(for: endpoint)
        dismiss(animated: true)
    }

    private func test() {
        let endpoint = edited
        showStatus(String(localized: "Connecting…"))
        let client = CHClient(endpoint: endpoint, password: passwordField.text ?? "", identity: Connections.shared.clientIdentity(for: endpoint))
        // The form's secret, not yet saved.
        let secret = endpoint.ssh?.keyName == nil ? sshPasswordField.text ?? "" : pendingKey?.text
        Task {
            do {
                if endpoint.ssh != nil {
                    showStatus(String(localized: "Connecting to the SSH server…"))
                    if let hostKey = try await Connections.shared.route(client, for: endpoint, secret: secret) {
                        // Seen first now: kept when the form is saved.
                        if self.endpoint.ssh?.knownHostKey == nil { self.endpoint.ssh = endpoint.ssh; self.endpoint.ssh?.knownHostKey = hostKey }
                        showSSH()
                    }
                }
                let info = try await client.connect(timeout: endpoint.isCloud ? 120 : 15)
                showStatus(String(localized: "Connected: ClickHouse \(info.version.text), \(info.user), \(info.timeZone)"))
            } catch {
                showStatus(error.viewerDescription, isError: true)
            }
        }
    }

    /// A message under the form: its first paragraph (a server's error can be a
    /// page long), the whole in Details.
    private func showStatus(_ text: String, isError: Bool = false) {
        statusText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        statusLabel.text = statusText.firstParagraph
        statusLabel.textColor = isError ? .systemRed : .secondaryLabel
        statusDetails.isHidden = statusText.firstParagraph == statusText
    }

    private func showStatusDetails() {
        let alert = UIAlertController(title: String(localized: "The server's message"), message: statusText, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Copy"), style: .default) { [statusText] _ in UIPasteboard.general.string = statusText })
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        present(alert, animated: true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
