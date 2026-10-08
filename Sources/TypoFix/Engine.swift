import AppKit
import ApplicationServices

/// What the focused text field looks like right now.
private struct FieldSnapshot {
    let element: AXUIElement
    let text: String
    let caret: Int   // UTF-16 offset, no selection

    func sameField(_ o: FieldSnapshot) -> Bool { CFEqual(element, o.element) }
}

/// Watches the focused text field, debounces, asks Claude, shows / applies suggestions.
final class Engine {
    let corrector = Corrector(kind: Settings.backend)
    private let panel = SuggestionPanel()
    private let keyTap = KeyTap()

    private var pollTimer: Timer?
    private var debounce: Timer?
    private var last: FieldSnapshot?
    private var current: Suggestion?
    private var ignored = Set<String>()
    private var touchedPids = Set<pid_t>()

    /// Short status line for the menu.
    private(set) var status = "就緒"
    var onStatusChange: () -> Void = {}

    var enabled: Bool = Settings.enabled {
        didSet {
            Settings.enabled = enabled
            if !enabled { reset() }
        }
    }

    init() {
        panel.onClick = { [weak self] in
            guard let self, self.current != nil else { return }
            self.accept()
        }
        keyTap.onTab = { [weak self] in
            guard let self, self.current != nil, self.panel.isVisible else { return false }
            DispatchQueue.main.async { self.accept() }
            return true
        }
        keyTap.onEsc = { [weak self] in
            guard let self, let s = self.current, self.panel.isVisible else { return false }
            self.ignored.insert(s.segment)
            DispatchQueue.main.async { self.dismiss() }
            return true
        }
    }

    /// True once the global Tab / Esc interception is running.
    var keyTapRunning: Bool { keyTap.isRunning }
    private var askedListenAccess = false

    /// Returns false until both Accessibility and the key tap are working; safe to call repeatedly.
    @discardableResult
    func start() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        if pollTimer == nil {
            Log.write("start: accessibility OK, polling")
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        }
        if keyTap.isRunning { return true }
        if keyTap.start() {
            Log.write("start: key tap OK")
            return true
        }
        Log.write("start: key tap FAILED (Input Monitoring?)")
        if !askedListenAccess {
            askedListenAccess = true
            CGRequestListenEventAccess()
        }
        return false
    }

    private func setStatus(_ s: String) {
        status = s
        onStatusChange()
    }

    // MARK: - Watching

    private var lastSkip = ""

    private func skip(_ reason: String) -> FieldSnapshot? {
        if reason != lastSkip {
            lastSkip = reason
            Log.write("skip: \(reason)")
        }
        return nil
    }

    private func readFocused() -> FieldSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return skip("no frontmost app") }
        let bundle = app.bundleIdentifier ?? "?"
        if app.processIdentifier == getpid() { return skip("self") }
        if Settings.isExcluded(app.bundleIdentifier) { return skip("excluded app \(bundle)") }
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        if !touchedPids.contains(pid) {
            // Electron apps only expose their text to Accessibility when asked to.
            touchedPids.insert(pid)
            AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        guard let el = AX.element(appEl, kAXFocusedUIElementAttribute) else { return skip("\(bundle): no focused element") }
        AXUIElementSetMessagingTimeout(el, 0.25)

        // Never read password fields.
        let role = AX.string(el, kAXRoleAttribute) ?? "?"
        if AX.string(el, kAXSubroleAttribute) == kAXSecureTextFieldSubrole as String || role == "AXSecureTextField" {
            return skip("\(bundle): password field")
        }

        guard let text = AX.string(el, kAXValueAttribute) else { return skip("\(bundle) \(role): no text value") }
        guard let r = AX.selectedRange(el) else { return skip("\(bundle) \(role): no caret range") }
        if r.length != 0 { return skip("\(bundle) \(role): text selected") }
        let len = (text as NSString).length
        guard r.location >= 0, r.location <= len else { return skip("\(bundle) \(role): caret out of range \(r.location)/\(len)") }
        guard len < 200_000 else { return skip("\(bundle) \(role): text too long (\(len))") }
        if lastSkip != "ok \(bundle) \(role)" {
            lastSkip = "ok \(bundle) \(role)"
            Log.write("reading \(bundle) \(role), len \(len)")
        }
        return FieldSnapshot(element: el, text: text, caret: r.location)
    }

    private func poll() {
        guard enabled, let snap = readFocused() else {
            if last != nil || current != nil { reset() }
            return
        }
        if let l = last, l.sameField(snap), l.text == snap.text, l.caret == snap.caret { return }

        let textChanged = last.map { !$0.sameField(snap) || $0.text != snap.text } ?? true
        last = snap
        dismiss()
        corrector.cancel()
        debounce?.invalidate()
        debounce = nil
        guard textChanged else { return }
        debounce = Timer.scheduledTimer(withTimeInterval: Settings.delay, repeats: false) { [weak self] _ in
            self?.check()
        }
    }

    private func reset() {
        last = nil
        debounce?.invalidate()
        debounce = nil
        corrector.cancel()
        dismiss()
    }

    // MARK: - Checking

    /// The snippet we send: from the start of the caret's line (max 300 UTF-16 units back) up to the caret.
    private func segmentStart(in ns: NSString, caret: Int) -> Int {
        let nl = ns.rangeOfCharacter(from: .newlines, options: .backwards,
                                     range: NSRange(location: 0, length: caret))
        var start = nl.location == NSNotFound ? 0 : nl.location + nl.length
        start = max(start, caret - 300)
        if start > 0, start < ns.length {
            let r = ns.rangeOfComposedCharacterSequence(at: start)
            if r.location < start { start = r.location + r.length }   // don't split emoji / surrogates
        }
        return start
    }

    private func check() {
        guard enabled, let snap = last else { return }
        let ns = snap.text as NSString
        let start = segmentStart(in: ns, caret: snap.caret)
        guard snap.caret > start else { return }
        let segment = ns.substring(with: NSRange(location: start, length: snap.caret - start))
        guard segment.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
              !ignored.contains(segment) else { return }

        setStatus("檢查中…")
        Log.write("check 「\(Log.preview(segment))」")
        let sentAt = Date()
        corrector.correct(segment) { [weak self] fixed in
            guard let self else { return }
            self.setStatus(self.corrector.lastError ?? "就緒")
            Log.write(String(format: "result %.2fs 「%@」%@", Date().timeIntervalSince(sentAt),
                             Log.preview(fixed ?? "nil"), self.corrector.lastError.map { " error: " + $0 } ?? ""))
            // Drop the answer if the user kept typing.
            guard let fixed, let now = self.last, now.sameField(snap),
                  now.text == snap.text, now.caret == snap.caret,
                  let s = Suggestion.make(element: snap.element, segment: segment, corrected: fixed,
                                          segmentStart: start, caret: snap.caret)
            else {
                if fixed != nil, fixed != segment { Log.write("no suggestion (stale, or change too big / at the end)") }
                return
            }
            self.current = s
            Log.write("suggest 「\(s.wrong)」→「\(s.right)」")
            self.panel.show(s.display, anchor: self.anchor(for: s))
        }
    }

    private func anchor(for s: Suggestion) -> CGRect {
        let el = s.element
        if s.range.length > 0, let r = AX.bounds(el, CFRange(location: s.range.location, length: s.range.length)) {
            return r
        }
        if s.range.location > 0, let r = AX.bounds(el, CFRange(location: s.range.location - 1, length: 1)) {
            return r
        }
        if s.caret > 0, let r = AX.bounds(el, CFRange(location: s.caret - 1, length: 1)) { return r }
        if let f = AX.frame(el) { return CGRect(x: f.minX, y: f.maxY - 1, width: 1, height: 1) }
        let m = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: m.x, y: h - m.y, width: 1, height: 16)
    }

    private func dismiss() {
        current = nil
        panel.hide()
    }

    // MARK: - Applying

    private func accept() {
        guard let s = current else { return }
        dismiss()
        let el = s.element

        // Re-validate against what's in the field right now.
        guard let text = AX.string(el, kAXValueAttribute),
              let r = AX.selectedRange(el), r.location == s.caret, r.length == 0 else { NSSound.beep(); return }
        let ns = text as NSString
        guard NSMaxRange(s.range) <= ns.length, ns.substring(with: s.range) == s.wrong else { NSSound.beep(); return }

        let expected = ns.replacingCharacters(in: s.range, with: s.right)
        let newCaret = s.caret + s.right.utf16.count - s.wrong.utf16.count
        // Seed the cache so the next typo in the same snippet shows up without another API call.
        let segStart = s.caret - s.segment.utf16.count
        let newSegment = (s.segment as NSString).replacingCharacters(
            in: NSRange(location: s.range.location - segStart, length: s.range.length), with: s.right)
        corrector.remember(newSegment, s.corrected)

        Log.write("accept 「\(s.wrong)」→「\(s.right)」")
        // Preferred path: replace the range through Accessibility.
        if AX.setSelectedRange(el, CFRange(location: s.range.location, length: s.range.length)),
           AX.setSelectedText(el, s.right) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                let now = AX.string(el, kAXValueAttribute)
                if now == expected {
                    AX.setSelectedRange(el, CFRange(location: newCaret, length: 0))
                } else if now == text {
                    // App claimed success but ignored it (common in browsers): fall back to typing.
                    Log.write("accept: AX ignored, typing instead")
                    AX.setSelectedRange(el, CFRange(location: s.caret, length: 0))
                    self.typeReplacement(s, in: ns)
                }
                // Anything else: the field changed in some other way, leave it alone.
            }
            return
        }
        Log.write("accept: AX unsupported, typing instead")
        AX.setSelectedRange(el, CFRange(location: s.caret, length: 0))
        typeReplacement(s, in: ns)
    }

    /// Fallback: backspace from the caret to the start of the typo, then paste the fixed text + what followed it.
    private func typeReplacement(_ s: Suggestion, in ns: NSString) {
        let end = NSMaxRange(s.range)
        let deleted = ns.substring(with: NSRange(location: s.range.location, length: s.caret - s.range.location))
        let tail = ns.substring(with: NSRange(location: end, length: s.caret - end))
        Keyboard.backspace(deleted.count)
        Keyboard.paste(s.right + tail)
    }
}
