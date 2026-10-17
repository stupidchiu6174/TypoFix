import AppKit
import ApplicationServices

/// What the focused text field looks like right now.
private struct FieldSnapshot {
    let element: AXUIElement
    let text: String
    let caret: Int   // UTF-16 offset, no selection
    var app = ""
    var role = ""
    var map = AX.OffsetMap()

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
    /// Apps seen ignoring AX text writes (Chrome): go straight to select + paste next time, instead of
    /// trying AX first and leaving the typo selected while waiting to see whether it took.
    private var axWriteIgnored = Set<String>()

    private static func bundleID(of el: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

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
    /// The last poll found a selection in the field — almost always an input method composing.
    private var composing = false
    /// Role of the focused field and whether it's a password field, for the last field seen
    private var fieldInfo: (element: AXUIElement, role: String, secure: Bool)?

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

        // Role / password check only when focus moves to another field: every AX call is a round trip
        // served on the other app's main thread, four times a second.
        if fieldInfo.map({ !CFEqual($0.element, el) }) ?? true {
            let role = AX.string(el, kAXRoleAttribute) ?? "?"
            let secure = AX.string(el, kAXSubroleAttribute) == kAXSecureTextFieldSubrole as String
                || role == "AXSecureTextField"
            fieldInfo = (el, role, secure)
        }
        let role = fieldInfo?.role ?? "?"
        // Never read password fields.
        if fieldInfo?.secure == true { return skip("\(bundle): password field") }

        guard let text = AX.string(el, kAXValueAttribute) else { return skip("\(bundle) \(role): no text value") }
        guard var r = AX.selectedRange(el) else { return skip("\(bundle) \(role): no caret range") }
        let map = AX.OffsetMap.detect(el, text: text)
        r.location = map.toValue(r.location, in: text)
        if r.length != 0 {
            // Usually not a real selection but the input method's unconfirmed text (Zhuyin, Japanese).
            composing = true
            return skip("\(bundle) \(role): text selected")
        }
        let len = (text as NSString).length
        guard r.location >= 0, r.location <= len else { return skip("\(bundle) \(role): caret out of range \(r.location)/\(len)") }
        guard len < 200_000 else { return skip("\(bundle) \(role): text too long (\(len))") }
        if lastSkip != "ok \(bundle) \(role)" {
            lastSkip = "ok \(bundle) \(role)"
            Log.write("reading \(bundle) \(role), len \(len)")
        }
        return FieldSnapshot(element: el, text: text, caret: r.location, app: bundle, role: role, map: map)
    }

    private func poll() {
        composing = false
        guard enabled, let snap = readFocused() else {
            if composing {
                // Mid-composition: hide the bubble (Tab / Esc belong to the input method now) but keep the
                // check that's running — resetting here dropped nearly every check while typing CJK.
                if current != nil { dismiss() }
                return
            }
            if last != nil || current != nil { reset() }
            return
        }
        if let l = last, l.sameField(snap), l.text == snap.text, l.caret == snap.caret { return }
        watchForGhostText(previous: last, now: snap)

        let textChanged = last.map { !$0.sameField(snap) || $0.text != snap.text } ?? true
        // Typing on after the caret leaves everything already checked untouched: keep the check that's
        // in flight and any suggestion that's showing. A check takes 2–4 s on the subscription backend,
        // and dropping it on every keystroke meant ~9 in 10 checks never produced anything — fixes only
        // showed up after a long pause.
        let typedOn = last.map { $0.sameField(snap) && Self.typedOn(from: $0, to: snap) } ?? false
        last = snap
        if typedOn {
            if let s = current, !s.stillValid(text: snap.text, caret: snap.caret) { dismiss() }
        } else {
            dismiss()
            corrector.cancel()
        }
        debounce?.invalidate()
        debounce = nil
        guard textChanged else { return }
        debounce = Timer.scheduledTimer(withTimeInterval: Settings.delay, repeats: false) { [weak self] _ in
            self?.check()
        }
    }

    /// The text before the old caret is unchanged and the caret didn't move back.
    private static func typedOn(from old: FieldSnapshot, to new: FieldSnapshot) -> Bool {
        let o = old.text as NSString, n = new.text as NSString
        guard new.caret >= old.caret, n.length >= old.caret, o.length >= old.caret else { return false }
        let r = NSRange(location: 0, length: old.caret)
        return o.substring(with: r) == n.substring(with: r)
    }

    // MARK: - Ghost-text detector (diagnostics)
    //
    // Reported: after sending or deleting Japanese text, the next time typing starts some of the old
    // text shows up again — not every time. Typo fix never wrote anything when it happened, so log the
    // moment it does: a field that was just emptied (or a fresh empty field) suddenly holding a piece of
    // text that was cleared a little earlier. Only the log changes; nothing is done to the field.

    private var recentlyCleared: [(text: String, app: String, at: Date)] = []
    private var lastAcceptAt: Date?

    private func watchForGhostText(previous: FieldSnapshot?, now snap: FieldSnapshot) {
        let nowTrim = snap.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prevTrim = previous?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sameField = previous.map { $0.sameField(snap) } ?? false

        // A field going from text to empty: remember what was there.
        if sameField, nowTrim.isEmpty, prevTrim.count >= 2 {
            recentlyCleared.append((prevTrim, snap.app, Date()))
            recentlyCleared.removeAll { Date().timeIntervalSince($0.at) > 600 }
            if recentlyCleared.count > 8 { recentlyCleared.removeFirst(recentlyCleared.count - 8) }
            Log.write("cleared \(snap.app) \(snap.role) 「\(Log.preview(prevTrim))」")
            return
        }

        // Text appearing in a field that was empty (or that we hadn't read yet), matching cleared text.
        guard nowTrim.count >= 2, prevTrim.isEmpty || !sameField else { return }
        guard let hit = recentlyCleared.last(where: { $0.text.contains(nowTrim) || nowTrim.contains($0.text) })
        else { return }
        let ago = Date().timeIntervalSince(hit.at)
        let accept = lastAcceptAt.map { String(format: "%.0fs ago", Date().timeIntervalSince($0)) } ?? "never"
        Log.write("GHOST? \(snap.app) \(snap.role) now 「\(Log.preview(nowTrim, 80))」"
                  + " matches text cleared \(String(format: "%.0f", ago))s ago in \(hit.app) 「\(Log.preview(hit.text, 80))」"
                  + " | sameField=\(sameField) suggestion=\(current != nil) keyTapActive=\(keyTap.active) lastAccept=\(accept)")
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
            // Use the answer as long as the snippet is still there unchanged (typing on after it is fine).
            guard let fixed, let now = self.last, now.sameField(snap),
                  Suggestion.snippet(segment, at: start, until: snap.caret, isIn: now.text, caret: now.caret),
                  var s = Suggestion.make(element: snap.element, segment: segment, corrected: fixed,
                                          segmentStart: start, caret: snap.caret)
            else {
                if fixed != nil, fixed != segment { Log.write("no suggestion (stale, or change too big / at the end)") }
                return
            }
            s.caret = now.caret
            s.map = now.map
            // Don't pop up mid-composition; the answer is cached, so the check after it ends is instant.
            if self.composing { return }
            // A newer suggestion for the same spot is already up: keep it.
            if let cur = self.current, cur.range == s.range, cur.right == s.right { return }
            self.current = s
            Log.write("suggest 「\(s.wrong)」→「\(s.right)」")
            self.panel.show(s.display, anchor: self.anchor(for: s))
            self.keyTap.setActive(true)   // Tab / Esc only need intercepting while the bubble is up
        }
    }

    private func anchor(for s: Suggestion) -> CGRect {
        let el = s.element
        let text = last?.text ?? ""
        func ax(_ r: NSRange) -> CFRange { s.map.toAX(r, in: text) }
        if s.range.length > 0, let r = AX.bounds(el, ax(s.range)) {
            return r
        }
        if s.range.location > 0, let r = AX.bounds(el, ax(NSRange(location: s.range.location - 1, length: 1))) {
            return r
        }
        if s.caret > 0, let r = AX.bounds(el, ax(NSRange(location: s.caret - 1, length: 1))) { return r }
        if let f = AX.frame(el) { return CGRect(x: f.minX, y: f.maxY - 1, width: 1, height: 1) }
        let m = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: m.x, y: h - m.y, width: 1, height: 16)
    }

    private func dismiss() {
        current = nil
        panel.hide()
        keyTap.setActive(false)
    }

    // MARK: - Applying

    private func accept() {
        guard var s = current else { return }
        dismiss()
        let el = s.element

        // Re-validate against what's in the field right now (the user may have typed on since).
        guard let text = AX.string(el, kAXValueAttribute),
              let r = AX.selectedRange(el), r.length == 0 else { NSSound.beep(); return }
        s.map = AX.OffsetMap.detect(el, text: text)
        let caret = s.map.toValue(r.location, in: text)
        guard s.stillValid(text: text, caret: caret) else { NSSound.beep(); return }
        let ns = text as NSString
        guard NSMaxRange(s.range) <= ns.length, ns.substring(with: s.range) == s.wrong else { NSSound.beep(); return }
        s.caret = caret

        let expected = ns.replacingCharacters(in: s.range, with: s.right)
        let newCaret = s.caret + s.right.utf16.count - s.wrong.utf16.count
        // Seed the cache so the next typo in the same snippet shows up without another API call.
        let segStart = s.segmentStart
        let newSegment = (s.segment as NSString).replacingCharacters(
            in: NSRange(location: s.range.location - segStart, length: s.range.length), with: s.right)
        corrector.remember(newSegment, s.corrected)

        Log.write("accept 「\(s.wrong)」→「\(s.right)」")
        lastAcceptAt = Date()
        if let id = Self.bundleID(of: el), axWriteIgnored.contains(id) {
            typeReplacement(s, in: ns)
            return
        }
        // Preferred path: replace the range through Accessibility — but only once the app confirms the
        // selection really covers the typo, so a miscounted offset can never overwrite the wrong text.
        if AX.setSelectedRange(el, s.map.toAX(s.range, in: text)), Self.selectionCovers(s, el: el, text: text),
           AX.setSelectedText(el, s.right) {
            verifyAX(s, el: el, original: text, expected: expected, newCaret: newCaret, in: ns, attempt: 0)
            return
        }
        Log.write("accept: AX unsupported, typing instead")
        AX.setSelectedRange(el, CFRange(location: s.map.toAX(s.caret, in: text), length: 0))
        typeReplacement(s, in: ns)
    }

    /// Some apps (Chrome) apply an AX write a moment later than they report it, so check a few times
    /// before deciding it was ignored — falling back too early would apply the fix twice.
    private func verifyAX(_ s: Suggestion, el: AXUIElement, original: String, expected: String,
                          newCaret: Int, in ns: NSString, attempt: Int) {
        let delays = [0.08, 0.15, 0.25]
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) {
            let now = AX.string(el, kAXValueAttribute)
            if now == expected {
                AX.setSelectedRange(el, CFRange(location: s.map.toAX(newCaret, in: expected), length: 0))
            } else if now == original {
                if attempt + 1 < delays.count {
                    self.verifyAX(s, el: el, original: original, expected: expected,
                                  newCaret: newCaret, in: ns, attempt: attempt + 1)
                    return
                }
                // App claimed success but ignored it (common in browsers): fall back to the keyboard.
                Log.write("accept: AX ignored, typing instead")
                if let id = Self.bundleID(of: el) { self.axWriteIgnored.insert(id) }
                self.typeReplacement(s, in: ns)
            }
            // Anything else: the field changed in some other way, leave it alone.
        }
    }

    /// Keyboard fallback for apps that ignore AX text writes (browsers).
    ///
    /// Preferred: select the typo through AX — Chrome honours selection changes even though it ignores
    /// AX text writes — and paste over the selection, then put the caret back through AX. No synthetic
    /// arrow keys, so nothing can race the user's typing.
    /// Otherwise: arrow back over whatever follows the typo, backspace only the typo, paste, arrow forward.
    /// Browsers don't process synthetic keys in order (⌘V goes through the menu and jumps ahead of arrows
    /// still queued behind the input method), so every step waits until the field shows it happened.
    /// If a step never shows up (the user kept typing, the app swallowed the key), stop there.
    private func typeReplacement(_ s: Suggestion, in ns: NSString) {
        let el = s.element
        let original = ns as String
        let end = NSMaxRange(s.range)
        let tailCount = ns.substring(with: NSRange(location: end, length: s.caret - end)).count
        let removed = ns.replacingCharacters(in: s.range, with: "")
        let expected = ns.replacingCharacters(in: s.range, with: s.right)
        let newCaret = s.caret + s.right.utf16.count - s.wrong.utf16.count
        let value = { AX.string(el, kAXValueAttribute) }
        /// `r` is in AXValue offsets of `text`; compared in the app's own counting.
        func selection(is r: NSRange, in text: String) -> Bool {
            let want = s.map.toAX(r, in: text)
            return AX.selectedRange(el).map { $0.location == want.location && $0.length == want.length } ?? false
        }

        func viaArrows() {
            Log.write("accept: arrows (back \(tailCount), delete \(s.wrong.count), paste \(s.right.count))")
            Keyboard.arrowLeft(tailCount)
            waitFor("move back", { selection(is: NSRange(location: end, length: 0), in: original) && value() == original }) {
                Keyboard.backspace(s.wrong.count)
                self.waitFor("delete typo", { value() == removed }) {
                    Keyboard.paste(s.right)
                    self.waitFor("paste fix", { value() == expected }) {
                        Keyboard.arrowRight(tailCount)
                    }
                }
            }
        }

        // The AX attempt may have left the typo selected already; (re)select it either way.
        _ = AX.setSelectedRange(el, s.map.toAX(s.range, in: original))
        waitFor("select typo", { selection(is: s.range, in: original) && value() == original }, tries: 5, then: {
            // Last check before writing: the selection must hold exactly the typo.
            guard Self.selectionCovers(s, el: el, text: original) else {
                Log.write("accept: selection doesn't match the typo, not touching the text")
                _ = AX.setSelectedRange(el, CFRange(location: s.map.toAX(s.caret, in: original), length: 0))
                NSSound.beep()
                return
            }
            Log.write("accept: select + paste")
            Keyboard.paste(s.right)
            self.waitFor("paste fix", { value() == expected }) {
                _ = AX.setSelectedRange(el, CFRange(location: s.map.toAX(newCaret, in: expected), length: 0))
                // Caret not movable through AX after all: walk it back to where the user was typing.
                self.waitFor("restore caret", { selection(is: NSRange(location: newCaret, length: 0), in: expected) },
                             tries: 5, then: {}, otherwise: { Keyboard.arrowRight(tailCount) })
            }
        }, otherwise: {
            // Selection can't be set through AX: put the caret back where the user left it, use arrows.
            _ = AX.setSelectedRange(el, CFRange(location: s.map.toAX(s.caret, in: original), length: 0))
            viaArrows()
        })
    }

    /// The app's current selection holds exactly the typo (or, for an insertion, sits right after the
    /// character the fix goes after). Read back from the app rather than trusting our own offsets.
    private static func selectionCovers(_ s: Suggestion, el: AXUIElement, text: String) -> Bool {
        guard let sel = AX.selectedRange(el) else { return false }
        if !s.wrong.isEmpty {
            return AX.string(el, kAXSelectedTextAttribute) == s.wrong
        }
        // Insertion: nothing to read back in an empty selection; check the character before it instead.
        let ns = text as NSString
        guard sel.length == 0, s.range.location > 0 else { return sel.length == 0 }
        let before = ns.substring(with: NSRange(location: s.range.location - 1, length: 1))
        var probe = CFRange(location: sel.location - 1, length: 1)
        guard let v = AXValueCreate(.cfRange, &probe) else { return false }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            el, kAXStringForRangeParameterizedAttribute as CFString, v, &out) == .success else { return true }
        return (out as? String) == before
    }

    /// Poll `done` every 30 ms (40 tries ≈ 1.2 s); run `then` once it holds. When it never does,
    /// run `otherwise` if given, else log, beep and give up.
    private func waitFor(_ step: String, _ done: @escaping () -> Bool, tries: Int = 40,
                         then: @escaping () -> Void, otherwise: (() -> Void)? = nil) {
        if done() { then(); return }
        guard tries > 0 else {
            if let otherwise {
                Log.write("accept: \(step) didn't take, trying another way")
                otherwise()
            } else {
                Log.write("accept: gave up at \(step)")
                NSSound.beep()
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            self.waitFor(step, done, tries: tries - 1, then: then, otherwise: otherwise)
        }
    }
}
