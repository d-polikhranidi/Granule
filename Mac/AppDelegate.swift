import AppKit
import SwiftUI
import ClickHouseCore
import Gingham

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var connections: ConnectionsWindowController?
    private var queryWindows: [QueryWindowController] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        GinghamKey.register()
        NSApp.mainMenu = mainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // `-ViewerSettings YES`: the Settings window at launch, its number printed.
        if UserDefaults.standard.bool(forKey: "ViewerSettings") {
            showSettings(nil)
            if let number = settings?.window?.windowNumber { FileHandle.standardError.write(Data("VIEWER-WINDOW \(number)\n".utf8)) }
            return
        }
        // `-ViewerAppearance dark|light`: the app in that appearance (screenshots of both).
        if let name = UserDefaults.standard.string(forKey: "ViewerAppearance") {
            NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
        }
        // `-ViewerURL <url>`: a window on that server at launch (not saved); `-ViewerRun <SQL>` run in it.
        if let url = UserDefaults.standard.string(forKey: "ViewerURL"), var (endpoint, password) = CHEndpoint.parse(url) {
            endpoint.id = Connections.debugID(for: url)
            Connections.debugBastion(for: &endpoint)
            // `-ViewerEnvironment production`: that server's environment (its tag and tint).
            endpoint.environment = UserDefaults.standard.string(forKey: "ViewerEnvironment").flatMap(CHEnvironment.init(rawValue:))
            let controller = QueryWindowController(endpoint: endpoint, password: password ?? "")
            controller.onNewTab = { [weak self] from in self?.open(from.endpoint, password: from.password, tabOf: from) }
            queryWindows.append(controller)
            controller.showWindow(nil)
            controller.connect()
            return
        }
        #if DEBUG
        // `-ViewerImport <file>`: clickhouse-client's configuration imported (into the checks' own list).
        if let path = UserDefaults.standard.string(forKey: "ViewerImport") {
            showConnections(nil)
            connections?.importConnections(from: URL(fileURLWithPath: path))
            return
        }
        #endif
        // `-ViewerConnect <name>`: that saved connection's window at launch.
        if let name = UserDefaults.standard.string(forKey: "ViewerConnect"),
           let endpoint = Connections.shared.endpoints.first(where: { $0.title == name || $0.name == name }) {
            open(endpoint)
            return
        }
        #endif
        showConnections(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showConnections(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// The window of connections (File > Connections…).
    @objc func showConnections(_ sender: Any?) {
        if connections == nil {
            // A connection that worked takes the place of the connections window.
            connections = ConnectionsWindowController { [weak self] endpoint, client in
                self?.open(endpoint, password: Connections.shared.password(for: endpoint), tabOf: nil, client: client)
                self?.connections?.close()
            }
        }
        connections?.showWindow(sender)
        connections?.window?.makeKeyAndOrderFront(sender)
    }

    private var settings: SettingsWindowController?

    /// Settings (⌘,): the editor's and the result's appearance.
    @objc func showSettings(_ sender: Any?) {
        if settings == nil { settings = SettingsWindowController() }
        settings?.showWindow(sender)
        settings?.window?.makeKeyAndOrderFront(sender)
    }

    /// File > Import from clickhouse-client…: in the connections window.
    @objc func importConnections(_ sender: Any?) {
        showConnections(sender)
        connections?.importFromClient(sender)
    }

    /// The connections window with a new connection in its form.
    @objc func newConnection(_ sender: Any?) {
        showConnections(sender)
        connections?.addConnection(sender)
    }

    /// A window of queries on a server.
    func open(_ endpoint: CHEndpoint) {
        open(endpoint, password: Connections.shared.password(for: endpoint), tabOf: nil)
    }

    /// A window of queries on a server, as a tab of another one's window if given.
    /// `client`: one already connected (Connect checked it), else the window connects its own.
    private func open(_ endpoint: CHEndpoint, password: String, tabOf other: QueryWindowController?, client: CHClient? = nil) {
        // The server's tabs are numbered: each keeps its editor's text.
        let used = Set(queryWindows.filter { $0.endpoint.id == endpoint.id }.map(\.tabNumber))
        let number = (0...).first { !used.contains($0) } ?? 0
        let controller = QueryWindowController(endpoint: endpoint, password: password, tabNumber: number, client: client)
        controller.onClose = { [weak self, weak controller] in
            guard let self else { return }
            queryWindows.removeAll { $0 === controller }
            // The last server's window closed: the connections again, to pick the next.
            if queryWindows.isEmpty { showConnections(nil) }
        }
        controller.onNewTab = { [weak self] from in self?.open(from.endpoint, password: from.password, tabOf: from) }
        queryWindows.append(controller)
        if let other, let window = controller.window, let otherWindow = other.window {
            otherWindow.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        } else {
            controller.showWindow(nil)
        }
        controller.connect()
    }

    private func mainMenu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        @discardableResult
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            items.forEach(submenu.addItem)
            item.submenu = submenu
            menu.addItem(item)
            return submenu
        }
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Granule"
        submenu(name, [
            item(String(localized: "About \(name)"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item(String(localized: "Settings…"), #selector(showSettings(_:)), ","),
            .separator(),
            item(String(localized: "Hide \(name)"), #selector(NSApplication.hide(_:)), "h"),
            item(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(String(localized: "Quit \(name)"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu(String(localized: "File"), [
            item(String(localized: "New Connection…"), #selector(newConnection(_:)), "n"),
            item(String(localized: "Import from clickhouse-client…"), #selector(importConnections(_:)), ""),
            item(String(localized: "Connections…"), #selector(showConnections(_:)), "n", [.command, .shift]),
            item(String(localized: "New Tab"), #selector(NSResponder.newWindowForTab(_:)), "t"),
            .separator(),
            item(String(localized: "Close"), #selector(NSWindow.performClose(_:)), "w"),
            item(String(localized: "Export…"), #selector(QueryWindowController.exportResult(_:)), "e"),
            item(String(localized: "Export Shown Rows…"), #selector(QueryWindowController.exportShownRows(_:)), "e", [.command, .option]),
        ])
        submenu(String(localized: "Edit"), [
            item(String(localized: "Undo"), Selector(("undo:")), "z"),
            item(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"),
            // The rows Gingham's way in the table, the text elsewhere.
            item(String(localized: "Copy"), #selector(QueryWindowController.copyRows(_:)), "c"),
            item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"),
            item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item(String(localized: "Find in Result…"), #selector(QueryWindowController.showSearch(_:)), "f"),
        ])
        submenu(String(localized: "Query"), [
            item(String(localized: "Run Statement"), #selector(QueryWindowController.runStatement(_:)), "\r"),
            item(String(localized: "Run All Statements"), #selector(QueryWindowController.runAllStatements(_:)), "\r", [.command, .shift]),
            item(String(localized: "Stop"), #selector(QueryWindowController.stopQuery(_:)), "."),
            item(String(localized: "Check Statement"), #selector(QueryWindowController.checkStatement(_:)), "b"),
            item(String(localized: "Format Statement"), #selector(QueryWindowController.formatStatement(_:)), "f", [.control, .shift]),
            item(String(localized: "Query Details"), #selector(QueryWindowController.showQueryDetails(_:)), "d", [.command, .option]),
            .separator(),
            item(String(localized: "Save Query…"), #selector(QueryWindowController.saveQuery(_:)), "s"),
            item(String(localized: "Saved Queries and History…"), #selector(QueryWindowController.showQueryLibrary(_:)), "y"),
            .separator(),
            {
                let explain = item(String(localized: "Explain Plan"), #selector(QueryWindowController.explainStatement(_:)), "\r", [.command, .option])
                explain.tag = 0
                return explain
            }(),
            {
                let explain = item(String(localized: "Explain Plan as Text"), #selector(QueryWindowController.explainStatement(_:)))
                explain.tag = 4
                return explain
            }(),
            {
                let explain = item(String(localized: "Explain Pipeline"), #selector(QueryWindowController.explainStatement(_:)))
                explain.tag = 1
                return explain
            }(),
            {
                let explain = item(String(localized: "Explain Pipeline as Text"), #selector(QueryWindowController.explainStatement(_:)))
                explain.tag = 5
                return explain
            }(),
            {
                let explain = item(String(localized: "Explain Estimate (parts, rows, marks)"), #selector(QueryWindowController.explainStatement(_:)))
                explain.tag = 2
                return explain
            }(),
            {
                let explain = item(String(localized: "Explain Syntax"), #selector(QueryWindowController.explainStatement(_:)))
                explain.tag = 3
                return explain
            }(),
            .separator(),
            item(String(localized: "Show Value"), #selector(QueryWindowController.showValue(_:)), " ", [.command]),
            item(String(localized: "Refresh Schema"), #selector(QueryWindowController.refreshSchema(_:)), "r", [.command, .shift]),
        ])
        submenu(String(localized: "View"), [
            item(String(localized: "Show Sidebar"), #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item(String(localized: "Show Chart"), #selector(QueryWindowController.toggleChart(_:)), "k", [.command, .shift]),
            item(String(localized: "Show Inspector"), #selector(NSSplitViewController.toggleInspector(_:)), "i", [.command, .option]),
        ])
        NSApp.windowsMenu = submenu(String(localized: "Window"), [
            item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
        ])
        return menu
    }
}

// MARK: - Settings

/// The Settings window: its panes in a preference toolbar (Queries, Appearance), its
/// title the pane's, as the HIG asks; the pane chosen last opens again.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private struct Pane {
        let id: NSToolbarItem.Identifier
        let title: String
        let symbol: String
        let content: () -> NSViewController
    }

    private let panes = [
        Pane(id: .init("queries"), title: String(localized: "Queries"), symbol: "gauge.with.dots.needle.67percent") {
            let hosting = NSHostingController(rootView: QuerySettingsView())
            hosting.sizingOptions = [.preferredContentSize]
            return hosting
        },
        Pane(id: .init("appearance"), title: String(localized: "Appearance"), symbol: "paintpalette") {
            let hosting = NSHostingController(rootView: AppearanceSettingsView())
            hosting.sizingOptions = [.preferredContentSize]
            return hosting
        },
    ]

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400), styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.delegate = self
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        // Where it was (its top left: the panes' heights differ).
        let placed = window.setFrameUsingName("Settings")
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        let saved = UserDefaults.standard.string(forKey: "SettingsPane")
        show(panes.first { $0.id.rawValue == saved } ?? panes[1])
        if placed { window.setFrameTopLeftPoint(topLeft) } else { window.center() }
        window.setFrameAutosaveName("Settings")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A pane in the window, its top edge kept where it is.
    private func show(_ pane: Pane) {
        guard let window else { return }
        let top = window.frame.maxY
        window.contentViewController = pane.content()
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
        window.title = pane.title
        window.toolbar?.selectedItemIdentifier = pane.id
        UserDefaults.standard.set(pane.id.rawValue, forKey: "SettingsPane")
    }

    @objc private func choosePane(_ item: NSToolbarItem) {
        guard let pane = panes.first(where: { $0.id == item.itemIdentifier }), window?.title != pane.title else { return }
        show(pane)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { panes.map(\.id) }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { panes.map(\.id) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { panes.map(\.id) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = panes.first(where: { $0.id == identifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(choosePane(_:))
        return item
    }
}

