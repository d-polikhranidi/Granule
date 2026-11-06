#if os(macOS)
import AppKit
typealias PlatformView = NSView
#else
import UIKit
typealias PlatformView = UIView
#endif
import ClickHouseCore
import Metal
import MetalKit
import QuartzCore
import simd

/// The colors of a chart, light and dark: the data-viz reference palette's
/// first three categorical slots (validated in both modes) and its surfaces.
nonisolated struct ChartPalette {
    let surface: SIMD4<Float>
    let grid: SIMD4<Float>
    let axis: SIMD4<Float>
    let muted: CGColor
    let text: CGColor
    let series: [SIMD4<Float>]

    static func rgb(_ hex: UInt32, alpha: Float = 1) -> SIMD4<Float> {
        SIMD4(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255, alpha)
    }

    static func color(_ value: SIMD4<Float>) -> CGColor {
        CGColor(srgbRed: CGFloat(value.x), green: CGFloat(value.y), blue: CGFloat(value.z), alpha: CGFloat(value.w))
    }

    static let light = ChartPalette(surface: rgb(0xFCFCFB), grid: rgb(0xE1E0D9), axis: rgb(0xC3C2B7), muted: color(rgb(0x6F6E69)),
                                    text: color(rgb(0x0B0B0B)), series: [rgb(0x2A78D6), rgb(0xEB6834), rgb(0x1BAF7A)])
    static let dark = ChartPalette(surface: rgb(0x1A1A19), grid: rgb(0x2C2C2A), axis: rgb(0x383835), muted: color(rgb(0x9D9B94)),
                                   text: color(rgb(0xFFFFFF)), series: [rgb(0x3987E5), rgb(0xD95926), rgb(0x199E70)])
}

/// A vertex as the chart's shaders take it (ChartShaders.metal).
nonisolated struct ChartVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
    var local: SIMD2<Float> = .zero
    var halfSize: SIMD2<Float> = .zero
    var radius: Float = 0
    var kind: UInt32 = 0
}

/// A chart of a result: lines over time or numbers, bars per category, drawn
/// by the GPU (its own shaders) with the axes' labels, the legend and the
/// value under the pointer in text over it.
final class ChartView: PlatformView, MTKViewDelegate {
    var model: ChartModel? { didSet { relayout() } }
    /// The zone x's times are written in.
    var timeZone: TimeZone = .gmt { didSet { relayout() } }

    private let metal = MTKView()
    /// Over the marks: the text (it takes no clicks or touches).
    private let overlay = ChartOverlay()
    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private var vertices: [ChartVertex] = []
    private let labels = CALayer()
    private let tooltip = CATextLayer()
    private let emptyLabel = CATextLayer()
    /// Where the pointer is over the plot (points), `nil` when it's not.
    private var hover: CGPoint?
    private var plot = CGRect.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        metal.device = device
        metal.delegate = self
        metal.sampleCount = 4
        metal.colorPixelFormat = .bgra8Unorm
        metal.enableSetNeedsDisplay = true
        metal.isPaused = true
        metal.translatesAutoresizingMaskIntoConstraints = false
        #if os(macOS)
        wantsLayer = true
        metal.layer?.isOpaque = true
        #endif
        addSubview(metal)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        for view in [metal, overlay] as [PlatformView] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        queue = device.makeCommandQueue()
        if let library = device.makeDefaultLibrary() {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "chartVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "chartFragment")
            descriptor.rasterSampleCount = 4
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        // The text over the marks.
        tooltip.isWrapped = false
        tooltip.cornerRadius = 6
        tooltip.isHidden = true
        tooltip.fontSize = 12
        emptyLabel.fontSize = 13
        emptyLabel.alignmentMode = .center
        #if os(macOS)
        overlay.wantsLayer = true
        overlay.layer?.addSublayer(labels)
        overlay.layer?.addSublayer(tooltip)
        overlay.layer?.addSublayer(emptyLabel)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
        #else
        overlay.isUserInteractionEnabled = false
        overlay.layer.addSublayer(labels)
        overlay.layer.addSublayer(tooltip)
        overlay.layer.addSublayer(emptyLabel)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0
        addGestureRecognizer(press)
        #endif
    }

    // MARK: Appearance and size

    private var scale: CGFloat {
        #if os(macOS)
        window?.backingScaleFactor ?? 2
        #else
        traitCollection.displayScale
        #endif
    }

    private var palette: ChartPalette {
        #if os(macOS)
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        #else
        traitCollection.userInterfaceStyle == .dark ? .dark : .light
        #endif
    }

    #if os(macOS)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        relayout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        relayout()
    }

    override func mouseMoved(with event: NSEvent) {
        hover = convert(event.locationInWindow, from: nil)
        relayout()
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        relayout()
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        relayout()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        relayout()
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        hover = recognizer.state == .ended || recognizer.state == .cancelled ? nil : recognizer.location(in: self)
        relayout()
    }

    @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
        hover = recognizer.state == .ended || recognizer.state == .cancelled ? nil : recognizer.location(in: self)
        relayout()
    }
    #endif

    /// The pixel columns the plot has: the buckets a long line is folded into.
    var plotWidthInPixels: Int { max(100, Int((bounds.width - 80) * scale)) }

    // MARK: Building

    /// The marks and the text for the model at this size.
    private func relayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        labels.frame = bounds
        labels.sublayers?.forEach { $0.removeFromSuperlayer() }
        emptyLabel.contentsScale = scale
        tooltip.contentsScale = scale
        let palette = palette
        vertices.removeAll(keepingCapacity: true)
        guard let model, bounds.width > 120, bounds.height > 80 else {
            emptyLabel.isHidden = false
            emptyLabel.string = model == nil ? String(localized: "Nothing to chart: a result needs a column of numbers.") : ""
            emptyLabel.foregroundColor = palette.muted
            emptyLabel.frame = CGRect(x: 0, y: bounds.height / 2 - 10, width: bounds.width, height: 22)
            tooltip.isHidden = true
            metal.setNeedsDisplayCompat()
            return
        }
        emptyLabel.isHidden = true
        let legendHeight: CGFloat = model.series.count > 1 ? 24 : 0
        plot = CGRect(x: 64, y: 14 + legendHeight, width: bounds.width - 64 - 20, height: bounds.height - 14 - legendHeight - 34)
        guard plot.width > 20, plot.height > 20 else { return }
        let yTicks = ChartModel.ticks(model.yRange, count: max(2, Int(plot.height / 56)))
        for tick in yTicks {
            let y = yPosition(tick, model)
            addLine(from: CGPoint(x: plot.minX, y: y), to: CGPoint(x: plot.maxX, y: y), width: 1 / scale, color: palette.grid)
            addText(ChartModel.compact(tick), at: CGRect(x: 0, y: y - 8, width: plot.minX - 8, height: 16), color: palette.muted, alignment: .right)
        }
        // The baseline (zero when it's in view).
        let baseline = model.yRange.contains(0) ? yPosition(0, model) : plot.maxY
        addLine(from: CGPoint(x: plot.minX, y: baseline), to: CGPoint(x: plot.maxX, y: baseline), width: 1 / scale, color: palette.axis)
        switch model.kind {
        case .bars: buildBars(model, palette: palette, baseline: baseline)
        default: buildLines(model, palette: palette)
        }
        // The legend: every series named, its color beside it.
        if model.series.count > 1 {
            var x = plot.minX
            for (index, series) in model.series.enumerated() {
                let color = palette.series[index % palette.series.count]
                addDot(CGPoint(x: x + 5, y: 12), radius: 4, color: color)
                let width = textWidth(series.name) + 8
                addText(series.name, at: CGRect(x: x + 14, y: 4, width: width, height: 16), color: palette.text, alignment: .left)
                x += 14 + width + 16
            }
        }
        metal.setNeedsDisplayCompat()
    }

    private func xPosition(_ value: Double, _ model: ChartModel) -> CGFloat {
        let span = model.xRange.upperBound - model.xRange.lowerBound
        return plot.minX + CGFloat(span > 0 ? (value - model.xRange.lowerBound) / span : 0.5) * plot.width
    }

    private func yPosition(_ value: Double, _ model: ChartModel) -> CGFloat {
        let span = model.yRange.upperBound - model.yRange.lowerBound
        return plot.maxY - CGFloat(span > 0 ? (value - model.yRange.lowerBound) / span : 0.5) * plot.height
    }

    private func buildLines(_ model: ChartModel, palette: ChartPalette) {
        let isTime = model.xType.isTemporal
        // The x axis: times at a round step in the column's zone, or round numbers.
        let count = max(2, Int(plot.width / 110))
        if isTime {
            let ticks = ChartModel.timeTicks(model.xRange, count: count, zone: timeZone)
            for tick in ticks.values {
                let x = xPosition(tick, model)
                addText(Date(timeIntervalSince1970: tick).formatted(ticks.format), at: CGRect(x: x - 60, y: plot.maxY + 8, width: 120, height: 16),
                        color: palette.muted, alignment: .center)
            }
        } else {
            for tick in ChartModel.ticks(model.xRange, count: count) {
                let x = xPosition(tick, model)
                addText(ChartModel.compact(tick), at: CGRect(x: x - 50, y: plot.maxY + 8, width: 100, height: 16), color: palette.muted, alignment: .center)
            }
        }
        let width = 2.0
        var endLabels: [CGFloat] = []
        var hoverValues: [(String, Double, SIMD4<Float>, CGPoint)] = []
        let hoverX = hover.flatMap { plot.insetBy(dx: -4, dy: -4).contains($0) ? $0.x : nil }
        var hoverDomainX: Double?
        for (index, series) in model.series.enumerated() {
            let color = palette.series[index % palette.series.count]
            if !series.mean.isEmpty {
                // Folded: each bucket's least to most as a band, its mean as the line.
                let buckets = series.mean.count
                func bucketX(_ bucket: Int) -> CGFloat { plot.minX + CGFloat(bucket) / CGFloat(max(1, buckets - 1)) * plot.width }
                var previous: Int?
                for bucket in 0..<buckets where !series.mean[bucket].isNaN {
                    if let last = previous {
                        addBand(x0: bucketX(last), low0: yPosition(series.least[last], model), high0: yPosition(series.most[last], model),
                                x1: bucketX(bucket), low1: yPosition(series.least[bucket], model), high1: yPosition(series.most[bucket], model),
                                color: color * SIMD4(1, 1, 1, 0.12))
                        addLine(from: CGPoint(x: bucketX(last), y: yPosition(series.mean[last], model)),
                                to: CGPoint(x: bucketX(bucket), y: yPosition(series.mean[bucket], model)), width: width, color: color, joins: true)
                    }
                    previous = bucket
                }
                if let hoverX {
                    let bucket = min(buckets - 1, max(0, Int(((hoverX - plot.minX) / plot.width * CGFloat(buckets - 1)).rounded())))
                    if !series.mean[bucket].isNaN {
                        let span = model.xRange.upperBound - model.xRange.lowerBound
                        hoverDomainX = model.xRange.lowerBound + span * Double(bucket) / Double(max(1, buckets - 1))
                        hoverValues.append((series.name, series.mean[bucket], color, CGPoint(x: bucketX(bucket), y: yPosition(series.mean[bucket], model))))
                    }
                }
            } else {
                var last: CGPoint?
                for (x, y) in series.points {
                    let point = CGPoint(x: xPosition(x, model), y: yPosition(y, model))
                    if let last { addLine(from: last, to: point, width: width, color: color, joins: true) }
                    last = point
                }
                if series.points.count == 1, let only = last { addDot(only, radius: 4, color: color) }
                if let hoverX, !series.points.isEmpty {
                    // The point nearest the pointer (points are in order of x).
                    let target = model.xRange.lowerBound + Double((hoverX - plot.minX) / plot.width) * (model.xRange.upperBound - model.xRange.lowerBound)
                    var low = 0, high = series.points.count - 1
                    while low < high {
                        let middle = (low + high) / 2
                        if series.points[middle].0 < target { low = middle + 1 } else { high = middle }
                    }
                    let candidates = [low - 1, low].filter { $0 >= 0 && $0 < series.points.count }
                    if let nearest = candidates.min(by: { abs(series.points[$0].0 - target) < abs(series.points[$1].0 - target) }) {
                        let point = series.points[nearest]
                        hoverDomainX = point.0
                        hoverValues.append((series.name, point.1, color, CGPoint(x: xPosition(point.0, model), y: yPosition(point.1, model))))
                    }
                }
            }
            // A direct label at the line's end (with a legend, for two or three series).
            if model.series.count > 1, let end = endPoint(of: series, model) {
                var y = end.y - 16
                while endLabels.contains(where: { abs($0 - y) < 14 }) { y += 14 }
                endLabels.append(y)
                let text = series.name
                let width = textWidth(text) + 6
                addText(text, at: CGRect(x: min(end.x, plot.maxX) - width, y: max(plot.minY, y), width: width, height: 14),
                        color: palette.text, alignment: .right)
            }
        }
        // The value under the pointer: a crosshair, dots ringed by the surface, a tooltip.
        guard let hoverDomainX, let first = hoverValues.first else {
            tooltip.isHidden = true
            return
        }
        addLine(from: CGPoint(x: first.3.x, y: plot.minY), to: CGPoint(x: first.3.x, y: plot.maxY), width: 1 / scale, color: palette.axis)
        for value in hoverValues {
            addDot(value.3, radius: 6, color: palette.surface)
            addDot(value.3, radius: 4, color: value.2)
        }
        let xText = isTime ? Date(timeIntervalSince1970: hoverDomainX).formatted(Date.FormatStyle(timeZone: timeZone).year().month().day().hour().minute().second())
            : ChartModel.compact(hoverDomainX)
        let lines = [xText] + hoverValues.map { "\($0.0): \(Self.exact($0.1))" } + (model.isFolded ? [String(localized: "(the mean of the rows at this pixel)")] : [])
        showTooltip(lines.joined(separator: "\n"), near: first.3, palette: palette)
    }

    /// Where a line ends (its last value).
    private func endPoint(of series: ChartModel.Series, _ model: ChartModel) -> CGPoint? {
        if let last = series.points.last { return CGPoint(x: xPosition(last.0, model), y: yPosition(last.1, model)) }
        guard let bucket = series.mean.lastIndex(where: { !$0.isNaN }) else { return nil }
        return CGPoint(x: plot.minX + CGFloat(bucket) / CGFloat(max(1, series.mean.count - 1)) * plot.width, y: yPosition(series.mean[bucket], model))
    }

    private func buildBars(_ model: ChartModel, palette: ChartPalette, baseline: CGFloat) {
        let categories = model.categories.count
        guard categories > 0 else { return }
        let slot = plot.width / CGFloat(categories)
        let seriesCount = CGFloat(model.series.count)
        // Bars at most 24 points thick, 2 points apart, the rest of the slot air.
        let thickness = min(24, max(2, (slot * 0.72 - (seriesCount - 1) * 2) / seriesCount))
        let group = thickness * seriesCount + (seriesCount - 1) * 2
        // Category labels: every one that fits.
        let every = max(1, Int(ceil(70 / slot)))
        for (index, name) in model.categories.enumerated() where index % every == 0 {
            let center = plot.minX + slot * (CGFloat(index) + 0.5)
            addText(name, at: CGRect(x: center - slot * CGFloat(every) / 2, y: plot.maxY + 8, width: slot * CGFloat(every), height: 16),
                    color: palette.muted, alignment: .center)
        }
        var hovered: (Int, CGFloat)?
        if let hover, plot.insetBy(dx: 0, dy: -4).contains(hover) {
            let index = min(categories - 1, max(0, Int((hover.x - plot.minX) / slot)))
            hovered = (index, plot.minX + slot * (CGFloat(index) + 0.5))
        }
        for (seriesIndex, series) in model.series.enumerated() {
            let color = palette.series[seriesIndex % palette.series.count]
            for (index, value) in series.values.enumerated() where value.isFinite {
                let left = plot.minX + slot * (CGFloat(index) + 0.5) - group / 2 + CGFloat(seriesIndex) * (thickness + 2)
                let top = yPosition(value, model)
                let faded = hovered.map { $0.0 != index } ?? false
                addBar(CGRect(x: left, y: min(top, baseline), width: thickness, height: abs(baseline - top)), upward: top <= baseline,
                       color: faded ? color * SIMD4(1, 1, 1, 0.45) : color)
            }
        }
        guard let (index, center) = hovered else {
            tooltip.isHidden = true
            return
        }
        let lines = [model.categories[index]] + model.series.map { "\($0.name): \(Self.exact($0.values[index]))" }
        let top = model.series.map { yPosition($0.values[index], model) }.min() ?? plot.midY
        showTooltip(lines.joined(separator: "\n"), near: CGPoint(x: center, y: top), palette: palette)
    }

    /// A value in a tooltip: exact, grouped.
    private static func exact(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0...4)))
    }

    // MARK: Marks

    /// A segment `width` points wide (with round joins when `joins`).
    private func addLine(from a: CGPoint, to b: CGPoint, width: CGFloat, color: SIMD4<Float>, joins: Bool = false) {
        let scale = Float(self.scale)
        let p0 = SIMD2(Float(a.x), Float(a.y)) * scale, p1 = SIMD2(Float(b.x), Float(b.y)) * scale
        let direction = p1 - p0
        let length = simd_length(direction)
        guard length > 0.001 else { return }
        let normal = SIMD2(-direction.y, direction.x) / length * Float(width) * scale / 2
        let quad = [p0 + normal, p0 - normal, p1 + normal, p1 - normal]
        for index in [0, 1, 2, 2, 1, 3] { vertices.append(ChartVertex(position: quad[index], color: color)) }
        if joins, width > 1.5 { addDot(b, radius: width / 2, color: color) }
    }

    /// A band between two lines (low and high at two x's).
    private func addBand(x0: CGFloat, low0: CGFloat, high0: CGFloat, x1: CGFloat, low1: CGFloat, high1: CGFloat, color: SIMD4<Float>) {
        let scale = Float(self.scale)
        let points = [SIMD2(Float(x0), Float(low0)), SIMD2(Float(x0), Float(high0)), SIMD2(Float(x1), Float(low1)), SIMD2(Float(x1), Float(high1))]
            .map { $0 * scale }
        for index in [0, 1, 2, 2, 1, 3] { vertices.append(ChartVertex(position: points[index], color: color)) }
    }

    /// A dot (a circle the fragment shader smooths).
    private func addDot(_ center: CGPoint, radius: CGFloat, color: SIMD4<Float>) {
        let scale = Float(self.scale)
        let c = SIMD2(Float(center.x), Float(center.y)) * scale, r = Float(radius) * scale + 1
        let corners: [SIMD2<Float>] = [SIMD2(-r, -r), SIMD2(r, -r), SIMD2(-r, r), SIMD2(r, r)]
        for index in [0, 1, 2, 2, 1, 3] {
            vertices.append(ChartVertex(position: c + corners[index], color: color, local: corners[index],
                                        halfSize: SIMD2(Float(radius) * scale, 0), kind: 2))
        }
    }

    /// A bar rounded at its data end (4 points), square at the baseline.
    private func addBar(_ rect: CGRect, upward: Bool, color: SIMD4<Float>) {
        guard rect.height > 0.25 else { return }
        let scale = Float(self.scale)
        let half = SIMD2(Float(rect.width), Float(rect.height)) * scale / 2
        let center = SIMD2(Float(rect.midX), Float(rect.midY)) * scale
        let radius = min(4 * scale, half.x, half.y)
        let corners: [SIMD2<Float>] = [SIMD2(-half.x, -half.y), SIMD2(half.x, -half.y), SIMD2(-half.x, half.y), SIMD2(half.x, half.y)]
        for index in [0, 1, 2, 2, 1, 3] {
            // (Local y < 0 is the rounded end: a bar going down has it at the bottom.)
            var local = corners[index]
            if !upward { local.y = -local.y }
            vertices.append(ChartVertex(position: center + corners[index], color: color, local: local, halfSize: half, radius: radius, kind: 1))
        }
    }

    // MARK: Text

    private func addText(_ text: String, at frame: CGRect, color: CGColor, alignment: CATextLayerAlignmentMode) {
        let layer = CATextLayer()
        layer.string = text
        layer.fontSize = 11
        layer.foregroundColor = color
        layer.alignmentMode = alignment
        layer.truncationMode = .end
        layer.contentsScale = scale
        layer.frame = frame
        labels.addSublayer(layer)
    }

    private func textWidth(_ text: String) -> CGFloat {
        let font = CTFontCreateUIFontForLanguage(.system, 11, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font as Any]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private func showTooltip(_ text: String, near point: CGPoint, palette: ChartPalette) {
        let lines = text.split(separator: "\n")
        let width = (lines.map { textWidth(String($0)) * 12 / 11 }.max() ?? 80) + 20
        let height = CGFloat(lines.count) * 15 + 12
        var origin = CGPoint(x: point.x + 14, y: point.y - height - 10)
        if origin.x + width > bounds.width - 4 { origin.x = point.x - width - 14 }
        origin.y = min(max(4, origin.y), bounds.height - height - 4)
        tooltip.string = NSAttributedString(string: text, attributes: [
            .font: CTFontCreateUIFontForLanguage(.system, 12, nil) as Any, .foregroundColor: palette.text,
        ])
        tooltip.backgroundColor = ChartPalette.color(palette.surface)
        tooltip.borderColor = ChartPalette.color(palette.axis)
        tooltip.borderWidth = 1 / scale
        tooltip.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        tooltip.isHidden = false
        tooltip.setNeedsDisplay()
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline, let queue, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer() else { return }
        let surface = palette.surface
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(surface.x), green: Double(surface.y), blue: Double(surface.z), alpha: 1)
        pass.colorAttachments[0].loadAction = .clear
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if !vertices.isEmpty, let device = view.device,
           let vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<ChartVertex>.stride) {
            encoder.setRenderPipelineState(pipeline)
            var uniforms = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

private extension MTKView {
    func setNeedsDisplayCompat() {
        #if os(macOS)
        needsDisplay = true
        #else
        setNeedsDisplay()
        #endif
    }
}

/// The view the chart's text is in: over the marks, top-down, taking no clicks.
final class ChartOverlay: PlatformView {
    #if os(macOS)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif
}
