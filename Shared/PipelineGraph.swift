#if os(macOS)
import AppKit
#else
import UIKit
#endif
import ClickHouseCore
import CoreText

/// A pipeline laid out from top to bottom: a row for each layer (the
/// longest way from a source), each node under the mean place of those
/// before it, the streams between them as curves with their counts.
nonisolated struct PipelineLayout {
    struct Box {
        var node: CHPipeline.Node
        var frame: CGRect
    }

    var boxes: [String: Box] = [:]
    var edges: [CHPipeline.Edge] = []
    var size: CGSize = .zero

    static let titleSize: CGFloat = 12
    static let stepSize: CGFloat = 10
    static let height: CGFloat = 46
    static let rowGap: CGFloat = 40
    static let columnGap: CGFloat = 24
    static let margin: CGFloat = 24

    init(_ pipeline: CHPipeline) {
        edges = pipeline.edges
        let layers = pipeline.layers
        let rows = Dictionary(grouping: pipeline.nodes, by: { layers[$0.id] ?? 0 })
        let incoming = Dictionary(grouping: pipeline.edges, by: \.to)
        var centers: [String: CGFloat] = [:]
        var placed: [[(CHPipeline.Node, CGFloat)]] = []
        for layer in (rows.keys.max() ?? -1) < 0 ? [] : Array(0...(rows.keys.max() ?? 0)) {
            var row = (rows[layer] ?? []).map { node in (node, Self.width(of: node)) }
            // Under the mean place of the nodes before it (those first in the DOT where none are).
            row.sort { a, b in
                let ax = (incoming[a.0.id] ?? []).compactMap { centers[$0.from] }, bx = (incoming[b.0.id] ?? []).compactMap { centers[$0.from] }
                let am = ax.isEmpty ? .greatestFiniteMagnitude : ax.reduce(0, +) / CGFloat(ax.count)
                let bm = bx.isEmpty ? .greatestFiniteMagnitude : bx.reduce(0, +) / CGFloat(bx.count)
                return am < bm
            }
            var x: CGFloat = 0
            for (node, width) in row {
                centers[node.id] = x + width / 2
                x += width + Self.columnGap
            }
            placed.append(row)
        }
        let widest = placed.map { row in row.reduce(0) { $0 + $1.1 } + CGFloat(max(0, row.count - 1)) * Self.columnGap }.max() ?? 0
        for (layer, row) in placed.enumerated() {
            let rowWidth = row.reduce(0) { $0 + $1.1 } + CGFloat(max(0, row.count - 1)) * Self.columnGap
            var x = Self.margin + (widest - rowWidth) / 2
            let y = Self.margin + CGFloat(layer) * (Self.height + Self.rowGap)
            for (node, width) in row {
                boxes[node.id] = Box(node: node, frame: CGRect(x: x, y: y, width: width, height: Self.height))
                x += width + Self.columnGap
            }
        }
        size = CGSize(width: widest + Self.margin * 2, height: Self.margin * 2 + CGFloat(placed.count) * (Self.height + Self.rowGap) - Self.rowGap)
    }

    private static func width(of node: CHPipeline.Node) -> CGFloat {
        max(textWidth(node.label, size: titleSize, bold: true), textWidth(node.step, size: stepSize, bold: false)) + 28
    }

    static func textWidth(_ text: String, size: CGFloat, bold: Bool) -> CGFloat {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font as Any]))
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }
}

/// The pipeline drawn: nodes as rounded boxes (the processor, its plan step
/// under it), streams as curves with arrowheads and their counts.
final class PipelineCanvas: PlatformView {
    var layout = PipelineLayout(CHPipeline(dot: "")) {
        didSet {
            invalidateIntrinsicContentSize()
            #if os(macOS)
            setFrameSize(layout.size)
            needsDisplay = true
            #else
            frame.size = layout.size
            setNeedsDisplay()
            #endif
        }
    }

    override var intrinsicContentSize: CGSize { layout.size }

    #if os(macOS)
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawGraph(in: context)
    }

    private var colors: (fill: CGColor, stroke: CGColor, text: CGColor, muted: CGColor, edge: CGColor) {
        var result: (CGColor, CGColor, CGColor, CGColor, CGColor) = (.white, .black, .black, .black, .black)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            result = (NSColor.controlBackgroundColor.cgColor, NSColor.separatorColor.cgColor, NSColor.labelColor.cgColor,
                      NSColor.secondaryLabelColor.cgColor, NSColor.tertiaryLabelColor.cgColor)
        }
        return result
    }
    #else
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        drawGraph(in: context)
    }

    private var colors: (fill: CGColor, stroke: CGColor, text: CGColor, muted: CGColor, edge: CGColor) {
        let traits = traitCollection
        return (UIColor.secondarySystemBackground.resolvedColor(with: traits).cgColor, UIColor.separator.resolvedColor(with: traits).cgColor,
                UIColor.label.resolvedColor(with: traits).cgColor, UIColor.secondaryLabel.resolvedColor(with: traits).cgColor,
                UIColor.tertiaryLabel.resolvedColor(with: traits).cgColor)
    }
    #endif

    private func drawGraph(in context: CGContext) {
        let colors = colors
        // Streams first, under the boxes.
        context.setLineWidth(1.5)
        context.setStrokeColor(colors.edge)
        context.setFillColor(colors.edge)
        for edge in layout.edges {
            guard let from = layout.boxes[edge.from]?.frame, let to = layout.boxes[edge.to]?.frame else { continue }
            let start = CGPoint(x: from.midX, y: from.maxY), end = CGPoint(x: to.midX, y: to.minY - 6)
            let bend = (end.y - start.y) / 2
            context.move(to: start)
            context.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y + bend), control2: CGPoint(x: end.x, y: end.y - bend))
            context.strokePath()
            context.move(to: CGPoint(x: end.x, y: end.y + 6))
            context.addLine(to: CGPoint(x: end.x - 4.5, y: end.y - 1))
            context.addLine(to: CGPoint(x: end.x + 4.5, y: end.y - 1))
            context.closePath()
            context.fillPath()
            if !edge.label.isEmpty {
                let middle = CGPoint(x: (start.x + end.x) / 2 + 8, y: (start.y + end.y) / 2 - 7)
                drawText(edge.label, at: middle, size: PipelineLayout.stepSize, bold: false, color: colors.muted, in: context)
            }
        }
        for box in layout.boxes.values {
            let path = CGPath(roundedRect: box.frame, cornerWidth: 8, cornerHeight: 8, transform: nil)
            context.addPath(path)
            context.setFillColor(colors.fill)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(colors.stroke)
            context.setLineWidth(1)
            context.strokePath()
            drawText(box.node.label, at: CGPoint(x: box.frame.minX + 14, y: box.frame.minY + 8), size: PipelineLayout.titleSize, bold: true,
                     color: colors.text, in: context)
            drawText(box.node.step, at: CGPoint(x: box.frame.minX + 14, y: box.frame.minY + 26), size: PipelineLayout.stepSize, bold: false,
                     color: colors.muted, in: context)
        }
    }

    /// Text with its top left at `point`, in a top-down context.
    private func drawText(_ text: String, at point: CGPoint, size: CGFloat, bold: Bool, color: CGColor, in context: CGContext) {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font as Any, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, nil, nil)
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: point.x, y: point.y + ascent)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
