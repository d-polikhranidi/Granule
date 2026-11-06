import ClickHouseCore
import UIKit

/// The servers the user added: tap one to open it, swipe to edit or remove,
/// + to add one (a URL pasted fills its form in).
final class ConnectionsViewController: UICollectionViewController {
    private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!

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
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.edit(nil) })
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, UUID> { cell, _, id in
            guard let endpoint = Connections.shared.endpoints.first(where: { $0.id == id }) else { return }
            var content = cell.defaultContentConfiguration()
            content.text = endpoint.title
            content.secondaryText = "\(endpoint.host):\(endpoint.port)" + (endpoint.isReadOnly ? " · " + String(localized: "read only") : "")
            content.image = UIImage(systemName: endpoint.isCloud ? "cloud" : "server.rack")
            cell.contentConfiguration = content
            cell.accessories = [.detail { [weak self] in self?.edit(endpoint) }]
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        Connections.shared.onChange.append { [weak self] in self?.reload() }
        if Connections.shared.endpoints.isEmpty {
            Connections.shared.save(CHEndpoint(name: String(localized: "Local server")), password: "")
        }
        reload()
    }

    private func reload() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(Connections.shared.endpoints.map(\.id))
        snapshot.reconfigureItems(Connections.shared.endpoints.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: false)
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

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let endpoint = Connections.shared.endpoints.first(where: { $0.id == id }) else {
            return
        }
        open(endpoint, password: Connections.shared.password(for: endpoint))
    }

    private func edit(_ endpoint: CHEndpoint?) {
        let form = ConnectionFormViewController(endpoint: endpoint ?? CHEndpoint(name: ""), isNew: endpoint == nil)
        present(UINavigationController(rootViewController: form), animated: true)
    }

    /// The server's schema beside its editor and result.
    func open(_ endpoint: CHEndpoint, password: String) {
        let client = CHClient(endpoint: endpoint, password: password)
        let query = QueryViewController(endpoint: endpoint, client: client)
        let schema = SchemaViewController(client: client)
        schema.onShowRows = { [weak query] table in query?.showRows(of: table) }
        schema.onShowCreate = { [weak query] table in query?.showCreate(of: table) }
        schema.onInsert = { [weak query] text in query?.insert(text) }
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
        query.onClose = { [weak split] in split?.dismiss(animated: true) }
        present(split, animated: true) {
            // Upright, the result first: the schema slides over it from its button.
            if split.view.bounds.width < split.view.bounds.height, !split.isCollapsed { split.hide(.primary) }
        }
    }
}
