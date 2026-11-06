import AppKit

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
