import ClickHouseCore
import UIKit

/// The sidebar: databases, their tables (rows, size) and, once a table is
/// opened, its columns. Tap a table to see its rows; long press for more.
final class SchemaViewController: UICollectionViewController, UISearchResultsUpdating {
    private let client: CHClient
    var onShowRows: (Schema.Table) -> Void = { _ in }
    var onShowCreate: (Schema.Table) -> Void = { _ in }
    var onInsert: (String) -> Void = { _ in }
    var onShowView: (ServerView) -> Void = { _ in }

    /// A row of the outline (unique ids: the same column name in two tables are two rows).
    nonisolated struct Node: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            case server
            case view(ServerView)
            case database(Schema.Database)
            case table(Schema.Table)
            case column(Schema.Column)
            case message(String)
        }

        let id = UUID()
        let kind: Kind

        static func == (lhs: Node, rhs: Node) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private var dataSource: UICollectionViewDiffableDataSource<Int, Node>!
    private var schema = Schema()
    private var filter = ""
    private var loaded = Set<UUID>()

    init(client: CHClient) {
        self.client = client
        let configuration = UICollectionLayoutListConfiguration(appearance: .sidebar)
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Schema")
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .refresh, primaryAction: UIAction { [weak self] _ in self?.reload() })
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Filter tables")
        search.searchBar.autocapitalizationType = .none
        navigationItem.searchController = search

        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Node> { cell, _, node in
            var content = cell.defaultContentConfiguration()
            switch node.kind {
            case .server:
                content.text = String(localized: "Server")
                content.image = UIImage(systemName: "server.rack")
                cell.accessories = [.outlineDisclosure()]
            case .view(let view):
                content.text = view.title
                content.secondaryText = view.isLive ? String(localized: "live") : nil
                content.image = UIImage(systemName: view.symbol)
                cell.accessories = []
            case .database(let database):
                content.text = database.name
                content.secondaryText = database.tables.count.formatted()
                content.image = UIImage(systemName: database.isSystem ? "gearshape" : "cylinder")
                cell.accessories = [.outlineDisclosure()]
            case .table(let table):
                content.text = table.name
                content.secondaryText = table.detail
                content.image = UIImage(systemName: table.isView ? "eye" : "tablecells")
                // The chevron opens the columns; a tap on the row shows its rows.
                cell.accessories = [.outlineDisclosure(options: .init(style: .header)) { [weak self] in self?.toggle(node) }]
            case .column(let column):
                content.text = column.name
                content.secondaryText = [column.type, column.sizeText ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                content.image = column.isInPrimaryKey ? UIImage(systemName: "key") : nil
                cell.accessories = []
            case .message(let text):
                content.text = text
                content.textProperties.color = .secondaryLabel
                cell.accessories = []
            }
            content.secondaryTextProperties.color = .secondaryLabel
            content.prefersSideBySideTextAndSecondaryText = true
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, node in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: node)
        }
        var handlers = UICollectionViewDiffableDataSource<Int, Node>.SectionSnapshotHandlers<Node>()
        handlers.willExpandItem = { [weak self] node in self?.loadColumns(of: node) }
        dataSource.sectionSnapshotHandlers = handlers
        show([Node(kind: .message(String(localized: "Connecting…")))])
    }

    private func show(_ nodes: [Node]) {
        var snapshot = NSDiffableDataSourceSectionSnapshot<Node>()
        snapshot.append(nodes)
        dataSource.apply(snapshot, to: 0, animatingDifferences: false, completion: nil)
    }

    func reload() {
        // (On an iPhone the sidebar's view loads when it's first shown.)
        loadViewIfNeeded()
        show([Node(kind: .message(String(localized: "Loading…")))])
        Task {
            do {
                schema = try await Schema.load(client)
                rebuild()
            } catch {
                show([Node(kind: .message(error.viewerDescription))])
            }
        }
    }

    private func rebuild() {
        loaded = []
        let words = filter.lowercased()
        var snapshot = NSDiffableDataSourceSectionSnapshot<Node>()
        if words.isEmpty {
            let server = Node(kind: .server)
            snapshot.append([server])
            snapshot.append(ServerView.allCases.map { Node(kind: .view($0)) }, to: server)
            snapshot.expand([server])
        }
        for database in schema.databases {
            let tables = words.isEmpty ? database.tables : database.tables.filter { $0.name.lowercased().contains(words) }
            guard words.isEmpty || !tables.isEmpty else { continue }
            let node = Node(kind: .database(database))
            snapshot.append([node])
            let tableNodes = tables.map { Node(kind: .table($0)) }
            snapshot.append(tableNodes, to: node)
            // A placeholder under each table until it's opened.
            for table in tableNodes { snapshot.append([Node(kind: .message(String(localized: "Loading…")))], to: table) }
            if !database.isSystem || !words.isEmpty { snapshot.expand([node]) }
        }
        dataSource.apply(snapshot, to: 0, animatingDifferences: false, completion: nil)
    }

    private func toggle(_ node: Node) {
        var snapshot = dataSource.snapshot(for: 0)
        if snapshot.isExpanded(node) {
            snapshot.collapse([node])
        } else {
            snapshot.expand([node])
            loadColumns(of: node)
        }
        dataSource.apply(snapshot, to: 0, animatingDifferences: true, completion: nil)
    }

    private func loadColumns(of node: Node) {
        guard case .table(let table) = node.kind, !loaded.contains(node.id) else { return }
        loaded.insert(node.id)
        Task {
            let children: [Node]
            do {
                children = try await Schema.columns(of: table, client: client).map { Node(kind: .column($0)) }
            } catch {
                children = [Node(kind: .message(error.viewerDescription))]
            }
            var snapshot = dataSource.snapshot(for: 0)
            guard snapshot.contains(node) else { return }
            snapshot.delete(snapshot.snapshot(of: node, includingParent: false).items)
            snapshot.append(children, to: node)
            dataSource.apply(snapshot, to: 0, animatingDifferences: false, completion: nil)
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        filter = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        if !schema.databases.isEmpty { rebuild() }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let node = dataSource.itemIdentifier(for: indexPath) else { return }
        collectionView.deselectItem(at: indexPath, animated: true)
        switch node.kind {
        case .view(let view): onShowView(view)
        case .table(let table): onShowRows(table)
        case .column(let column): onInsert(CHSQL.quotedName(column.name))
        default: break
        }
    }

    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                                 point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let node = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            switch node.kind {
            case .table(let table):
                return UIMenu(children: [
                    UIAction(title: String(localized: "Show Rows"), image: UIImage(systemName: "tablecells")) { _ in self.onShowRows(table) },
                    UIAction(title: String(localized: "Show CREATE Statement"), image: UIImage(systemName: "doc.plaintext")) { _ in self.onShowCreate(table) },
                    UIAction(title: String(localized: "Insert Name"), image: UIImage(systemName: "text.insert")) { _ in self.onInsert(table.qualifiedName) },
                    UIAction(title: String(localized: "Copy Name"), image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = table.qualifiedName },
                ])
            case .database(let database):
                return UIMenu(children: [
                    UIAction(title: String(localized: "Insert Name"), image: UIImage(systemName: "text.insert")) { _ in self.onInsert(CHSQL.quotedName(database.name)) },
                ])
            case .column(let column):
                return UIMenu(children: [
                    UIAction(title: String(localized: "Insert Name"), image: UIImage(systemName: "text.insert")) { _ in self.onInsert(CHSQL.quotedName(column.name)) },
                    UIAction(title: String(localized: "Copy Name"), image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = column.name },
                ])
            case .view(let view):
                return UIMenu(children: [
                    UIAction(title: String(localized: "Show"), image: UIImage(systemName: view.symbol)) { _ in self.onShowView(view) },
                    UIAction(title: String(localized: "Insert Statement"), image: UIImage(systemName: "text.insert")) { _ in self.onInsert(view.sql) },
                ])
            case .server, .message:
                return nil
            }
        })
    }
}
