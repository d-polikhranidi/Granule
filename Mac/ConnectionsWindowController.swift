import AppKit
import ClickHouseCore

/// The servers the user added: a list, and the selected one's form (a URL
/// pasted fills it in). Connect opens a window of queries on it.
final class ConnectionsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let onConnect: (CHEndpoint) -> Void
    private let list = NSTableView()
    private var endpoints: [CHEndpoint] { Connections.shared.endpoints }

    private let urlField = NSTextField()
    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let secureBox = NSButton(checkboxWithTitle: String(localized: "Use HTTPS"), target: nil, action: nil)
    private let userField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let databaseField = NSTextField()
    private let readOnlyBox = NSButton(checkboxWithTitle: String(localized: "Read only: run no statements that change data"), target: nil, action: nil)
    private let compressionPopUp = NSPopUpButton()
    private let trustPopUp = NSPopUpButton()
    private let fingerprintField = NSTextField()
    private let certificateLabel = NSTextField(labelWithString: "")
    private let certificateButton = NSButton(title: String(localized: "Choose…"), target: nil, action: nil)
    private let certificateRemove = NSButton(title: String(localized: "Remove"), target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let connectButton = NSButton(title: String(localized: "Connect"), target: nil, action: nil)
    private let testButton = NSButton(title: String(localized: "Test"), target: nil, action: nil)
    private var form: NSView!
    private var authority: Data?

    init(onConnect: @escaping (CHEndpoint) -> Void) {
        self.onConnect = onConnect
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 470), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = String(localized: "Connections")
        window.minSize = NSSize(width: 640, height: 420)
        window.setFrameAutosaveName("Connections")
        super.init(window: window)
        build()
        Connections.shared.onChange.append { [weak self] in self?.list.reloadData() }
        if endpoints.isEmpty {
            Connections.shared.save(CHEndpoint(name: String(localized: "Local server")), password: "")
        }
        list.reloadData()
        list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        // The list, with + and − under it.
        let column = NSTableColumn(identifier: .init("name"))
        list.addTableColumn(column)
        list.headerView = nil
        list.style = .inset
        list.usesAlternatingRowBackgroundColors = false
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(connect(_:))
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "Add"))!, target: self, action: #selector(addConnection(_:)))
        let remove = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: String(localized: "Remove"))!, target: self, action: #selector(removeConnection(_:)))
        [add, remove].forEach { $0.bezelStyle = .smallSquare; $0.isBordered = false }
        let buttons = NSStackView(views: [add, remove])
        buttons.spacing = 4
        let side = NSStackView(views: [scroll, buttons])
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 6

        // The form.
        urlField.placeholderString = String(localized: "Paste a URL: https://user:password@host:8443/database")
        urlField.delegate = self
        portField.formatter = {
            let formatter = NumberFormatter()
            formatter.allowsFloats = false
            formatter.minimum = 1
            formatter.maximum = 65535
            formatter.usesGroupingSeparator = false
            return formatter
        }()
        databaseField.placeholderString = String(localized: "the user's default")
        compressionPopUp.addItems(withTitles: [String(localized: "Automatic (none on a local network)"), String(localized: "LZ4"), String(localized: "None")])
        trustPopUp.addItems(withTitles: [String(localized: "The system's authorities"), String(localized: "Only this certificate (SHA-256)"),
                                         String(localized: "An authority of mine…")])
        trustPopUp.target = self
        trustPopUp.action = #selector(trustChanged(_:))
        fingerprintField.placeholderString = String(localized: "SHA-256 of the server's certificate")
        secureBox.target = self
        secureBox.action = #selector(secureChanged(_:))
        certificateLabel.textColor = .secondaryLabelColor
        certificateLabel.lineBreakMode = .byTruncatingMiddle
        certificateButton.target = self
        certificateButton.action = #selector(chooseCertificate(_:))
        certificateRemove.target = self
        certificateRemove.action = #selector(removeCertificate(_:))
        statusLabel.textColor = .secondaryLabelColor
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connect(_:))
        testButton.target = self
        testButton.action = #selector(test(_:))
        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            return label
        }
        let hostRow = NSStackView(views: [hostField, label(String(localized: "Port:")), portField])
        hostRow.distribution = .fill
        portField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        hostField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hostField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let grid = NSGridView(views: [
            [label(String(localized: "URL:")), urlField],
            [label(String(localized: "Name:")), nameField],
            [label(String(localized: "Host:")), hostRow],
            [NSGridCell.emptyContentView, secureBox],
            [label(String(localized: "User:")), userField],
            [label(String(localized: "Password:")), passwordField],
            [label(String(localized: "Database:")), databaseField],
            [NSGridCell.emptyContentView, readOnlyBox],
            [label(String(localized: "Compression:")), compressionPopUp],
            [label(String(localized: "Certificate:")), trustPopUp],
            [NSGridCell.emptyContentView, fingerprintField],
            [label(String(localized: "Client certificate:")), NSStackView(views: [certificateLabel, certificateButton, certificateRemove])],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 1).width = 380
        grid.setContentHuggingPriority(.required, for: .vertical)
        for index in 0..<grid.numberOfRows { grid.row(at: index).yPlacement = .center }
        let actions = NSStackView(views: [statusLabel, testButton, connectButton])
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let formStack = NSStackView(views: [grid, actions])
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 16
        formStack.setHuggingPriority(.required, for: .vertical)
        actions.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        form = formStack

        let split = NSStackView(views: [side, formStack])
        split.alignment = .top
        split.spacing = 20
        split.edgeInsets = NSEdgeInsets(top: 20, left: 16, bottom: 20, right: 20)
        split.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            side.widthAnchor.constraint(equalToConstant: 200),
            side.bottomAnchor.constraint(equalTo: split.bottomAnchor, constant: -20),
        ])
    }

    // MARK: The list

    func numberOfRows(in tableView: NSTableView) -> Int { endpoints.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let endpoint = endpoints[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: endpoint.title)
        let detail = NSTextField(labelWithString: "\(endpoint.host):\(endpoint.port)")
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        let icon = NSImageView(image: NSImage(systemSymbolName: endpoint.isCloud ? "cloud" : "server.rack", accessibilityDescription: nil)!)
        let texts = NSStackView(views: [title, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        let stack = NSStackView(views: [icon, texts])
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                                     stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 38 }

    func tableViewSelectionDidChange(_ notification: Notification) {
        fill(from: selected)
    }

    private var selected: CHEndpoint? {
        let row = list.selectedRow
        return endpoints.indices.contains(row) ? endpoints[row] : nil
    }

    @objc private func addConnection(_ sender: Any?) {
        save()
        Connections.shared.save(CHEndpoint(name: String(localized: "New server")), password: "")
        list.reloadData()
        list.selectRowIndexes(IndexSet(integer: endpoints.count - 1), byExtendingSelection: false)
        window?.makeFirstResponder(urlField)
    }

    @objc private func removeConnection(_ sender: Any?) {
        guard let endpoint = selected else { return }
        let row = list.selectedRow
        Connections.shared.remove(endpoint)
        list.reloadData()
        if !endpoints.isEmpty { list.selectRowIndexes(IndexSet(integer: min(row, endpoints.count - 1)), byExtendingSelection: false) }
        fill(from: selected)
    }

    // MARK: The form

    private func fill(from endpoint: CHEndpoint?) {
        form.isHidden = endpoint == nil
        guard let endpoint else { return }
        urlField.stringValue = ""
        nameField.stringValue = endpoint.name
        hostField.stringValue = endpoint.host
        portField.integerValue = endpoint.port
        secureBox.state = endpoint.isSecure ? .on : .off
        userField.stringValue = endpoint.user
        passwordField.stringValue = Connections.shared.password(for: endpoint)
        databaseField.stringValue = endpoint.database
        readOnlyBox.state = endpoint.isReadOnly ? .on : .off
        compressionPopUp.selectItem(at: CHCompression.allCases.firstIndex(of: endpoint.compression) ?? 0)
        authority = nil
        switch endpoint.trust {
        case .system:
            trustPopUp.selectItem(at: 0)
            fingerprintField.stringValue = ""
        case .pinned(let fingerprint):
            trustPopUp.selectItem(at: 1)
            fingerprintField.stringValue = fingerprint
        case .authority(let data):
            trustPopUp.selectItem(at: 2)
            authority = data
            fingerprintField.stringValue = String(localized: "An authority chosen (\(data.count) bytes)")
        }
        trustChanged(nil)
        showCertificate(endpoint.clientCertificate)
        statusLabel.stringValue = ""
    }

    private func showCertificate(_ name: String?) {
        certificateLabel.stringValue = name ?? String(localized: "None (for servers that ask for one: mTLS)")
        certificateRemove.isHidden = name == nil
    }

    /// A PKCS#12 file (.p12, .pfx) with the client's certificate and key, and its password.
    @objc private func chooseCertificate(_ sender: Any?) {
        guard var endpoint = selected, let window else { return }
        let panel = NSOpenPanel()
        panel.message = String(localized: "The client certificate and its key, as a PKCS#12 file (.p12, .pfx)")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            let alert = NSAlert()
            alert.messageText = String(localized: "The password of \(url.lastPathComponent)")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.window.initialFirstResponder = field
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                do {
                    let name = try Connections.storeClientCertificate(data, password: field.stringValue, for: endpoint.id)
                    endpoint = self.edited ?? endpoint
                    endpoint.clientCertificate = name
                    Connections.shared.save(endpoint, password: self.passwordField.stringValue)
                    self.showCertificate(name)
                } catch {
                    self.statusLabel.stringValue = (error as? CHClientIdentity.Failure) == .wrongPassword
                        ? String(localized: "The file's password is wrong.") : String(localized: "The file isn't a PKCS#12 certificate with its key.")
                    self.statusLabel.textColor = .systemRed
                }
            }
        }
    }

    @objc private func removeCertificate(_ sender: Any?) {
        guard var endpoint = edited else { return }
        Connections.removeClientCertificate(for: endpoint.id)
        endpoint.clientCertificate = nil
        Connections.shared.save(endpoint, password: passwordField.stringValue)
        showCertificate(nil)
    }

    /// The form as an endpoint (the selected one's id).
    private var edited: CHEndpoint? {
        guard var endpoint = selected else { return nil }
        endpoint.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        endpoint.host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        endpoint.port = portField.integerValue > 0 ? portField.integerValue : (secureBox.state == .on ? 8443 : 8123)
        endpoint.isSecure = secureBox.state == .on
        endpoint.user = userField.stringValue.isEmpty ? "default" : userField.stringValue
        endpoint.database = databaseField.stringValue.trimmingCharacters(in: .whitespaces)
        endpoint.isReadOnly = readOnlyBox.state == .on
        endpoint.compression = CHCompression.allCases[max(0, compressionPopUp.indexOfSelectedItem)]
        endpoint.clientCertificate = selected?.clientCertificate
        switch trustPopUp.indexOfSelectedItem {
        case 1: endpoint.trust = .pinned(fingerprintField.stringValue)
        case 2: endpoint.trust = authority.map(CHTrust.authority) ?? .system
        default: endpoint.trust = .system
        }
        return endpoint
    }

    @discardableResult
    private func save() -> CHEndpoint? {
        guard let endpoint = edited else { return nil }
        let row = list.selectedRow
        Connections.shared.save(endpoint, password: passwordField.stringValue)
        list.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        return endpoint
    }

    /// A URL pasted: the form filled in from it.
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === urlField, let (endpoint, password) = CHEndpoint.parse(urlField.stringValue),
              urlField.stringValue.contains("://") || urlField.stringValue.contains(":") else { return }
        hostField.stringValue = endpoint.host
        portField.integerValue = endpoint.port
        secureBox.state = endpoint.isSecure ? .on : .off
        userField.stringValue = endpoint.user
        databaseField.stringValue = endpoint.database
        if let password { passwordField.stringValue = password }
        if nameField.stringValue.isEmpty || nameField.stringValue == String(localized: "New server") {
            nameField.stringValue = endpoint.isCloud ? String(endpoint.host.prefix { $0 != "." }) : endpoint.host
        }
    }

    @objc private func secureChanged(_ sender: Any?) {
        let secure = secureBox.state == .on
        if secure, portField.integerValue == 8123 { portField.integerValue = 8443 }
        if !secure, portField.integerValue == 8443 { portField.integerValue = 8123 }
    }

    @objc private func trustChanged(_ sender: Any?) {
        let index = trustPopUp.indexOfSelectedItem
        fingerprintField.isHidden = index == 0
        fingerprintField.isEditable = index == 1
        guard index == 2, sender != nil else { return }
        let panel = NSOpenPanel()
        panel.message = String(localized: "The certificate of the authority that issued the server's (PEM or DER)")
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            authority = Self.der(data)
            fingerprintField.stringValue = String(localized: "\(url.lastPathComponent) chosen")
        }
    }

    /// A certificate's DER bytes from a PEM or DER file.
    static func der(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN") else { return data }
        let body = text.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body) ?? data
    }

    // MARK: Connecting

    @objc private func test(_ sender: Any?) {
        guard let endpoint = save() else { return }
        statusLabel.stringValue = String(localized: "Connecting…")
        statusLabel.textColor = .secondaryLabelColor
        let client = CHClient(endpoint: endpoint, password: passwordField.stringValue, identity: Connections.shared.clientIdentity(for: endpoint))
        Task {
            do {
                let info = try await client.connect(timeout: endpoint.isCloud ? 120 : 15)
                statusLabel.stringValue = String(localized: "Connected: ClickHouse \(info.version.text), \(info.user), \(info.timeZone)")
            } catch {
                statusLabel.stringValue = error.viewerDescription
                statusLabel.textColor = .systemRed
            }
        }
    }

    @objc private func connect(_ sender: Any?) {
        guard let endpoint = save() else { return }
        onConnect(endpoint)
    }
}
