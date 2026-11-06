import AppKit
import ClickHouseCore
import ClickHouseSSH

/// The servers the user added: a list, and the selected one's form (a URL
/// pasted fills it in). Connect opens a window of queries on it.
final class ConnectionsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    /// A connection that worked, and its client (connected).
    private let onConnect: (CHEndpoint, CHClient) -> Void
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
    private let sshBox = NSButton(checkboxWithTitle: String(localized: "Through an SSH server (a bastion)"), target: nil, action: nil)
    private let sshHostField = NSTextField()
    private let sshPortField = NSTextField()
    private let sshUserField = NSTextField()
    private let sshAuthPopUp = NSPopUpButton()
    private let sshPasswordField = NSSecureTextField()
    private let sshKeyLabel = NSTextField(labelWithString: "")
    private let sshKeyButton = NSButton(title: String(localized: "Choose…"), target: nil, action: nil)
    private let sshHostKeyLabel = NSTextField(labelWithString: "")
    private let sshForgetButton = NSButton(title: String(localized: "Forget"), target: nil, action: nil)
    /// The SSH rows of the form, shown when the box is on (the password's or the key's as chosen).
    private var sshRows: [NSGridRow] = []
    private var sshPasswordRow: NSGridRow!
    private var sshKeyRow: NSGridRow!
    private var sshHostKeyRow: NSGridRow!
    private var fingerprintRow: NSGridRow!
    /// A private key chosen and read, kept in the Keychain when the form is saved.
    private var pendingKey: (name: String, text: String)?
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    /// The whole of a long message (the status shows its first paragraph).
    private let statusDetails = NSButton(title: String(localized: "Details…"), target: nil, action: nil)
    private var statusText = ""
    /// The connection being tried (Test, or Connect before its window opens).
    private var attempt: Task<Void, Never>?
    private var isRestoringSelection = false
    private let connectButton = NSButton(title: String(localized: "Connect"), target: nil, action: nil)
    private let testButton = NSButton(title: String(localized: "Test"), target: nil, action: nil)
    private var form: NSView!
    private var authority: Data?

    init(onConnect: @escaping (CHEndpoint, CHClient) -> Void) {
        self.onConnect = onConnect
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = String(localized: "Connections")
        window.minSize = NSSize(width: 640, height: 420)
        window.setFrameAutosaveName("Connections")
        super.init(window: window)
        build()
        Connections.shared.onChange.append { [weak self] in self?.reloadList() }
        if endpoints.isEmpty {
            Connections.shared.save(CHEndpoint(name: String(localized: "Local server")), password: "")
        }
        list.reloadData()
        list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        window.center()
        #if DEBUG
        // `-ViewerForm testfail`: Test with a wrong password, then the right one, in a
        // connection made for it (removed after), clicked and typed as a user would.
        if UserDefaults.standard.string(forKey: "ViewerForm") == "testfail" {
            Task { await checkFormForTesting() }
        }
        // `-ViewerForm ssh`: the form's SSH rows shown (not saved), and the window's number.
        if UserDefaults.standard.string(forKey: "ViewerForm") == "ssh" {
            sshBox.state = .on
            sshHostField.stringValue = "bastion.example.com"
            sshAuthPopUp.selectItem(at: 1)
            sshChanged(nil)
            DispatchQueue.main.async { FileHandle.standardError.write(Data("VIEWER-WINDOW \(window.windowNumber)\n".utf8)) }
        }
        #endif
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
        sshBox.target = self
        sshBox.action = #selector(sshChanged(_:))
        sshPortField.formatter = portField.formatter
        sshPortField.placeholderString = "22"
        sshHostField.placeholderString = String(localized: "bastion.example.com")
        sshAuthPopUp.addItems(withTitles: [String(localized: "Password"), String(localized: "Private key (ed25519, ECDSA)")])
        sshAuthPopUp.target = self
        sshAuthPopUp.action = #selector(sshChanged(_:))
        sshKeyLabel.textColor = .secondaryLabelColor
        sshKeyLabel.lineBreakMode = .byTruncatingMiddle
        sshKeyButton.target = self
        sshKeyButton.action = #selector(chooseKey(_:))
        sshHostKeyLabel.textColor = .secondaryLabelColor
        sshHostKeyLabel.lineBreakMode = .byTruncatingMiddle
        sshHostKeyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sshForgetButton.target = self
        sshForgetButton.action = #selector(forgetHostKey(_:))
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isSelectable = false
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.cell?.truncatesLastVisibleLine = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusDetails.bezelStyle = .inline
        statusDetails.controlSize = .small
        statusDetails.isHidden = true
        statusDetails.target = self
        statusDetails.action = #selector(showStatusDetails(_:))
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
        let sshHostRow = NSStackView(views: [sshHostField, label(String(localized: "Port:")), sshPortField])
        sshPortField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        sshHostField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sshHostField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
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
            [label(String(localized: "SSH:")), sshBox],
            [label(String(localized: "SSH server:")), sshHostRow],
            [label(String(localized: "SSH user:")), sshUserField],
            [label(String(localized: "Sign in with:")), sshAuthPopUp],
            [label(String(localized: "SSH password:")), sshPasswordField],
            [label(String(localized: "Private key:")), NSStackView(views: [sshKeyLabel, sshKeyButton])],
            [label(String(localized: "Server's key:")), NSStackView(views: [sshHostKeyLabel, sshForgetButton])],
        ])
        fingerprintRow = grid.row(at: 10)
        sshRows = (grid.numberOfRows - 6..<grid.numberOfRows).map { grid.row(at: $0) }
        sshPasswordRow = grid.row(at: grid.numberOfRows - 3)
        sshKeyRow = grid.row(at: grid.numberOfRows - 2)
        sshHostKeyRow = grid.row(at: grid.numberOfRows - 1)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 1).width = 380
        // Below the fields' compression resistance (750): hugging must not squeeze them.
        grid.setContentHuggingPriority(NSLayoutConstraint.Priority(700), for: .vertical)
        for index in 0..<grid.numberOfRows { grid.row(at: index).yPlacement = .center }
        // The message takes what the buttons leave; they stay on the right.
        let actions = NSStackView(views: [statusLabel, statusDetails, testButton, connectButton])
        actions.distribution = .fill
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for button in [statusDetails, testButton, connectButton] { button.setContentHuggingPriority(.required, for: .horizontal) }
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
        guard !isRestoringSelection else { return }
        fill(from: selected)
    }

    /// The list read again, its selection kept: `reloadData()` drops it (and says
    /// nothing), which left the form editing no connection.
    private func reloadList() {
        let id = selected?.id
        list.reloadData()
        guard let id, let row = endpoints.firstIndex(where: { $0.id == id }) else { return }
        isRestoringSelection = true
        list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isRestoringSelection = false
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
        pendingKey = nil
        sshBox.state = endpoint.ssh == nil ? .off : .on
        sshHostField.stringValue = endpoint.ssh?.host ?? ""
        sshPortField.integerValue = endpoint.ssh?.port ?? 22
        sshUserField.stringValue = endpoint.ssh?.user ?? ""
        sshAuthPopUp.selectItem(at: endpoint.ssh?.keyName == nil ? 0 : 1)
        sshPasswordField.stringValue = endpoint.ssh?.keyName == nil ? Connections.shared.sshSecret(for: endpoint) : ""
        showSSH(endpoint)
        showStatus("")
    }

    #if DEBUG
    private func checkFormForTesting() async {
        guard let window else { return }
        func click(_ view: NSView) {
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
        func type(_ text: String, into field: NSTextField) {
            click(field)
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
            (field.currentEditor() as? NSTextView)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        func check(_ name: String, _ passed: Bool) {
            FileHandle.standardError.write(Data("VIEWER-CHECK \(passed ? "pass" : "FAIL") \(name): «\(statusLabel.stringValue.prefix(80))» row \(list.selectedRow)\n".utf8))
        }
        func queryWindows() -> Int { NSApp.windows.filter { $0.windowController is QueryWindowController && $0.isVisible }.count }
        try? await Task.sleep(for: .seconds(1))
        FileHandle.standardError.write(Data("VIEWER-WINDOW \(window.windowNumber)\n".utf8))
        addConnection(nil)
        type("http://default:wrong@localhost:18123", into: urlField)
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: urlField))
        click(testButton)
        try? await Task.sleep(for: .seconds(2))
        check("a wrong password is said in short, the connection still selected",
              statusLabel.stringValue.hasPrefix("default: Authentication failed") && !statusLabel.stringValue.contains("\n") && !statusDetails.isHidden && selected != nil)
        type("viewer", into: passwordField)
        click(testButton)
        try? await Task.sleep(for: .seconds(2))
        check("then the right one connects", statusLabel.stringValue.hasPrefix("Connected") && statusDetails.isHidden)
        type("wrong", into: passwordField)
        click(connectButton)
        try? await Task.sleep(for: .seconds(2))
        check("Connect with a wrong password opens no window", queryWindows() == 0 && statusLabel.textColor == .systemRed)
        type("viewer", into: passwordField)
        type("Checked", into: nameField)
        click(connectButton)
        try? await Task.sleep(for: .seconds(3))
        check("Connect with the right one opens the window", queryWindows() == 1 && connectButton.title == String(localized: "Connect"))
        check("the name reached the list", endpoints.contains { $0.name == "Checked" } && selected?.name == "Checked")
        NSApp.windows.filter { $0.windowController is QueryWindowController }.forEach { $0.close() }
        try? await Task.sleep(for: .seconds(1))
        // Its own list, emptied: the entries and their Keychain items made here.
        for endpoint in endpoints { Connections.shared.remove(endpoint) }
        NSApp.terminate(nil)
    }
    #endif

    /// The SSH rows as the form says: hidden when off, the password's or the key's.
    private func showSSH(_ endpoint: CHEndpoint?) {
        let on = sshBox.state == .on
        sshRows.forEach { $0.isHidden = !on }
        sshPasswordRow.isHidden = !on || sshAuthPopUp.indexOfSelectedItem != 0
        sshKeyRow.isHidden = !on || sshAuthPopUp.indexOfSelectedItem != 1
        let keyName = pendingKey?.name ?? endpoint?.ssh?.keyName
        sshKeyLabel.stringValue = keyName.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "None chosen")
        let hostKey = endpoint?.ssh?.knownHostKey
        sshHostKeyRow.isHidden = !on || hostKey == nil
        sshHostKeyLabel.stringValue = hostKey.map(Self.shortKey) ?? ""
        sshHostKeyLabel.toolTip = hostKey
        fitWindow()
    }

    /// The window as tall as the form, at least (its rows come and go).
    private func fitWindow() {
        guard let window, let root = window.contentView?.subviews.first else { return }
        root.layoutSubtreeIfNeeded()
        let height = root.fittingSize.height
        window.contentMinSize = NSSize(width: 640, height: height)
        let content = window.contentRect(forFrameRect: window.frame)
        guard content.height < height else { return }
        var frame = window.frame
        frame.origin.y -= height - content.height
        frame.size.height += height - content.height
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    /// A host key's type and the end of its base64, enough to tell keys apart.
    static func shortKey(_ key: String) -> String {
        let parts = key.split(separator: " ")
        guard parts.count >= 2 else { return key }
        return "\(parts[0]) …\(parts[1].suffix(16))"
    }

    @objc private func sshChanged(_ sender: Any?) {
        if sshBox.state == .on, sshUserField.stringValue.isEmpty { sshUserField.stringValue = NSUserName() }
        showSSH(edited)
    }

    /// An OpenSSH private key file, read and checked now.
    @objc private func chooseKey(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = String(localized: "A private key without a passphrase (ed25519 or ECDSA), such as ~/.ssh/id_ed25519")
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                _ = try CHSSHKey.parse(text)
                pendingKey = (url.lastPathComponent, text)
                showStatus("")
            } catch {
                showStatus((error as? CHSSHKey.Failure)?.description ?? CHSSHKey.Failure.unreadable.description, isError: true)
            }
            showSSH(edited)
        }
    }

    /// The bastion's key forgotten: the next connection takes the one it presents.
    @objc private func forgetHostKey(_ sender: Any?) {
        guard var endpoint = edited else { return }
        endpoint.ssh?.knownHostKey = nil
        Connections.shared.save(endpoint, password: passwordField.stringValue)
        showSSH(endpoint)
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
                    self.showStatus((error as? CHClientIdentity.Failure) == .wrongPassword
                        ? String(localized: "The file's password is wrong.") : String(localized: "The file isn't a PKCS#12 certificate with its key."), isError: true)
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
        if sshBox.state == .on {
            let host = sshHostField.stringValue.trimmingCharacters(in: .whitespaces)
            let port = sshPortField.integerValue > 0 ? sshPortField.integerValue : 22
            var bastion = selected?.ssh ?? CHSSHBastion(host: host, port: port, user: "")
            // Another bastion: its key is yet to be seen.
            if bastion.host != host || bastion.port != port { bastion.knownHostKey = nil }
            bastion.host = host
            bastion.port = port
            bastion.user = sshUserField.stringValue.trimmingCharacters(in: .whitespaces)
            bastion.keyName = sshAuthPopUp.indexOfSelectedItem == 1 ? (pendingKey?.name ?? selected?.ssh?.keyName ?? "") : nil
            endpoint.ssh = bastion
        } else {
            endpoint.ssh = nil
        }
        return endpoint
    }

    @discardableResult
    private func save() -> CHEndpoint? {
        guard let endpoint = edited else { return nil }
        let row = list.selectedRow
        Connections.shared.save(endpoint, password: passwordField.stringValue)
        // The bastion's secret: none without one, its password, or the key chosen.
        if endpoint.ssh == nil {
            Connections.setSSHSecret("", for: endpoint.id)
        } else if endpoint.ssh?.keyName == nil {
            Connections.setSSHSecret(sshPasswordField.stringValue, for: endpoint.id)
        } else if let pendingKey {
            Connections.setSSHSecret(pendingKey.text, for: endpoint.id)
        }
        pendingKey = nil
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
        fingerprintRow.isHidden = index == 0
        fingerprintField.isEditable = index == 1
        fitWindow()
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
        guard attempt == nil, let endpoint = save() else { return }
        tryConnecting(endpoint, opening: false)
    }

    /// Connects, then opens the server's window; an error stays in the form.
    /// While it tries, the button stops it.
    @objc private func connect(_ sender: Any?) {
        if let attempt {
            attempt.cancel()
            return
        }
        guard let endpoint = save() else { return }
        tryConnecting(endpoint, opening: true)
    }

    private func tryConnecting(_ endpoint: CHEndpoint, opening: Bool) {
        showStatus(endpoint.isCloud ? String(localized: "Connecting (a sleeping service takes a while to wake)…") : String(localized: "Connecting…"))
        testButton.isEnabled = false
        connectButton.title = String(localized: "Stop")
        let client = CHClient(endpoint: endpoint, password: passwordField.stringValue, identity: Connections.shared.clientIdentity(for: endpoint))
        attempt = Task {
            do {
                if endpoint.ssh != nil { showStatus(String(localized: "Connecting to the SSH server…")) }
                try await Connections.shared.route(client, for: endpoint)
                showSSH(selected)
                let info = try await client.connect(timeout: endpoint.isCloud ? 120 : 15)
                try Task.checkCancellation()
                if opening {
                    showStatus("")
                    onConnect(endpoint, client)
                } else {
                    showStatus(String(localized: "Connected: ClickHouse \(info.version.text), \(info.user), \(info.timeZone)"))
                }
            } catch where Task.isCancelled {
                showStatus(String(localized: "Stopped."))
            } catch {
                showStatus(error.viewerDescription, isError: true)
                showSSH(selected)
            }
            attempt = nil
            testButton.isEnabled = true
            connectButton.title = String(localized: "Connect")
        }
    }

    /// A message under the form: its first paragraph, at most two lines (a
    /// server's error can be a page long), the whole in Details and its tip.
    private func showStatus(_ text: String, isError: Bool = false) {
        statusText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = statusText.firstParagraph
        // Wrapped at the width it has (what the buttons leave), so two lines show.
        statusLabel.superview?.layoutSubtreeIfNeeded()
        statusLabel.preferredMaxLayoutWidth = max(160, statusLabel.frame.width)
        statusLabel.stringValue = first
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        statusLabel.toolTip = statusText.isEmpty ? nil : statusText
        statusDetails.isHidden = first == statusText && statusText.count < 160
    }

    @objc private func showStatusDetails(_ sender: Any?) {
        guard let window, !statusText.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "The server's message")
        alert.informativeText = statusText
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Copy"))
        alert.beginSheetModal(for: window) { [statusText] response in
            guard response == .alertSecondButtonReturn else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(statusText, forType: .string)
        }
    }
}
