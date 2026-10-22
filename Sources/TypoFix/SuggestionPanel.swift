import AppKit

/// Suggestion card shown when hovering an underlined typo (or clicking the count badge).
/// Never takes focus, so the caret stays in the app being typed in.
final class SuggestionPanel {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Tab 套用　Esc 略過")

    var isVisible: Bool { panel.isVisible }
    /// Screen frame in Cocoa coordinates, for hover hit-testing.
    var frame: NSRect { panel.frame }
    var onAccept: () -> Void = {}
    var onIgnore: () -> Void = {}
    /// The pointer entered (true) or left (false) the card.
    var onHover: (Bool) -> Void = { _ in }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
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

        let fx = HoverEffectView()
        fx.onHover = { [weak self] in self?.onHover($0) }
        fx.material = .popover
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 10
        fx.layer?.masksToBounds = true

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let accept = FirstMouseButton(title: "套用", target: nil, action: nil)
        accept.onPress = { [weak self] in self?.onAccept() }
        accept.bezelStyle = .push
        accept.controlSize = .small
        accept.keyEquivalent = "\r"   // drawn as the default button; Return itself still goes to the app
        let ignore = FirstMouseButton(title: "略過", target: nil, action: nil)
        ignore.onPress = { [weak self] in self?.onIgnore() }
        ignore.bezelStyle = .push
        ignore.controlSize = .small

        let buttons = NSStackView(views: [accept, ignore, hint])
        buttons.orientation = .horizontal
        buttons.spacing = 6

        let stack = NSStackView(views: [label, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
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
        var origin = NSPoint(x: anchor.minX, y: primaryHeight - anchor.maxY - 4 - size.height)
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSPoint(x: anchor.midX, y: primaryHeight - anchor.midY))
        }) ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            if origin.y < vf.minY { origin.y = primaryHeight - anchor.minY + 4 }   // flip above
            origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - size.width - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

/// Card background: reports the pointer entering and leaving, so the card stays while it's hovered.
private final class HoverEffectView: NSVisualEffectView {
    var onHover: (Bool) -> Void = { _ in }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

/// A button that works on the first click in a panel that never becomes key.
final class FirstMouseButton: NSButton {
    var onPress: () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        highlight(true)
    }
    override func mouseUp(with event: NSEvent) {
        highlight(false)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress() }
    }
}
