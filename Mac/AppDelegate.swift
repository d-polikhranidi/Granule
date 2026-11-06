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
        let name = "Clickhouse Viewer"
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

/// The Settings window: its panes in a preference toolbar (Appearance, for now),
/// its title the pane's, as the HIG asks.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private static let appearanceItem = NSToolbarItem.Identifier("appearance")

    init() {
        let hosting = NSHostingController(rootView: AppearanceSettingsView())
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = String(localized: "Appearance")
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.delegate = self
        toolbar.selectedItemIdentifier = Self.appearanceItem
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        window.setFrameAutosaveName("Settings")
        if !window.setFrameUsingName("Settings") { window.center() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.appearanceItem] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.appearanceItem] }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.appearanceItem] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = String(localized: "Appearance")
        item.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: item.label)
        return item
    }
}

/// Settings > Appearance. The windows follow the system's Light, Dark or Auto;
/// here are the editor's and the result's own looks.
struct AppearanceSettingsView: View {
    @AppStorage("EditorTheme") private var theme = EditorTheme.standard.rawValue
    @AppStorage("EditorFontSize") private var editorFontSize = 13.0
    @AppStorage("ResultFontSize") private var resultFontSize = 0.0
    @AppStorage("ResultDensity") private var density = "regular"
    @AppStorage("ResultAlternatingRows") private var alternatingRows = true
    @AppStorage("DarkContentBackground") private var darkContent = false

    private static let sample = "SELECT country, count() AS visits -- this month\nFROM events\nWHERE event_time >= {since:DateTime} AND url LIKE '%/page/%'\nGROUP BY country ORDER BY visits DESC LIMIT 10"

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $darkContent) {
                    Text("Dark background for the editor and results")
                    Text("The windows themselves follow System Settings › Appearance (Light, Dark or Auto).")
                }
            }
            Section("Editor") {
                Picker("Theme", selection: $theme) {
                    ForEach(EditorTheme.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                Stepper(value: $editorFontSize, in: 10...24, step: 1) {
                    LabeledContent("Font size", value: String(localized: "\(Int(editorFontSize)) pt"))
                }
                preview
            }
            Section("Results") {
                Picker("Text size", selection: $resultFontSize) {
                    Text("System").tag(0.0)
                    ForEach([11.0, 12, 13, 14, 15, 16, 18], id: \.self) { Text(String(localized: "\(Int($0)) pt")).tag($0) }
                }
                Picker("Rows", selection: $density) {
                    Text("Compact").tag("compact")
                    Text("Regular").tag("regular")
                    Text("Spacious").tag("spacious")
                }
                .pickerStyle(.segmented)
                Toggle("Alternating row backgrounds", isOn: $alternatingRows)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: theme) { changed() }
        .onChange(of: editorFontSize) { changed() }
        .onChange(of: resultFontSize) { changed() }
        .onChange(of: density) { changed() }
        .onChange(of: alternatingRows) { changed() }
        .onChange(of: darkContent) { changed() }
    }

    /// The theme on a statement, as the editor will show it.
    private var preview: some View {
        let storage = NSTextStorage(string: Self.sample)
        SQLHighlighting.apply(to: storage)
        let background = EditorTheme(rawValue: theme)?.background
        return Text(AttributedString(storage))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(background.map { Color(nsColor: $0) } ?? Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
            .environment(\.colorScheme, darkContent ? .dark : (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light))
            .id("\(theme)\(editorFontSize)\(darkContent)")
    }

    private func changed() {
        NotificationCenter.default.post(name: AppearanceSettings.didChange, object: nil)
    }
}

