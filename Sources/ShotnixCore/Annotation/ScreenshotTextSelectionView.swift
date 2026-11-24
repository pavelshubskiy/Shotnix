import AppKit

/// Selects recognized words in visual reading order using AppKit mouse events.
/// Geometry and drag state stay local to the canvas, including while OCR runs.
@MainActor
final class ScreenshotTextSelectionView: NSView {
    private struct Row {
        let bounds: CGRect
        let words: Range<Int>
    }

    private var words: [OCRWord] = []
    private var rows: [Row] = []
    private var rowStarts: Set<Int> = []
    private var imageSize: CGSize = .zero
    private var selection: ClosedRange<Int>? {
        didSet {
            if selection != oldValue { needsDisplay = true }
        }
    }

    private struct Drag {
        let start: CGPoint
        var end: CGPoint
        var isActive: Bool
        var hasMoved: Bool
    }

    private var drag: Drag?
    var onCopyRequested: (() -> Void)?

    override var isFlipped: Bool { true }

    var selectedText: String {
        guard let selection else { return "" }
        return selection.reduce(into: "") { text, index in
            if index != selection.lowerBound { text += rowStarts.contains(index) ? "\n" : " " }
            text += words[index].text
        }
    }

    func configure(lines: [OCRLine], imageSize: CGSize) {
        self.imageSize = imageSize
        selection = nil
        words.removeAll()
        rows.removeAll()
        rowStarts.removeAll()
        for lines in OCRLayout.rows(from: lines) {
            let start = words.count
            for line in lines {
                words += line.words.isEmpty ? [OCRWord(text: line.text, box: line.box)] : line.words
            }
            let box = lines.reduce(CGRect.null) { $0.union($1.box) }
            rows.append(Row(bounds: box, words: start..<words.count))
            rowStarts.insert(start)
        }
        updateSelection()
        if drag?.isActive == false { drag = nil }
    }

    func reset() {
        drag = nil
        selection = nil
    }

    func selectAllText() {
        drag = nil
        if !words.isEmpty { selection = 0...(words.count - 1) }
    }

    // Keep all input on the canvas, so a gesture can start before OCR or rendering finishes.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        selection = nil
        drag = Drag(start: point, end: point, isActive: true, hasMoved: event.clickCount >= 2)
        updateSelection()
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag, drag.isActive else { return }
        drag.end = convert(event.locationInWindow, from: nil)
        drag.hasMoved = true
        self.drag = drag
        updateSelection()
    }

    override func mouseUp(with event: NSEvent) {
        guard var drag, drag.isActive else { return }
        drag.end = convert(event.locationInWindow, from: nil)
        drag.isActive = false
        self.drag = drag
        updateSelection()
        // Keep a completed gesture while recognition is still in flight.
        if !words.isEmpty { self.drag = nil }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard selection != nil else { return nil }
        let menu = NSMenu()
        let item = menu.addItem(withTitle: L("Copy Text"), action: #selector(copySelection), keyEquivalent: "")
        item.target = self
        return menu
    }

    @objc private func copySelection() { onCopyRequested?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let selection, imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = CGAffineTransform(scaleX: bounds.width / imageSize.width, y: bounds.height / imageSize.height)
        NSColor.controlAccentColor.withAlphaComponent(0.32).setFill()
        for index in selection {
            let rect = words[index].box.applying(scale).insetBy(dx: -1, dy: -2)
            if rect.intersects(dirtyRect) { rect.fill() }
        }
    }

    private func updateSelection() {
        guard let drag, drag.hasMoved, !rows.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        let scale = CGAffineTransform(scaleX: imageSize.width / bounds.width, y: imageSize.height / bounds.height)
        let start = drag.start.applying(scale)
        let end = drag.end.applying(scale)
        let zoom = max(enclosingScrollView?.magnification ?? 1, 0.1)
        let startRow = nearestRow(to: start)
        let rowBounds = rows[startRow].bounds
        // Allow starting a few on-screen points into the whitespace around a line.
        let hitArea = rowBounds.insetBy(dx: -12 * scale.a / zoom, dy: -8 * scale.d / zoom)
        guard hitArea.contains(start) else { return }
        let anchor = nearestWord(to: start, in: rows[startRow])
        let focus = nearestWord(to: end, in: rows[nearestRow(to: end)])
        selection = min(anchor, focus)...max(anchor, focus)
    }

    private func nearestRow(to point: CGPoint) -> Int {
        rows.indices.min {
            let a = rows[$0].bounds
            let b = rows[$1].bounds
            return proximity(point.y, a.minY, a.maxY) < proximity(point.y, b.minY, b.maxY)
        }!
    }

    private func nearestWord(to point: CGPoint, in row: Row) -> Int {
        row.words.min {
            let a = words[$0].box
            let b = words[$1].box
            return proximity(point.x, a.minX, a.maxX) < proximity(point.x, b.minX, b.maxX)
        }!
    }

    /// A point inside a word or row ranks ahead of one beside it.
    private func proximity(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        if value < lower { return lower - value }
        if value > upper { return value - upper }
        return 0
    }
}
