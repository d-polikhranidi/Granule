import AppKit
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
        // `-ViewerURL <url>`: a window on that server at launch (not saved); `-ViewerRun <SQL>` run in it.
        if let url = UserDefaults.standard.string(forKey: "ViewerURL"), var (endpoint, password) = CHEndpoint.parse(url) {
            Connections.debugBastion(for: &endpoint)
            let controller = QueryWindowController(endpoint: endpoint, password: password ?? "")
            controller.onNewTab = { [weak self] from in self?.open(from.endpoint, password: from.password, tabOf: from) }
            queryWindows.append(controller)
            controller.showWindow(nil)
            controller.connect()
            return
        }
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
            connections = ConnectionsWindowController { [weak self] endpoint in self?.open(endpoint) }
        }
        connections?.showWindow(sender)
        connections?.window?.makeKeyAndOrderFront(sender)
    }

    /// A window of queries on a server.
    func open(_ endpoint: CHEndpoint) {
        open(endpoint, password: Connections.shared.password(for: endpoint), tabOf: nil)
    }

    /// A window of queries on a server, as a tab of another one's window if given.
    private func open(_ endpoint: CHEndpoint, password: String, tabOf other: QueryWindowController?) {
        // The server's tabs are numbered: each keeps its editor's text.
        let used = Set(queryWindows.filter { $0.endpoint.id == endpoint.id }.map(\.tabNumber))
        let number = (0...).first { !used.contains($0) } ?? 0
        let controller = QueryWindowController(endpoint: endpoint, password: password, tabNumber: number)
        controller.onClose = { [weak self, weak controller] in self?.queryWindows.removeAll { $0 === controller } }
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
        let name = "Clickhouse Viewer"
        submenu(name, [
            item(String(localized: "About \(name)"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item(String(localized: "Hide \(name)"), #selector(NSApplication.hide(_:)), "h"),
            item(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(String(localized: "Quit \(name)"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu(String(localized: "File"), [
            item(String(localized: "Connections…"), #selector(showConnections(_:)), "n", [.command, .shift]),
            item(String(localized: "New Tab"), #selector(NSResponder.newWindowForTab(_:)), "t"),
            .separator(),
            item(String(localized: "Close"), #selector(NSWindow.performClose(_:)), "w"),
            item(String(localized: "Export…"), #selector(QueryWindowController.exportResult(_:)), "e"),
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
            item(String(localized: "Stop"), #selector(QueryWindowController.stopQuery(_:)), "."),
            item(String(localized: "Check Statement"), #selector(QueryWindowController.checkStatement(_:)), "b"),
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
