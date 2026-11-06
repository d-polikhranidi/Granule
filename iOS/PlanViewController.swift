import ClickHouseCore
import UIKit

/// A query's plan (Explain Plan): its steps as an outline, each read with the
/// granules its indexes leave, the reads' funnels at the top.
final class PlanViewController: UICollectionViewController {
    private let plan: CHPlanNode
    private var dataSource: UICollectionViewDiffableDataSource<Int, Node>!

    /// A row (an item of the plan, by identity).
    nonisolated struct Node: Hashable, Sendable {
        let id = UUID()
        static func == (lhs: Node, rhs: Node) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private var items: [UUID: PlanItem] = [:]

    init(plan: CHPlanNode) {
        self.plan = plan
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Plan")
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Node> { [weak self] cell, _, node in
            guard let item = self?.items[node.id] else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = item.title
            content.image = UIImage(systemName: item.symbol)
            let lines = [item.detail, item.note ?? ""].filter { !$0.isEmpty }
            content.secondaryText = lines.joined(separator: "\n")
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
            cell.contentConfiguration = content
            cell.accessories = item.children.isEmpty ? [] : [.outlineDisclosure()]
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) {
            [plan] cell, _, _ in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = PlanItem.summary(of: plan)
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, node in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: node)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSectionSnapshot<Node>()
        func add(_ item: PlanItem, to parent: Node?) {
            let node = Node()
            items[node.id] = item
            snapshot.append([node], to: parent)
            item.children.forEach { add($0, to: node) }
            if !item.children.isEmpty { snapshot.expand([node]) }
        }
        add(PlanItem(plan), to: nil)
        dataSource.apply(snapshot, to: 0, animatingDifferences: false)
    }
}
