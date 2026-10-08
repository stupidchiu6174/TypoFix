import AppKit

/// Small floating bubble near the caret. Clicking it applies the fix; it never takes focus,
/// so the caret stays in the app being typed in.
final class SuggestionPanel {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "點一下或 Tab 套用　Esc 略過")

    var isVisible: Bool { panel.isVisible }
    /// Called when the bubble is clicked.
    var onClick: () -> Void = {}

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 50),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let fx = ClickableEffectView()
        fx.onClick = { [weak self] in self?.onClick() }
        fx.material = .popover
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 8
        fx.layer?.masksToBounds = true

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [label, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor),
            stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        panel.contentView = fx
    }

    /// `anchor` is in Accessibility coordinates (origin at top-left of the primary screen).
    func show(_ text: NSAttributedString, anchor: CGRect) {
        label.attributedStringValue = text
        let size = panel.contentView!.fittingSize
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

        // Convert to Cocoa coordinates (origin bottom-left) and place just below the anchor.
        var origin = NSPoint(x: anchor.minX, y: primaryHeight - anchor.maxY - 6 - size.height)
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSPoint(x: anchor.midX, y: primaryHeight - anchor.midY))
        }) ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            if origin.y < vf.minY { origin.y = primaryHeight - anchor.minY + 6 }   // flip above
            origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - size.width - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

/// Bubble background: the whole bubble is one click target, highlighted on hover.
private final class ClickableEffectView: NSVisualEffectView {
    var onClick: () -> Void = {}
    private var hovering = false { didSet { isEmphasized = hovering; material = hovering ? .selection : .popover } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Labels inside shouldn't swallow the click.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    // set() rather than push/pop: the bubble can disappear under the pointer without a mouseExited.
    override func mouseEntered(with event: NSEvent) { hovering = true; NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { hovering = false; NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        hovering = false
        NSCursor.arrow.set()
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
}
