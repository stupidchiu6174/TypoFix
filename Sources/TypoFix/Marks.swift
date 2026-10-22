import AppKit

/// Accessibility coordinates (origin top-left of the primary screen) → Cocoa (origin bottom-left).
private func cocoa(_ r: CGRect) -> NSRect {
    let h = NSScreen.screens.first?.frame.height ?? 0
    return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
}

private func makeOverlayPanel(mouse: Bool) -> NSPanel {
    let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: true)
    p.level = .statusBar
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.ignoresMouseEvents = !mouse
    p.becomesKeyOnlyIfNeeded = true
    p.hidesOnDeactivate = false
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    return p
}

/// Click-through window over the focused field that draws a red squiggle under each typo.
final class UnderlineOverlay {
    private let panel = makeOverlayPanel(mouse: false)
    private let view = SquiggleView()

    init() { panel.contentView = view }

    /// `field` and `typos` are in Accessibility coordinates. Squiggles outside the field (scrolled away)
    /// are clipped by the window.
    func update(field: CGRect, typos: [CGRect]) {
        guard !typos.isEmpty else { hide(); return }
        let frame = cocoa(field).insetBy(dx: 0, dy: -3)   // room for squiggles on the last line
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        view.lines = typos.map { r in
            let c = cocoa(r)
            return NSRect(x: c.minX - frame.minX, y: c.minY - frame.minY - 2, width: max(c.width, 6), height: 3)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        view.lines = []
    }
}

private final class SquiggleView: NSView {
    var lines: [NSRect] = [] { didSet { if lines != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.withAlphaComponent(0.85).setStroke()
        for r in lines {
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            var x = r.minX
            path.move(to: NSPoint(x: x, y: r.minY + 1.5))
            var up = true
            while x < r.maxX {
                x = min(x + 2, r.maxX)
                path.line(to: NSPoint(x: x, y: r.minY + (up ? 3 : 0)))
                up.toggle()
            }
            path.stroke()
        }
    }
}

/// Round counter at the bottom-right corner of the focused field. Click to open the nearest typo.
final class IssueBadge {
    private let panel = makeOverlayPanel(mouse: true)
    private let button = BadgeView()
    var onClick: () -> Void = {}

    static let size: CGFloat = 20

    init() {
        panel.contentView = button
        button.onClick = { [weak self] in self?.onClick() }
    }

    /// Screen frame in Cocoa coordinates, for hover hit-testing.
    var frame: NSRect? { panel.isVisible ? panel.frame : nil }

    /// `field` in Accessibility coordinates.
    func update(count: Int, field: CGRect) {
        guard count > 0 else { hide(); return }
        let f = cocoa(field)
        let s = Self.size
        let frame = NSRect(x: f.maxX - s - 6, y: f.minY + 6, width: s, height: s)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        button.count = count
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }
}

private final class BadgeView: NSView {
    var count = 0 { didSet { if count != oldValue { needsDisplay = true } } }
    var onClick: () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
        let text = count > 99 ? "99+" : "\(count)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: count > 9 ? 9 : 11, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}
