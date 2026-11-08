import ClickHouseCore
import UIKit
import UniformTypeIdentifiers

/// The servers the user added: tap one to open it, swipe to edit or remove,
/// + to add one (a URL pasted fills its form in). On the iPad a connection
/// opens in a window of its own too (its menu, or dragged out of the list).
final class ConnectionsViewController: UICollectionViewController, UICollectionViewDragDelegate, UIDocumentPickerDelegate {
    private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!
    /// The connection this window shows, if one is open (its window is restored to it).
    private(set) var shownEndpoint: CHEndpoint?

    /// A window on one connection, as the system keeps and hands it back.
    static let activityType = "by.digitalglobe.Clickhouse-Viewer.connection"

    static func activity(for endpoint: CHEndpoint) -> NSUserActivity {
        let activity = NSUserActivity(activityType: activityType)
        activity.title = endpoint.title
        activity.userInfo = ["id": endpoint.id.uuidString]
        activity.targetContentIdentifier = endpoint.id.uuidString
        return activity
    }

    /// The saved connection an activity is for.
    static func endpoint(of activity: NSUserActivity?) -> CHEndpoint? {
        guard let activity, activity.activityType == activityType, let text = activity.userInfo?["id"] as? String,
              let id = UUID(uuidString: text) else { return nil }
        return Connections.shared.endpoints.first { $0.id == id }
    }

    init() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.trailingSwipeActionsConfigurationProvider = { _ in nil }
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        var withActions = configuration
        withActions.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in self?.swipeActions(at: indexPath) }
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout.list(using: withActions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Connections")
        navigationController?.navigationBar.prefersLargeTitles = true
        // A new connection, or those of clickhouse-client's configuration.
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, menu: UIMenu(children: [
            UIAction(title: String(localized: "New Connection"), image: UIImage(systemName: "plus")) { [weak self] _ in self?.edit(nil) },
            UIAction(title: String(localized: "Import from clickhouse-client…"), image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                self?.importFromClient(nil)
            },
        ]))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: String(localized: "Settings"), image: UIImage(systemName: "gearshape"),
                                                           primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            AppDelegate.presentSettings(from: self)
        })
        // (Weakly: the data source, the controller's, keeps the registration.)
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, UUID> { [weak self] cell, _, id in
            guard let endpoint = Connections.shared.endpoints.first(where: { $0.id == id }) else { return }
            var content = cell.defaultContentConfiguration()
            content.text = endpoint.title
            content.secondaryText = [endpoint.environment?.title, "\(endpoint.host):\(endpoint.port)",
                                     endpoint.isReadOnly ? String(localized: "read only") : nil].compactMap { $0 }.joined(separator: " · ")
            content.image = UIImage(systemName: endpoint.isCloud ? "cloud" : "server.rack")
            // The environment's color says what the server is for.
            content.imageProperties.tintColor = endpoint.environment?.color
            cell.contentConfiguration = content
            cell.accessories = [.detail { [weak self] in self?.edit(endpoint) }]
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        Connections.shared.onChange.append { [weak self] in self?.reload() }
        collectionView.dragDelegate = self
        // An empty list (the first launch) offers a new connection and the public playground.
        reload()
    }

    private func reload() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(Connections.shared.endpoints.map(\.id))
        snapshot.reconfigureItems(Connections.shared.endpoints.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: false)
        if Connections.shared.endpoints.isEmpty {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: "server.rack")
            empty.text = String(localized: "No Connections")
            empty.secondaryText = String(localized: "Add a ClickHouse server: a URL pasted into the form fills it in. Or try the app on ClickHouse's public playground, read only.")
            var button = UIButton.Configuration.borderedProminent()
            button.title = String(localized: "Add Connection")
            empty.button = button
            empty.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.edit(nil) }
            var playground = UIButton.Configuration.plain()
            playground.title = String(localized: "Try the Public Playground")
            empty.secondaryButton = playground
            empty.secondaryButtonProperties.primaryAction = UIAction { [weak self] _ in
                self?.open(Connections.shared.addPlayground(), password: "")
            }
            contentUnavailableConfiguration = empty
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    /// File > New Connection (⌘N), from wherever the window is.
    @objc func newConnection(_ sender: Any?) {
        var top: UIViewController = self
        while let presented = top.presentedViewController { top = presented }
        top.present(UINavigationController(rootViewController: ConnectionFormViewController(endpoint: CHEndpoint(name: ""), isNew: true)), animated: true)
    }

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let endpoint = Connections.shared.endpoints.first(where: { $0.id == id }) else {
            return nil
        }
        let remove = UIContextualAction(style: .destructive, title: String(localized: "Remove")) { _, _, done in
            Connections.shared.remove(endpoint)
            done(true)
        }
        let edit = UIContextualAction(style: .normal, title: String(localized: "Edit")) { [weak self] _, _, done in
            self?.edit(endpoint)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove, edit])
    }

    /// A connection's menu: Connect, Open in New Window (where there can be more than one), Edit, Remove.
    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                                 point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let id = dataSource.itemIdentifier(for: indexPath),
              let endpoint = Connections.shared.endpoints.first(where: { $0.id == id }) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            var actions: [UIMenuElement] = [
                UIAction(title: String(localized: "Connect"), image: UIImage(systemName: "bolt.horizontal")) { _ in
                    self?.open(endpoint, password: Connections.shared.password(for: endpoint))
                },
            ]
            if UIApplication.shared.supportsMultipleScenes {
                actions.append(UIAction(title: String(localized: "Open in New Window"), image: UIImage(systemName: "macwindow.badge.plus")) { _ in
                    Self.openInNewWindow(endpoint)
                })
            }
            actions.append(UIAction(title: String(localized: "Edit"), image: UIImage(systemName: "pencil")) { _ in self?.edit(endpoint) })
            actions.append(UIAction(title: String(localized: "Remove"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                Connections.shared.remove(endpoint)
            })
            return UIMenu(children: actions)
        })
    }

    /// A window of its own for a connection, connected there.
    static func openInNewWindow(_ endpoint: CHEndpoint) {
        let request = UISceneSessionActivationRequest(role: .windowApplication, userActivity: activity(for: endpoint))
        UIApplication.shared.activateSceneSession(for: request)
    }

    /// A connection dragged out of the list: dropped at the screen's edge, it opens in a new window.
    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: any UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard let id = dataSource.itemIdentifier(for: indexPath), let endpoint = Connections.shared.endpoints.first(where: { $0.id == id }) else {
            return []
        }
        let provider = NSItemProvider()
        provider.registerObject(Self.activity(for: endpoint), visibility: .all)
        let item = UIDragItem(itemProvider: provider)
        item.localObject = endpoint.id
        return [item]
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let endpoint = Connections.shared.endpoints.first(where: { $0.id == id }) else {
            return
        }
        open(endpoint, password: Connections.shared.password(for: endpoint))
    }

    #if DEBUG
    /// `-ViewerForm ssh`: a new connection's form with a bastion (not saved).
    func showSSHFormForTesting() {
        var endpoint = CHEndpoint(name: "")
        endpoint.ssh = CHSSHBastion(host: "bastion.example.com", user: "viewer", keyName: "id_ed25519",
                                    knownHostKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl")
        present(UINavigationController(rootViewController: ConnectionFormViewController(endpoint: endpoint, isNew: true)), animated: false)
    }
    #endif

    /// clickhouse-client's configuration (config.xml or config.yaml) chosen in Files, its
    /// connections added to the list.
    @objc func importFromClient(_ sender: Any?) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.xml, .yaml], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let found = (try? Data(contentsOf: url)).map(CHClientConfig.connections(in:)) ?? []
        let (added, skipped) = Connections.shared.add(found)
        let summary = Connections.importSummary(of: found, added: added, skipped: skipped)
        let alert = UIAlertController(title: summary.title, message: summary.detail, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    private func edit(_ endpoint: CHEndpoint?) {
        let form = ConnectionFormViewController(endpoint: endpoint ?? CHEndpoint(name: ""), isNew: endpoint == nil)
        present(UINavigationController(rootViewController: form), animated: true)
    }

    /// Connects, then shows the server's schema beside its editor and result;
    /// an error is said here, with the form a tap away.
    func open(_ endpoint: CHEndpoint, password: String) {
        let client = CHClient(endpoint: endpoint, password: password, identity: Connections.shared.clientIdentity(for: endpoint))
        let waiting = UIAlertController(title: String(localized: "Connecting to \(endpoint.title)…"),
                                        message: endpoint.isCloud ? String(localized: "A sleeping service takes a while to wake.") : nil,
                                        preferredStyle: .alert)
        let attempt = Task { [weak self] in
            do {
                try await Connections.shared.route(client, for: endpoint)
                _ = try await client.connect(timeout: endpoint.isCloud ? 120 : 20)
                try Task.checkCancellation()
                waiting.dismiss(animated: true) { [weak self] in self?.show(endpoint, client: client) }
            } catch where Task.isCancelled {
                waiting.dismiss(animated: true)
            } catch {
                waiting.dismiss(animated: true) { [weak self] in self?.showFailure(error, of: endpoint) }
            }
        }
        waiting.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in attempt.cancel() })
        present(waiting, animated: true)
    }

    private func showFailure(_ error: Error, of endpoint: CHEndpoint) {
        let alert = UIAlertController(title: String(localized: "Can't connect to \(endpoint.title)"), message: error.viewerSummary, preferredStyle: .alert)
        if error.viewerSummary != error.viewerDescription {
            alert.addAction(UIAlertAction(title: String(localized: "Details"), style: .default) { [weak self] _ in
                let details = UIAlertController(title: String(localized: "The server's message"), message: error.viewerDescription, preferredStyle: .alert)
                details.addAction(UIAlertAction(title: String(localized: "Copy"), style: .default) { _ in UIPasteboard.general.string = error.viewerDescription })
                details.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
                self?.present(details, animated: true)
            })
        }
        if Connections.shared.endpoints.contains(where: { $0.id == endpoint.id }) {
            alert.addAction(UIAlertAction(title: String(localized: "Edit Connection"), style: .default) { [weak self] _ in self?.edit(endpoint) })
        }
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        present(alert, animated: true)
    }

    /// The schema beside the editor and result, on a connected client.
    private func show(_ endpoint: CHEndpoint, client: CHClient) {
        let query = QueryViewController(endpoint: endpoint, client: client)
        let schema = SchemaViewController(client: client)
        schema.onShowRows = { [weak query] table, all in query?.showRows(of: table, all: all) }
        schema.onShowCreate = { [weak query] table in query?.showCreate(of: table) }
        schema.onInsert = { [weak query] text in query?.insert(text) }
        schema.onShowView = { [weak query] view in query?.show(view) }
        schema.onShowDetails = { [weak query] table in query?.showDetails(of: table, .overview) }
        query.onConnected = { [weak schema] in schema?.reload() }
        let split = UISplitViewController(style: .doubleColumn)
        // Side by side where there's room (landscape), the schema a tap away otherwise.
        split.preferredDisplayMode = .automatic
        split.preferredSplitBehavior = .automatic
        split.setViewController(UINavigationController(rootViewController: schema), for: .primary)
        split.setViewController(UINavigationController(rootViewController: query), for: .secondary)
        // On an iPhone: the editor and result first, the schema a tap back.
        split.delegate = query
        split.modalPresentationStyle = .fullScreen
        // The window is named for its server (the app switcher shows it) and comes back to it.
        shownEndpoint = endpoint
        view.window?.windowScene?.title = endpoint.title
        query.onClose = { [weak self, weak split] in
            self?.shownEndpoint = nil
            self?.view.window?.windowScene?.title = nil
            split?.dismiss(animated: true)
        }
        present(split, animated: true) {
            // Upright, the result first: the schema slides over it from its button.
            if split.view.bounds.width < split.view.bounds.height, !split.isCollapsed { split.hide(.primary) }
        }
    }
}
