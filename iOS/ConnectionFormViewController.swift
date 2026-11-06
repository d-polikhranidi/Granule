import ClickHouseCore
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
    private let certificateButton = UIButton(configuration: .bordered())

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
        urlField.addAction(UIAction { [weak self] _ in self?.urlChanged() }, for: .editingChanged)
        let stack = UIStackView(arrangedSubviews: [
            row(String(localized: "URL"), field(urlField, String(localized: "Paste a URL: https://user:password@host:8443/db"), keyboard: .URL)),
            row(String(localized: "Name"), field(nameField, String(localized: "Name"))),
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
            statusLabel,
            UIButton(configuration: .bordered(), primaryAction: UIAction(title: String(localized: "Test Connection")) { [weak self] _ in self?.test() }),
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
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
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType(filenameExtension: "p12") ?? .data, UTType(filenameExtension: "pfx") ?? .data])
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let alert = UIAlertController(title: String(localized: "The password of \(url.lastPathComponent)"), message: nil, preferredStyle: .alert)
        alert.addTextField { $0.isSecureTextEntry = true }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            do {
                endpoint.clientCertificate = try Connections.storeClientCertificate(data, password: alert?.textFields?.first?.text ?? "", for: endpoint.id)
                showCertificate()
            } catch {
                statusLabel.text = (error as? CHClientIdentity.Failure) == .wrongPassword
                    ? String(localized: "The file's password is wrong.") : String(localized: "The file isn't a PKCS#12 certificate with its key.")
                statusLabel.textColor = .systemRed
            }
        })
        present(alert, animated: true)
    }

    private func fill() {
        nameField.text = endpoint.name
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
    }

    private var edited: CHEndpoint {
        var endpoint = endpoint
        endpoint.name = nameField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        endpoint.host = hostField.text?.trimmingCharacters(in: .whitespaces) ?? "localhost"
        endpoint.isSecure = secureSwitch.isOn
        endpoint.port = Int(portField.text ?? "") ?? (endpoint.isSecure ? 8443 : 8123)
        endpoint.user = (userField.text ?? "").isEmpty ? "default" : userField.text!
        endpoint.database = databaseField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        endpoint.isReadOnly = readOnlySwitch.isOn
        endpoint.compression = CHCompression.allCases[max(0, compressionControl.selectedSegmentIndex)]
        let fingerprint = fingerprintField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        endpoint.trust = fingerprint.isEmpty ? .system : .pinned(fingerprint)
        return endpoint
    }

    private func urlChanged() {
        guard let text = urlField.text, text.contains(":"), let (parsed, password) = CHEndpoint.parse(text) else { return }
        hostField.text = parsed.host
        portField.text = String(parsed.port)
        secureSwitch.isOn = parsed.isSecure
        userField.text = parsed.user
        databaseField.text = parsed.database
        if let password { passwordField.text = password }
        if (nameField.text ?? "").isEmpty { nameField.text = parsed.isCloud ? String(parsed.host.prefix { $0 != "." }) : parsed.host }
    }

    private func save() {
        endpoint = edited
        Connections.shared.save(endpoint, password: passwordField.text ?? "")
        dismiss(animated: true)
    }

    private func test() {
        let endpoint = edited
        statusLabel.text = String(localized: "Connecting…")
        statusLabel.textColor = .secondaryLabel
        let client = CHClient(endpoint: endpoint, password: passwordField.text ?? "", identity: Connections.shared.clientIdentity(for: endpoint))
        Task {
            do {
                let info = try await client.connect(timeout: endpoint.isCloud ? 120 : 15)
                statusLabel.text = String(localized: "Connected: ClickHouse \(info.version.text), \(info.user), \(info.timeZone)")
            } catch {
                statusLabel.text = error.viewerDescription
                statusLabel.textColor = .systemRed
            }
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
