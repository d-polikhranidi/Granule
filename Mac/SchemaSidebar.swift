import AppKit
import ClickHouseCore

/// The sidebar: the server's databases, their tables (engine, rows, size)
/// and, once a table is opened, its columns (type, keys, size and
/// compression). Double-click a table to see its rows.
final class SchemaSidebar: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var client: CHClient?
    /// A table to show the rows of.
    var onShowRows: (Schema.Table) -> Void = { _ in }
    /// A table's CREATE statement to show.
    var onShowCreate: (Schema.Table) -> Void = { _ in }
    /// A name to put in the editor.
    var onInsert: (String) -> Void = { _ in }
    /// A view of the server to show.
    var onShowView: (ServerView) -> Void = { _ in }

    private let outline = NSOutlineView()
    private let filterField = NSSearchField()
    private var schema = Schema()
    private var items: [Item] = []
    private var filter = ""

    /// A row of the sidebar.
    final class Item {
        enum Kind {
            case server
            case view(ServerView)
            case database(Schema.Database)
            case table(Schema.Table)
            case column(Schema.Column)
            case message(String)
        }

        let kind: Kind
        var children: [Item]?
        /// Its children are a placeholder until loaded (a table's columns).
        var needsLoad = false
        var isLoading = false

        init(_ kind: Kind, children: [Item]? = nil) {
            self.kind = kind
            self.children = children
        }
    }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked(_:))
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.autosaveExpandedItems = false
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        filterField.placeholderString = String(localized: "Filter tables")
        filterField.target = self
        filterField.action = #selector(filterChanged(_:))
        let stack = NSStackView(views: [filterField, scroll])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Below the title bar (the window's content goes under it).
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        view = container
    }

    /// The databases and tables read again.
    func reload() {
        guard let client else { return }
        items = [Item(.message(String(localized: "Loading…")))]
        outline.reloadData()
        Task {
            do {
                schema = try await Schema.load(client)
                rebuild()
            } catch {
                items = [Item(.message(error.viewerDescription))]
                outline.reloadData()
            }
        }
    }

    private func rebuild() {
        let words = filter.lowercased()
        let server = Item(.server, children: ServerView.allCases.map { Item(.view($0)) })
        items = [server] + schema.databases.compactMap { database in
            let tables = words.isEmpty ? database.tables : database.tables.filter { $0.name.lowercased().contains(words) }
            guard words.isEmpty || !tables.isEmpty || database.name.lowercased().contains(words) else { return nil }
            var shown = database
            shown.tables = tables
            return Item(.database(shown), children: tables.map { Item(.table($0)) })
        }
        outline.reloadData()
        if words.isEmpty, !serverCollapsed { outline.expandItem(server) }
        // The user's databases open; the system's closed (or all open while filtering).
        for item in items {
            if case .database(let database) = item.kind, !database.isSystem || !words.isEmpty || items.count == 1 {
                outline.expandItem(item)
            }
        }
    }

    /// Whether the user closed the Server section (it stays closed on reloads).
    private var serverCollapsed: Bool {
        get { UserDefaults.standard.bool(forKey: "ServerSectionCollapsed") }
        set { UserDefaults.standard.set(newValue, forKey: "ServerSectionCollapsed") }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? Item, case .server = item.kind { serverCollapsed = true }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? Item, case .server = item.kind { serverCollapsed = false }
    }

    @objc private func filterChanged(_ sender: Any?) {
        filter = filterField.stringValue.trimmingCharacters(in: .whitespaces)
        rebuild()
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? Item else { return items.count }
        if item.children == nil, isExpandable(item) {
            // One placeholder (the same object each time the outline asks) until loaded.
            item.children = [Item(.message(String(localized: "Loading…")))]
            item.needsLoad = true
        }
        return item.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? Item else { return items[index] }
        return item.children?[index] ?? Item(.message(""))
    }

    private func isExpandable(_ item: Item) -> Bool {
        switch item.kind {
        case .server, .database, .table: true
        default: false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? Item else { return false }
        return isExpandable(item)
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? Item, case .table(let table) = item.kind,
              item.needsLoad, !item.isLoading, let client else { return }
        item.isLoading = true
        Task {
            do {
                let columns = try await Schema.columns(of: table, client: client)
                item.children = columns.map { Item(.column($0)) }
            } catch {
                item.children = [Item(.message(error.viewerDescription))]
            }
            item.isLoading = false
            item.needsLoad = false
            outline.reloadItem(item, reloadChildren: true)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item else { return nil }
        let title: String, detail: String, symbol: String?
        var toolTip: String?
        switch item.kind {
        case .server:
            title = String(localized: "Server")
            detail = ""
            symbol = "server.rack"
        case .view(let view):
            title = view.title
            detail = view.isLive ? String(localized: "live") : ""
            symbol = view.symbol
        case .database(let database):
            title = database.name
            detail = database.tables.count.formatted()
            symbol = database.isSystem ? "gearshape" : "cylinder"
        case .table(let table):
            title = table.name
            detail = table.detail
            symbol = table.isView ? "eye" : table.engine == "Dictionary" ? "book.closed" : "tablecells"
            toolTip = [table.engine, table.comment].filter { !$0.isEmpty }.joined(separator: "\n")
        case .column(let column):
            title = column.name
            var parts = [column.type]
            if !column.defaultKind.isEmpty { parts.append(column.defaultKind) }
            detail = parts.joined(separator: " · ")
            symbol = column.isInPrimaryKey ? "key" : column.isInSortingKey ? "arrow.up.arrow.down" : nil
            toolTip = [column.type, column.defaultKind.isEmpty ? "" : "\(column.defaultKind) \(column.defaultExpression)",
                       column.sizeText ?? "", column.comment].filter { !$0.isEmpty }.joined(separator: "\n")
        case .message(let text):
            title = text
            detail = ""
            symbol = nil
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: title)
        label.lineBreakMode = .byTruncatingTail
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        var views: [NSView] = []
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let icon = NSImageView(image: image)
            icon.contentTintColor = .secondaryLabelColor
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            views.append(icon)
        }
        views += [label, detailLabel]
        let stack = NSStackView(views: views)
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        cell.textField = label
        cell.toolTip = toolTip
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private var clickedItem: Item? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return outline.item(atRow: row) as? Item
    }

    @objc private func clicked(_ sender: Any?) {
        guard let item = clickedItem, case .view(let view) = item.kind else { return }
        onShowView(view)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let item = clickedItem else { return }
        switch item.kind {
        case .table(let table): onShowRows(table)
        case .column(let column): onInsert(CHSQL.quotedName(column.name))
        default: break
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = clickedItem else { return }
        func add(_ title: String, _ action: @escaping () -> Void) {
            let menuItem = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = action
            menu.addItem(menuItem)
        }
        switch item.kind {
        case .database(let database):
            add(String(localized: "Insert Name")) { [weak self] in self?.onInsert(CHSQL.quotedName(database.name)) }
            add(String(localized: "Copy Name")) { Self.copy(database.name) }
        case .table(let table):
            add(String(localized: "Show Rows")) { [weak self] in self?.onShowRows(table) }
            add(String(localized: "Show CREATE Statement")) { [weak self] in self?.onShowCreate(table) }
            menu.addItem(.separator())
            add(String(localized: "Insert Name")) { [weak self] in self?.onInsert(table.qualifiedName) }
            add(String(localized: "Copy Name")) { Self.copy(table.qualifiedName) }
        case .column(let column):
            add(String(localized: "Insert Name")) { [weak self] in self?.onInsert(CHSQL.quotedName(column.name)) }
            add(String(localized: "Copy Name")) { Self.copy(column.name) }
        case .view(let view):
            add(String(localized: "Show")) { [weak self] in self?.onShowView(view) }
            add(String(localized: "Insert Statement")) { [weak self] in self?.onInsert(view.sql) }
        case .server, .message:
            break
        }
        menu.addItem(.separator())
        add(String(localized: "Refresh")) { [weak self] in self?.reload() }
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
