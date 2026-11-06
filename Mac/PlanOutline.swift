import AppKit
import ClickHouseCore

/// A plan in the result's place: an outline of its steps (Explain Plan),
/// the reads' funnels in a line above it.
final class PlanOutline: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let outline = NSOutlineView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private var root: PlanItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let step = NSTableColumn(identifier: .init("step"))
        step.title = String(localized: "Step")
        step.width = 420
        let detail = NSTableColumn(identifier: .init("detail"))
        detail.title = String(localized: "Reads")
        detail.width = 420
        outline.addTableColumn(step)
        outline.addTableColumn(detail)
        outline.outlineTableColumn = step
        outline.dataSource = self
        outline.delegate = self
        outline.usesAutomaticRowHeights = true
        outline.style = .inset
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        summary.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let stack = NSStackView(views: [summary, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ plan: CHPlanNode) {
        root = PlanItem(plan)
        summary.stringValue = PlanItem.summary(of: plan)
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? PlanItem else { return root == nil ? 0 : 1 }
        return item.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? PlanItem else { return root! }
        return item.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? PlanItem)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? PlanItem else { return nil }
        let cell = NSTableCellView()
        let stack: NSStackView
        if tableColumn?.identifier.rawValue == "detail" {
            let label = NSTextField(wrappingLabelWithString: item.detail)
            label.textColor = .secondaryLabelColor
            stack = NSStackView(views: [label])
        } else {
            let icon = NSImageView(image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            let title = NSTextField(wrappingLabelWithString: item.title)
            var lines: [NSView] = [title]
            if let note = item.note {
                let condition = NSTextField(wrappingLabelWithString: note)
                condition.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                condition.textColor = .secondaryLabelColor
                lines.append(condition)
            }
            let texts = NSStackView(views: lines)
            texts.orientation = .vertical
            texts.alignment = .leading
            texts.spacing = 2
            stack = NSStackView(views: [icon, texts])
            stack.alignment = .top
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3),
        ])
        return cell
    }
}
