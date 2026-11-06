import AppKit
import ClickHouseCore
import Gingham

/// A cell's whole value in a popover: JSON laid out, selectable, with Copy.
enum CellInspector {
    static func show(_ text: String, title: String, relativeTo rect: CGRect, of view: NSView) {
        let shown = prettyJSON(text) ?? text
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = SQLHighlighting.font
        textView.string = shown
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        heading.lineBreakMode = .byTruncatingMiddle
        let length = NSTextField(labelWithString: String(localized: "\((text as NSString).length.formatted()) characters"))
        length.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        length.textColor = .secondaryLabelColor
        let copy = NSButton(title: String(localized: "Copy"), target: nil, action: nil)
        let copier = Copier(text: text)
        copy.target = copier
        copy.action = #selector(Copier.copy(_:))
        let header = NSStackView(views: [heading, length, copy])
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [header, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        let lines = min(30, max(3, shown.split(separator: "\n", omittingEmptySubsequences: false).count + 1))
        let controller = NSViewController()
        controller.view = stack
        controller.preferredContentSize = NSSize(width: 520, height: min(520, CGFloat(lines) * 17 + 60))
        objc_setAssociatedObject(controller, &Copier.key, copier, .OBJC_ASSOCIATION_RETAIN)
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    /// The text laid out, if it's a JSON object or array.
    static func prettyJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }

    private final class Copier: NSObject {
        nonisolated(unsafe) static var key = 0
        let text: String

        init(text: String) { self.text = text }

        @objc func copy(_ sender: Any?) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

/// The inspector beside the result (View > Show Inspector, ⌥⌘I): the focused
/// cell's whole value, and its row column by column. It follows the cursor; a
/// column picked in the row is focused in the result.
final class ResultInspector: NSViewController, GHTableViewDataSource, GHTableViewDelegate {
    /// A column picked in the row's list: its index in the result.
    var onPickColumn: (Int) -> Void = { _ in }

    private let heading = NSTextField(labelWithString: "")
    private let typeLabel = NSTextField(labelWithString: "")
    private let valueView = NSTextView()
    private let valueScroll = NSScrollView()
    private let lengthLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let rowHeading = NSTextField(labelWithString: "")
    private let fields = GHTableView(frame: .zero)
    private let placeholder = NSTextField(wrappingLabelWithString: String(localized: "Select a cell to see its whole value here, and its row."))
    private let split = NSSplitView()

    /// What shows: the result, the row and the column (the same again isn't laid out again).
    private var source: ResultTableSource?
    private var row = -1
    private var columnIndex = -1
    private var rowCame = false
    private var text = ""
    /// The row's values as their cells show them, by column.
    private var values: [String] = []
    /// The text laid out at most (Copy copies all of it).
    private static let shownLength = 1_000_000

    override func loadView() {
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.lineBreakMode = .byTruncatingMiddle
        heading.isSelectable = true
        typeLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        typeLabel.textColor = .secondaryLabelColor
        typeLabel.lineBreakMode = .byTruncatingTail
        typeLabel.isSelectable = true
        for label in [heading, typeLabel] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let titles = NSStackView(views: [heading, typeLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2

        valueView.isEditable = false
        valueView.isSelectable = true
        valueView.drawsBackground = false
        valueView.textContainerInset = NSSize(width: 4, height: 6)
        valueView.minSize = .zero
        valueView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        valueView.isVerticallyResizable = true
        valueView.autoresizingMask = [.width]
        valueView.textContainer?.widthTracksTextView = true
        valueScroll.documentView = valueView
        valueScroll.hasVerticalScroller = true
        valueScroll.borderType = .noBorder
        valueScroll.backgroundColor = .textBackgroundColor
        valueScroll.wantsLayer = true
        valueScroll.layer?.cornerRadius = 8
        valueScroll.layer?.masksToBounds = true

        lengthLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        lengthLabel.textColor = .secondaryLabelColor
        lengthLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copyButton.title = String(localized: "Copy")
        copyButton.bezelStyle = .push
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(copyValue(_:))
        let footer = NSStackView(views: [lengthLabel, NSView(), copyButton])
        let value = NSStackView(views: [titles, valueScroll, footer])
        value.orientation = .vertical
        value.alignment = .leading
        value.spacing = 8
        for view in [titles, valueScroll, footer] { view.widthAnchor.constraint(equalTo: value.widthAnchor).isActive = true }
        value.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        valueScroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        rowHeading.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        rowHeading.textColor = .secondaryLabelColor
        fields.dataSource = self
        fields.delegate = self
        fields.showsHeader = false
        fields.showsSummaryRow = false
        fields.allowsMultipleSelection = false
        fields.allowsColumnReordering = false
        fields.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        fields.usesAlternatingRowBackgroundColors = false
        fields.autosaveName = nil
        fields.columns = [
            .column(GHTableColumn("name", title: String(localized: "Column"), width: 110, minWidth: 50, maxWidth: 400, isSortable: false)),
            .column(GHTableColumn("value", title: String(localized: "Value"), width: 140, minWidth: 50, maxWidth: 10_000, isSortable: false)),
        ]
        let row = NSStackView(views: [rowHeading, fields])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 6
        fields.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        row.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)
        fields.setContentHuggingPriority(.defaultLow, for: .vertical)

        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(value)
        split.addArrangedSubview(row)
        // The value takes the window's height changes; the row's list keeps its own.
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        split.autosaveName = "ResultInspectorSplit"
        value.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        let view = NSView()
        for subview in [split, placeholder] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        // Inside its safe area: the toolbar's glass is over the inspector's top.
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
            split.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -10),
            split.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            split.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            placeholder.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 20),
            placeholder.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -20),
        ])
        self.view = view
        show(nil, row: -1, columnIndex: -1)
    }

    /// The divider in the middle the first time the inspector shows (then where the user leaves it).
    private var placedDivider = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames ResultInspectorSplit") != nil

    override func viewDidLayout() {
        super.viewDidLayout()
        // Once the panes have their heights (on the first pass they have none yet).
        guard !placedDivider, split.arrangedSubviews.map(\.frame.height).reduce(0, +) > 300 else { return }
        placedDivider = true
        split.setPosition((split.bounds.height * 0.5).rounded(), ofDividerAt: 0)
    }

    /// The value of `row` (a data source row) in the result's column `columnIndex`, or nothing (`-1`).
    func show(_ source: ResultTableSource?, row: Int, columnIndex: Int) {
        let rowCame = source.map { row >= 0 && row < $0.result.rowCount } ?? false
        guard source !== self.source || row != self.row || columnIndex != self.columnIndex || rowCame != self.rowCame else { return }
        let rowChanged = source !== self.source || row != self.row || rowCame != self.rowCame
        self.source = source
        self.row = row
        self.columnIndex = columnIndex
        self.rowCame = rowCame
        guard let source, rowCame, columnIndex >= 0, columnIndex < source.result.names.count else {
            text = ""
            values = []
            fields.reloadData()
            split.isHidden = true
            placeholder.isHidden = false
            return
        }
        split.isHidden = false
        placeholder.isHidden = true
        heading.stringValue = source.result.names[columnIndex]
        typeLabel.stringValue = source.result.typeNames[columnIndex]
        let isNull = source.isNull(row: row, columnIndex: columnIndex)
        text = isNull ? "" : source.fullText(row: row, columnIndex: columnIndex) ?? ""
        let length = (text as NSString).length
        var shown = length > Self.shownLength ? String(text.prefix(Self.shownLength)) : text
        if length <= Self.shownLength, let pretty = CellInspector.prettyJSON(text) { shown = pretty }
        valueView.font = SQLHighlighting.font
        valueView.textColor = isNull ? .tertiaryLabelColor : .labelColor
        valueView.string = isNull ? "NULL" : shown
        valueView.scroll(.zero)
        lengthLabel.stringValue = isNull ? String(localized: "No value (NULL)")
            : length > Self.shownLength ? String(localized: "\(length.formatted()) characters, the first \(Self.shownLength.formatted()) shown")
            : String(localized: "\(length.formatted()) characters")
        copyButton.isEnabled = !isNull
        if rowChanged {
            rowHeading.stringValue = String(localized: "Row \((row + 1).formatted()) of \(source.result.rowCount.formatted())")
            values = source.result.names.indices.map { source.shownText(row: row, columnIndex: $0) }
            fields.reloadData()
        }
        if fields.selectedRow != columnIndex {
            fields.selectRowIndexes(IndexSet(integer: columnIndex), byExtendingSelection: false)
        }
        fields.scrollRowToVisible(columnIndex)
    }

    /// The text's font again (Settings > Appearance changed).
    func applyAppearance() {
        valueView.font = SQLHighlighting.font
    }

    @objc private func copyValue(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: The row's list

    func numberOfRows(in tableView: GHTableView) -> Int { values.count }

    func tableView(_ tableView: GHTableView, valueFor column: GHTableColumn, row: Int) -> GHCellValue {
        guard let source, row < values.count else { return .empty }
        return .text(column.id == "name" ? source.result.names[row] : values[row])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let picked = fields.selectedRow
        guard picked >= 0, picked != columnIndex else { return }
        onPickColumn(picked)
    }
}
