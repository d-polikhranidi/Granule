import AppKit
import ClickHouseCore
import ClickHouseSSH
import SwiftUI

/// The servers the user added: a sidebar of them and the selected one's form
/// (a URL pasted fills it in). Connect connects, then opens a window of queries
/// on it. The sidebar and toolbar are the system's, so they take the system's
/// look (Liquid Glass) by themselves; the form is SwiftUI's grouped form, as in
/// System Settings.
final class ConnectionsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                         NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// A connection that worked, and its client (connected).
    private let onConnect: (CHEndpoint, CHClient) -> Void
    private let list = ConnectionsTable()
    private let form = ConnectionForm()
    private var endpoints: [CHEndpoint] { Connections.shared.endpoints }
    /// The connection being tried (Test, or Connect before its window opens).
    private var attempt: Task<Void, Never>?
    private var isRestoringSelection = false
    /// A save under way: the list's row is reloaded alone, its selection kept.
    private var isSaving = false

    init(onConnect: @escaping (CHEndpoint, CHClient) -> Void) {
        self.onConnect = onConnect
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = String(localized: "Connections")
        window.minSize = NSSize(width: 700, height: 460)
        super.init(window: window)
        window.delegate = self
        build()
        window.setFrameAutosaveName("Connections")
        if !window.setFrameUsingName("Connections") { window.center() }
        Connections.shared.onChange.append { [weak self] in
            guard let self, !isSaving else { return }
            reloadList()
        }
        if endpoints.isEmpty {
            var local = CHEndpoint(name: String(localized: "Local server"))
            local.nameIsSuggested = true
            Connections.shared.save(local, password: "")
        }
        list.reloadData()
        list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #if DEBUG
        // `-ViewerForm testfail`: Test with a wrong password, then the right one, in a
        // connection made for it (removed after), through the form's own actions.
        if UserDefaults.standard.string(forKey: "ViewerForm") == "testfail" {
            Task { await checkFormForTesting() }
        }
        // `-ViewerForm ssh`: the form's SSH rows shown (not saved), and the window's number.
        if UserDefaults.standard.string(forKey: "ViewerForm") == "ssh" {
            form.sshEnabled = true
            form.sshHost = "bastion.example.com"
            form.sshUser = NSUserName()
            form.sshSignIn = .key
            form.environment = .production
            form.trust = .pinned
            if let screen = window.screen ?? NSScreen.main {
                window.setFrame(NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY, width: 860, height: screen.visibleFrame.height), display: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { FileHandle.standardError.write(Data("VIEWER-WINDOW \(window.windowNumber)\n".utf8)) }
            // `-ViewerMenu environment`: the Environment menu opened too (its window captured from outside).
            if UserDefaults.standard.string(forKey: "ViewerMenu") == "environment" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    // SwiftUI builds its accessibility tree only for a client like VoiceOver: clicked where the
                    // picker is in this layout (the Environment row, its chevrons at the form's trailing edge).
                    let point = NSPoint(x: window.frame.width - 42, y: window.frame.height - 244)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            NSApp.postEvent(event, atStart: false)
                        }
                    }
                }
            }
        }
        #endif
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let window else { return }
        // The sidebar: a source list (rounded selection, the user's sidebar size).
        list.addTableColumn(NSTableColumn(identifier: .init("name")))
        list.headerView = nil
        list.style = .automatic
        list.rowSizeStyle = .default
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(connectClicked(_:))
        list.onDelete = { [weak self] in self?.deleteSelected(nil) }
        let menu = NSMenu()
        menu.delegate = self
        list.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let sidebar = NSViewController()
        sidebar.view = scroll

        form.actions = ConnectionForm.Actions(
            test: { [weak self] in self?.test(nil) },
            connect: { [weak self] in self?.connectClicked(nil) },
            new: { [weak self] in self?.addConnection(nil) },
            delete: { [weak self] in self?.deleteSelected(nil) },
            chooseAuthority: { [weak self] in self?.chooseAuthority() },
            chooseCertificate: { [weak self] in self?.chooseCertificate() },
            removeCertificate: { [weak self] in self?.removeCertificate() },
            chooseKey: { [weak self] in self?.chooseKey() },
            forgetHostKey: { [weak self] in self?.forgetHostKey() },
            showDetails: { [weak self] in self?.showStatusDetails() })
        let hosting = NSHostingController(rootView: ConnectionFormView(form: form))
        hosting.sizingOptions = [.minSize]

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = false
        split.addSplitViewItem(sidebarItem)
        let formItem = NSSplitViewItem(viewController: hosting)
        formItem.minimumThickness = 460
        if #available(macOS 26.0, *) { formItem.automaticallyAdjustsSafeAreaInsets = true }
        split.addSplitViewItem(formItem)
        split.splitView.autosaveName = "ConnectionsSplit"
        window.contentViewController = split

        let toolbar = NSToolbar(identifier: "Connections")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    // MARK: The toolbar

    private static let newItem = NSToolbarItem.Identifier("newConnection")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.newItem, .sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.newItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = String(localized: "New Connection")
        item.toolTip = String(localized: "New Connection (⌘N)")
        item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "New Connection"))
        item.target = self
        item.action = #selector(addConnection(_:))
        item.isBordered = true
        return item
    }

    // MARK: The list

    func numberOfRows(in tableView: NSTableView) -> Int { endpoints.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let endpoint = endpoints[row]
        let identifier = NSUserInterfaceItemIdentifier("connection")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? Self.makeCell(identifier)
        cell.textField?.stringValue = endpoint.title
        cell.imageView?.image = NSImage(systemSymbolName: endpoint.isCloud ? "cloud" : "server.rack", accessibilityDescription: nil)
        // The environment's color says what the server is for; without one, the accent color.
        cell.imageView?.contentTintColor = endpoint.environment?.color
        cell.toolTip = [endpoint.environment?.title, "\(endpoint.user)@\(endpoint.host):\(endpoint.port)"].compactMap { $0 }.joined(separator: " · ")
        return cell
    }

    private static func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        for view in [image, text] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoringSelection else { return }
        // The form shown is kept before another is shown.
        save()
        load(selected)
    }

    /// The list read again, its selection kept: `reloadData()` drops it (and says
    /// nothing), which left the form editing no connection.
    private func reloadList() {
        let id = form.id ?? selected?.id
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

    /// The connection the form shows, as saved.
    private var shown: CHEndpoint? {
        guard let id = form.id else { return nil }
        return endpoints.first { $0.id == id }
    }

    private func select(_ id: UUID) {
        guard let row = endpoints.firstIndex(where: { $0.id == id }) else { return }
        list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        list.scrollRowToVisible(row)
    }

    /// The row a context menu or the Delete key is for: the clicked one, else the selected one.
    private var targetEndpoint: CHEndpoint? {
        let row = list.clickedRow >= 0 ? list.clickedRow : list.selectedRow
        return endpoints.indices.contains(row) ? endpoints[row] : nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard targetEndpoint != nil else { return }
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }
        menu.addItem(item(String(localized: "Connect"), #selector(connectClicked(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Duplicate"), #selector(duplicate(_:))))
        menu.addItem(item(String(localized: "Copy URL"), #selector(copyURL(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Delete…"), #selector(deleteSelected(_:))))
    }

    @objc func addConnection(_ sender: Any?) {
        save()
        var endpoint = CHEndpoint(name: Connections.shared.suggestedName(host: "", except: nil))
        endpoint.nameIsSuggested = true
        Connections.shared.save(endpoint, password: "")
        select(endpoint.id)
        form.focusURL += 1
    }

    @objc private func duplicate(_ sender: Any?) {
        save()
        guard let original = targetEndpoint else { return }
        var copy = original
        copy.id = UUID()
        copy.name = Connections.shared.uniqueName(String(localized: "\(original.title) copy"), except: copy.id)
        copy.nameIsSuggested = nil
        Connections.shared.save(copy, password: Connections.shared.password(for: original))
        Connections.setSSHSecret(Connections.shared.sshSecret(for: original), for: copy.id)
        for suffix in [".p12", ".p12-password"] {
            if let data = Keychain.data(for: original.id, suffix: suffix) { Keychain.setData(data, for: copy.id, suffix: suffix) }
        }
        select(copy.id)
    }

    /// The connection's address, without its password.
    @objc private func copyURL(_ sender: Any?) {
        guard let endpoint = targetEndpoint else { return }
        let url = "\(endpoint.isSecure ? "https" : "http")://\(endpoint.user)@\(endpoint.host):\(endpoint.port)/\(endpoint.database)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func deleteSelected(_ sender: Any?) {
        guard let endpoint = targetEndpoint, let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete “\(endpoint.title)”?")
        alert.informativeText = String(localized: "Its password, keys and certificate are removed from the Keychain. Its history stays.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn,
                  let row = endpoints.firstIndex(where: { $0.id == endpoint.id }) else { return }
            if form.id == endpoint.id { form.id = nil }
            Connections.shared.remove(endpoint)
            if !endpoints.isEmpty {
                list.selectRowIndexes(IndexSet(integer: min(row, endpoints.count - 1)), byExtendingSelection: false)
            }
            load(selected)
        }
    }

    // MARK: The form

    private func load(_ endpoint: CHEndpoint?) {
        attempt?.cancel()
        guard let endpoint else {
            form.id = nil
            return
        }
        form.id = endpoint.id
        form.url = ""
        // A name made for it shows as the field's prompt: typing starts one of one's own.
        if endpoint.nameIsSuggested == true {
            form.name = ""
            form.namePrompt = endpoint.name
        } else {
            form.name = endpoint.name
            form.namePrompt = Connections.shared.suggestedName(host: endpoint.host, except: endpoint.id)
        }
        form.environment = endpoint.environment
        form.isReadOnly = endpoint.isReadOnly
        form.host = endpoint.host
        form.port = String(endpoint.port)
        form.isSecure = endpoint.isSecure
        form.database = endpoint.database
        form.compression = endpoint.compression
        form.user = endpoint.user
        form.password = Connections.shared.password(for: endpoint)
        form.authority = nil
        form.fingerprint = ""
        switch endpoint.trust {
        case .system:
            form.trust = .system
        case .pinned(let fingerprint):
            form.trust = .pinned
            form.fingerprint = fingerprint
        case .authority(let data):
            form.trust = .authority
            form.authority = data
            form.authorityName = String(localized: "An authority (\(data.count) bytes)")
        }
        form.clientCertificate = endpoint.clientCertificate
        form.sshEnabled = endpoint.ssh != nil
        form.sshHost = endpoint.ssh?.host ?? ""
        form.sshPort = String(endpoint.ssh?.port ?? 22)
        form.sshUser = endpoint.ssh?.user ?? ""
        form.sshSignIn = endpoint.ssh?.keyName == nil ? .password : .key
        form.sshPassword = endpoint.ssh?.keyName == nil ? Connections.shared.sshSecret(for: endpoint) : ""
        form.keyName = endpoint.ssh?.keyName.flatMap { $0.isEmpty ? nil : $0 }
        form.pendingKey = nil
        form.knownHostKey = endpoint.ssh?.knownHostKey
        form.setStatus("")
    }

    /// The form as the connection it shows.
    private var edited: CHEndpoint? {
        guard var endpoint = shown else { return nil }
        // No two connections of one name: a number is added to a name taken.
        let typed = form.name.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty {
            endpoint.name = Connections.shared.uniqueName(form.namePrompt, except: endpoint.id)
            endpoint.nameIsSuggested = true
        } else {
            endpoint.name = Connections.shared.uniqueName(typed, except: endpoint.id)
            endpoint.nameIsSuggested = nil
        }
        endpoint.environment = form.environment
        endpoint.host = form.host.trimmingCharacters(in: .whitespaces)
        endpoint.isSecure = form.isSecure
        endpoint.port = Int(form.port.trimmingCharacters(in: .whitespaces)) ?? (form.isSecure ? 8443 : 8123)
        endpoint.user = form.user.isEmpty ? "default" : form.user
        endpoint.database = form.database.trimmingCharacters(in: .whitespaces)
        endpoint.isReadOnly = form.isReadOnly
        endpoint.compression = form.compression
        switch form.trust {
        case .pinned: endpoint.trust = .pinned(form.fingerprint.trimmingCharacters(in: .whitespaces))
        case .authority: endpoint.trust = form.authority.map(CHTrust.authority) ?? .system
        case .system: endpoint.trust = .system
        }
        if form.sshEnabled {
            let host = form.sshHost.trimmingCharacters(in: .whitespaces)
            let port = Int(form.sshPort.trimmingCharacters(in: .whitespaces)) ?? 22
            // The host key is the saved one (kept by a connection, dropped by Forget).
            var bastion = endpoint.ssh ?? CHSSHBastion(host: host, port: port, user: "")
            // Another bastion: its key is yet to be seen.
            if bastion.host != host || bastion.port != port { bastion.knownHostKey = nil }
            bastion.host = host
            bastion.port = port
            bastion.user = form.sshUser.trimmingCharacters(in: .whitespaces)
            bastion.keyName = form.sshSignIn == .key ? (form.pendingKey?.name ?? form.keyName ?? "") : nil
            endpoint.ssh = bastion
        } else {
            endpoint.ssh = nil
        }
        return endpoint
    }

    @discardableResult
    private func save() -> CHEndpoint? {
        guard let endpoint = edited else { return nil }
        isSaving = true
        Connections.shared.save(endpoint, password: form.password)
        // A typed name that was taken now has its number: the field says so.
        if endpoint.nameIsSuggested == nil, endpoint.name != form.name.trimmingCharacters(in: .whitespaces) {
            form.name = endpoint.name
        }
        // The bastion's secret: none without one, its password, or the key chosen.
        if endpoint.ssh == nil {
            Connections.setSSHSecret("", for: endpoint.id)
        } else if endpoint.ssh?.keyName == nil {
            Connections.setSSHSecret(form.sshPassword, for: endpoint.id)
        } else if let key = form.pendingKey {
            Connections.setSSHSecret(key.text, for: endpoint.id)
            form.keyName = key.name
            form.pendingKey = nil
        }
        isSaving = false
        if let row = endpoints.firstIndex(where: { $0.id == endpoint.id }) {
            list.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
        return endpoint
    }

    func windowWillClose(_ notification: Notification) {
        save()
    }

    /// A certificate's DER bytes from a PEM or DER file.
    static func der(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN") else { return data }
        let body = text.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body) ?? data
    }

    private func chooseAuthority() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = String(localized: "The certificate of the authority that issued the server's (PEM or DER)")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            form.authority = Self.der(data)
            form.authorityName = url.lastPathComponent
            save()
        }
    }

    /// A PKCS#12 file (.p12, .pfx) with the client's certificate and key, and its password.
    private func chooseCertificate() {
        guard let id = form.id, let window else { return }
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
                    let name = try Connections.storeClientCertificate(data, password: field.stringValue, for: id)
                    self.save()
                    if var endpoint = self.shown {
                        endpoint.clientCertificate = name
                        Connections.shared.save(endpoint, password: nil)
                    }
                    self.form.clientCertificate = name
                } catch {
                    self.form.setStatus((error as? CHClientIdentity.Failure) == .wrongPassword
                        ? String(localized: "The file's password is wrong.") : String(localized: "The file isn't a PKCS#12 certificate with its key."),
                                        isError: true)
                }
            }
        }
    }

    private func removeCertificate() {
        guard let id = form.id else { return }
        save()
        Connections.removeClientCertificate(for: id)
        if var endpoint = shown {
            endpoint.clientCertificate = nil
            Connections.shared.save(endpoint, password: nil)
        }
        form.clientCertificate = nil
    }

    /// An OpenSSH private key file, read and checked now (kept when the form is saved).
    private func chooseKey() {
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
                form.pendingKey = ConnectionForm.PendingKey(name: url.lastPathComponent, text: text)
                form.setStatus("")
                save()
            } catch {
                form.setStatus((error as? CHSSHKey.Failure)?.description ?? CHSSHKey.Failure.unreadable.description, isError: true)
            }
        }
    }

    /// The bastion's key forgotten: the next connection takes the one it presents.
    private func forgetHostKey() {
        save()
        guard var endpoint = shown else { return }
        endpoint.ssh?.knownHostKey = nil
        Connections.shared.save(endpoint, password: nil)
        form.knownHostKey = nil
    }

    // MARK: Connecting

    @objc private func test(_ sender: Any?) {
        guard attempt == nil, let endpoint = save() else { return }
        tryConnecting(endpoint, opening: false)
    }

    /// Connects, then opens the server's window; an error stays in the form.
    /// While it tries, the button stops it.
    @objc private func connectClicked(_ sender: Any?) {
        if let attempt {
            attempt.cancel()
            return
        }
        // A double-click or the menu on another row connects to that one.
        if sender is NSMenuItem || sender as? NSTableView === list, let target = targetEndpoint, target.id != form.id {
            select(target.id)
        }
        guard let endpoint = save() else { return }
        tryConnecting(endpoint, opening: true)
    }

    private func tryConnecting(_ endpoint: CHEndpoint, opening: Bool) {
        form.setStatus(endpoint.isCloud ? String(localized: "Connecting (a sleeping service takes a while to wake)…") : String(localized: "Connecting…"))
        form.isAttempting = true
        let client = CHClient(endpoint: endpoint, password: form.password, identity: Connections.shared.clientIdentity(for: endpoint))
        attempt = Task {
            do {
                if endpoint.ssh != nil { form.setStatus(String(localized: "Connecting to the SSH server…")) }
                try await Connections.shared.route(client, for: endpoint)
                form.knownHostKey = shown?.ssh?.knownHostKey
                let info = try await client.connect(timeout: endpoint.isCloud ? 120 : 15)
                try Task.checkCancellation()
                if opening {
                    form.setStatus("")
                    onConnect(endpoint, client)
                } else {
                    form.setStatus(String(localized: "Connected: ClickHouse \(info.version.text), \(info.user), \(info.timeZone)"))
                }
            } catch where Task.isCancelled {
                form.setStatus(String(localized: "Stopped."))
            } catch {
                form.setStatus(error.viewerDescription, isError: true)
                form.knownHostKey = shown?.ssh?.knownHostKey
            }
            attempt = nil
            form.isAttempting = false
        }
    }

    private func showStatusDetails() {
        guard let window, !form.status.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "The server's message")
        alert.informativeText = form.status
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Copy"))
        alert.beginSheetModal(for: window) { [status = form.status] response in
            guard response == .alertSecondButtonReturn else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(status, forType: .string)
        }
    }

    #if DEBUG
    private func checkFormForTesting() async {
        guard let window else { return }
        func check(_ name: String, _ passed: Bool) {
            FileHandle.standardError.write(Data("VIEWER-CHECK \(passed ? "pass" : "FAIL") \(name): «\(form.statusSummary.prefix(80))» row \(list.selectedRow)\n".utf8))
        }
        func queryWindows() -> Int { NSApp.windows.filter { $0.windowController is QueryWindowController && $0.isVisible }.count }
        func wait() async {
            for _ in 0..<40 where form.isAttempting { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(300))
        }
        try? await Task.sleep(for: .seconds(1))
        FileHandle.standardError.write(Data("VIEWER-WINDOW \(window.windowNumber)\n".utf8))
        addConnection(nil)
        check("a new connection's name is the field's prompt, the field empty", form.name.isEmpty && form.namePrompt == String(localized: "New server"))
        form.name = "Local server"
        check("a name taken is said", form.nameIsTaken)
        save()
        check("and gets a number when saved", form.name == "Local server 2" && shown?.name == "Local server 2" && !form.nameIsTaken)
        form.name = ""
        save()
        check("no name typed: New server", shown?.name == String(localized: "New server") && shown?.nameIsSuggested == true)
        form.url = "http://default:wrong@localhost:18123"
        form.applyURL()
        test(nil)
        await wait()
        check("a wrong password is said in short, the connection still selected",
              form.statusSummary.hasPrefix("default: Authentication failed") && !form.statusSummary.contains("\n") && form.hasStatusDetails
              && selected?.id == form.id && form.id != nil)
        FileHandle.standardError.write(Data("VIEWER-ERROR \(window.windowNumber)\n".utf8))
        try? await Task.sleep(for: .seconds(1.5))
        form.password = "viewer"
        test(nil)
        await wait()
        check("then the right one connects", form.statusSummary.hasPrefix("Connected") && !form.hasStatusDetails)
        form.password = "wrong"
        connectClicked(nil)
        await wait()
        check("Connect with a wrong password opens no window", queryWindows() == 0 && form.statusIsError)
        form.password = "viewer"
        form.name = "Checked"
        form.environment = .production
        connectClicked(nil)
        await wait()
        try? await Task.sleep(for: .seconds(1))
        check("Connect with the right one opens the window", queryWindows() == 1 && !form.isAttempting)
        check("the name and environment reached the list", endpoints.contains { $0.name == "Checked" && $0.environment == .production } && selected?.name == "Checked")
        check("the connections window closed for the server's", !window.isVisible)
        NSApp.windows.filter { $0.windowController is QueryWindowController }.forEach { $0.close() }
        try? await Task.sleep(for: .seconds(1))
        check("it came back when the server's window closed", window.isVisible)
        form.isReadOnly = false
        form.setEnvironment(.staging)
        let stagingLeftItAlone = !form.isReadOnly
        form.setEnvironment(.production)
        check("Production turns Read only on, other environments don't", stagingLeftItAlone && form.isReadOnly)
        list.deselectAll(nil)
        try? await Task.sleep(for: .milliseconds(300))
        check("no connection selected: the hint in the form's place", form.id == nil)
        FileHandle.standardError.write(Data("VIEWER-PLACEHOLDER \(window.windowNumber)\n".utf8))
        try? await Task.sleep(for: .seconds(2))
        // Its own list, emptied: the entries and their Keychain items made here.
        for endpoint in endpoints { Connections.shared.remove(endpoint) }
        NSApp.terminate(nil)
    }
    #endif
}

/// The list of connections: Delete removes the selected one (after asking).
final class ConnectionsTable: NSTableView {
    var onDelete: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        let deletes = [NSDeleteCharacter, NSDeleteFunctionKey].compactMap { UnicodeScalar(UInt32($0)).map { String(Character($0)) } }
        if let characters = event.charactersIgnoringModifiers, deletes.contains(characters), selectedRow >= 0 {
            onDelete()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - The form

/// What the connection form shows and edits; the window controller loads and saves it.
@Observable
final class ConnectionForm {
    enum Trust: Hashable { case system, pinned, authority }
    enum SSHSignIn: Hashable { case password, key }

    struct PendingKey {
        var name: String
        var text: String
    }

    struct Actions {
        var test: () -> Void = {}
        var connect: () -> Void = {}
        var new: () -> Void = {}
        var delete: () -> Void = {}
        var chooseAuthority: () -> Void = {}
        var chooseCertificate: () -> Void = {}
        var removeCertificate: () -> Void = {}
        var chooseKey: () -> Void = {}
        var forgetHostKey: () -> Void = {}
        var showDetails: () -> Void = {}
    }

    /// The connection shown (`nil`: none selected).
    var id: UUID?
    var url = ""
    var name = ""
    var environment: CHEnvironment?

    /// Production turns Read only on (it can be turned off again): nothing is
    /// changed there by accident, as the research's clients that write learned.
    func setEnvironment(_ environment: CHEnvironment?) {
        if environment == .production, self.environment != .production { isReadOnly = true }
        self.environment = environment
    }
    var isReadOnly = false
    var host = ""
    var port = ""
    var isSecure = false
    var database = ""
    var compression = CHCompression.automatic
    var user = ""
    var password = ""
    var trust = Trust.system
    var fingerprint = ""
    var authority: Data?
    var authorityName = ""
    var clientCertificate: String?
    var sshEnabled = false
    var sshHost = ""
    var sshPort = "22"
    var sshUser = ""
    var sshSignIn = SSHSignIn.password
    var sshPassword = ""
    var keyName: String?
    /// A private key chosen and read, kept in the Keychain when the form is saved.
    var pendingKey: PendingKey?
    var knownHostKey: String?
    /// The last message, whole (the form shows its first paragraph).
    private(set) var status = ""
    private(set) var statusIsError = false
    var isAttempting = false
    /// Bumped to put the cursor in the URL field (a new connection).
    var focusURL = 0
    /// The name the connection gets if none is typed (New server, the host's).
    var namePrompt = ""
    var actions = Actions()

    var statusSummary: String { status.firstParagraph }
    var hasStatusDetails: Bool { statusSummary != status || status.count > 160 }

    func setStatus(_ text: String, isError: Bool = false) {
        status = text.trimmingCharacters(in: .whitespacesAndNewlines)
        statusIsError = isError
    }

    /// HTTPS on or off, the usual port with it.
    func setSecure(_ secure: Bool) {
        isSecure = secure
        if secure, port == "8123" { port = "8443" }
        if !secure, port == "8443" { port = "8123" }
    }

    func setSSH(_ on: Bool) {
        sshEnabled = on
        if on, sshUser.isEmpty { sshUser = NSUserName() }
    }

    /// A URL pasted: the form filled in from it.
    func applyURL() {
        guard url.contains(":"), let (endpoint, password) = CHEndpoint.parse(url) else { return }
        host = endpoint.host
        port = String(endpoint.port)
        isSecure = endpoint.isSecure
        user = endpoint.user
        database = endpoint.database
        if let password { self.password = password }
        // Without a name of one's own, the host's is suggested (the field's prompt).
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            namePrompt = Connections.shared.suggestedName(host: endpoint.host, except: id)
        }
    }

    /// Whether another connection has the name typed (a number will be added to this one's).
    var nameIsTaken: Bool {
        let typed = name.trimmingCharacters(in: .whitespaces)
        return !typed.isEmpty && Connections.shared.isNameTaken(typed, except: id)
    }

    /// An environment's mark in menus: drawn in its color (a menu draws symbols in one color).
    static func dot(_ color: NSColor?) -> NSImage {
        let image = NSImage(size: NSSize(width: 9, height: 9), flipped: false) { rect in
            if let color {
                color.setFill()
                NSBezierPath(ovalIn: rect).fill()
            } else {
                // No environment: a ring, so the titles stay in one column in the menu.
                NSColor.tertiaryLabelColor.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A host key's type and the end of its base64, enough to tell keys apart.
    static func shortKey(_ key: String) -> String {
        let parts = key.split(separator: " ")
        guard parts.count >= 2 else { return key }
        return "\(parts[0]) …\(parts[1].suffix(16))"
    }
}

/// A connection's settings as System Settings shows its own: grouped sections,
/// labels on the leading side, the actions under them.
struct ConnectionFormView: View {
    @Bindable var form: ConnectionForm
    @FocusState private var urlFocused: Bool

    var body: some View {
        if form.id == nil {
            ContentUnavailableView {
                Label("No Connection Selected", systemImage: "server.rack")
            } description: {
                Text("Select a connection in the list, or create a new one. A URL pasted into a new connection fills it in.")
            } actions: {
                Button("New Connection") { form.actions.new() }
            }
        } else {
            VStack(spacing: 0) {
                Form {
                    Section {
                        TextField("URL", text: $form.url, prompt: Text(String(localized: "Paste a URL: https://user:password@host:8443/database")))
                            .focused($urlFocused)
                            .onChange(of: form.url) { form.applyURL() }
                    } footer: {
                        Text("A URL pasted here fills in the fields below.").foregroundStyle(.secondary)
                    }
                    Section {
                        TextField("Name", text: $form.name, prompt: Text(form.namePrompt))
                        Picker("Environment", selection: Binding(get: { form.environment }, set: { form.setEnvironment($0) })) {
                            // The picker's bezel leaves more room before an icon (15 pt) than after its chevrons
                            // (9 pt): the labels give 6 back, so both sides are even.
                            Label {
                                Text("None")
                            } icon: {
                                Image(nsImage: ConnectionForm.dot(nil)).renderingMode(.original)
                            }
                            .padding(.leading, -6)
                            .tag(CHEnvironment?.none)
                            ForEach(CHEnvironment.allCases, id: \.self) { environment in
                                Label {
                                    Text(environment.title)
                                } icon: {
                                    Image(nsImage: ConnectionForm.dot(environment.color)).renderingMode(.original)
                                }
                                .padding(.leading, -6)
                                .tag(Optional(environment))
                            }
                        }
                        Toggle(isOn: $form.isReadOnly) {
                            Text("Read only")
                            Text("Runs no statements that change data.")
                        }
                    } header: {
                        Text("Connection")
                    } footer: {
                        if form.nameIsTaken {
                            Text("Another connection has this name: a number will be added to this one.").foregroundStyle(.red)
                        }
                    }
                    Section("Server") {
                        TextField("Host", text: $form.host, prompt: Text("localhost"))
                        TextField("Port", text: $form.port, prompt: Text(form.isSecure ? "8443" : "8123"))
                        Toggle("Use HTTPS", isOn: Binding(get: { form.isSecure }, set: { form.setSecure($0) }))
                        TextField("Database", text: $form.database, prompt: Text("the user's default"))
                        Picker("Compression", selection: $form.compression) {
                            Text("Automatic (none on a local network)").tag(CHCompression.automatic)
                            Text("LZ4").tag(CHCompression.lz4)
                            Text("None").tag(CHCompression.none)
                        }
                    }
                    Section("Authentication") {
                        TextField("User", text: $form.user, prompt: Text("default"))
                        SecureField("Password", text: $form.password)
                    }
                    Section {
                        Picker("Server certificate", selection: $form.trust) {
                            Text("Trusted by the system").tag(ConnectionForm.Trust.system)
                            Text("Only this certificate (SHA-256)").tag(ConnectionForm.Trust.pinned)
                            Text("Issued by an authority of mine").tag(ConnectionForm.Trust.authority)
                        }
                        if form.trust == .pinned {
                            TextField("SHA-256", text: $form.fingerprint, prompt: Text("The fingerprint of the server's certificate"))
                        }
                        if form.trust == .authority {
                            LabeledContent("Authority") {
                                HStack {
                                    Text(form.authorityName.isEmpty ? String(localized: "None chosen") : form.authorityName)
                                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    Button("Choose…") { form.actions.chooseAuthority() }
                                }
                            }
                        }
                        LabeledContent("Client certificate") {
                            HStack {
                                Text(form.clientCertificate ?? String(localized: "None"))
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Button("Choose…") { form.actions.chooseCertificate() }
                                if form.clientCertificate != nil {
                                    Button("Remove") { form.actions.removeCertificate() }
                                }
                            }
                        }
                    } header: {
                        Text("Certificates")
                    } footer: {
                        Text("A client certificate (.p12) is for servers that ask for one.").foregroundStyle(.secondary)
                    }
                    Section("SSH Tunnel") {
                        Toggle(isOn: Binding(get: { form.sshEnabled }, set: { form.setSSH($0) })) {
                            Text("Through an SSH server")
                            Text("The server's host and port are then as the SSH server reaches them.")
                        }
                        if form.sshEnabled {
                            TextField("SSH server", text: $form.sshHost, prompt: Text("bastion.example.com"))
                            TextField("Port", text: $form.sshPort, prompt: Text("22"))
                            TextField("User", text: $form.sshUser)
                            Picker("Sign in with", selection: $form.sshSignIn) {
                                Text("Password").tag(ConnectionForm.SSHSignIn.password)
                                Text("Private key (ed25519, ECDSA)").tag(ConnectionForm.SSHSignIn.key)
                            }
                            if form.sshSignIn == .password {
                                SecureField("SSH password", text: $form.sshPassword)
                            } else {
                                LabeledContent("Private key") {
                                    HStack {
                                        Text(form.pendingKey?.name ?? form.keyName ?? String(localized: "None chosen"))
                                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        Button("Choose…") { form.actions.chooseKey() }
                                    }
                                }
                            }
                            if let key = form.knownHostKey {
                                LabeledContent("Server's key") {
                                    HStack {
                                        Text(ConnectionForm.shortKey(key)).foregroundStyle(.secondary).lineLimit(1).help(key)
                                        Button("Forget") { form.actions.forgetHostKey() }
                                    }
                                }
                            }
                        }
                    }
                    Section {
                        Button("Delete Connection…", role: .destructive) { form.actions.delete() }
                    }
                }
                .formStyle(.grouped)
                actionBar
            }
            .onChange(of: form.focusURL) { urlFocused = true }
        }
    }

    /// The last message (its first paragraph, the whole in Details), Test and Connect.
    private var actionBar: some View {
        HStack(alignment: .center, spacing: 8) {
            if !form.status.isEmpty {
                Text(form.statusSummary)
                    .foregroundStyle(form.statusIsError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .help(form.status)
                if form.hasStatusDetails {
                    Button("Details…") { form.actions.showDetails() }
                        .buttonStyle(.link)
                }
            }
            Spacer(minLength: 12)
            Button("Test") { form.actions.test() }
                .disabled(form.isAttempting)
            Button(form.isAttempting ? String(localized: "Stop") : String(localized: "Connect")) { form.actions.connect() }
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
