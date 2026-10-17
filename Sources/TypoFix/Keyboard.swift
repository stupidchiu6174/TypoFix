import AppKit

/// Global key interception (Tab / Esc while a suggestion is showing) and synthetic typing.
final class KeyTap {
    /// Return true to swallow the key.
    var onTab: () -> Bool = { false }
    var onEsc: () -> Bool = { false }

    fileprivate var tap: CFMachPort?
    /// Whether keys currently go through the tap. Only while a suggestion is showing: an active tap
    /// makes every keystroke system-wide wait for our main thread, which in LiriOS is also running the
    /// side panel, monitor, wallpaper and file browser — typing everywhere felt sluggish.
    fileprivate(set) var active = false

    var isRunning: Bool { tap != nil }

    func setActive(_ on: Bool) {
        guard let t = tap, on != active else { return }
        active = on
        CGEvent.tapEnable(tap: t, enable: on)
    }

    func start() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: keyTapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        // Created (so the permission is known to work) but idle until a suggestion appears.
        CGEvent.tapEnable(tap: t, enable: false)
        active = false
        return true
    }
}

private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    guard let refcon else { return pass }
    let me = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = me.tap, me.active { CGEvent.tapEnable(tap: t, enable: true) }
        return pass
    }
    guard type == .keyDown,
          event.getIntegerValueField(.eventSourceUserData) != Keyboard.marker else { return pass }

    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
    guard mods.isEmpty else { return pass }
    if code == 48, me.onTab() { return nil }   // Tab
    if code == 53, me.onEsc() { return nil }   // Esc
    return pass
}

enum Keyboard {
    /// Tags our own synthetic events so the tap ignores them.
    static let marker: Int64 = 0x7479_706F

    private static func post(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
        }
    }

    static func backspace(_ count: Int) {
        for _ in 0..<count { post(51) }
    }

    static func arrowLeft(_ count: Int) {
        for _ in 0..<count { post(123) }
    }

    static func arrowRight(_ count: Int) {
        for _ in 0..<count { post(124) }
    }

    /// Paste `text` through the clipboard, then restore the clipboard's previous contents.
    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        let changeCount = pb.changeCount

        post(9, flags: .maskCommand)   // ⌘V

        // Restore late enough that the app has surely handled ⌘V: it's queued behind the arrow/backspace
        // events, and a browser can take a while to chew through those. Restoring too early pastes the
        // user's old clipboard instead of the fix.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard pb.changeCount == changeCount else { return }   // user copied something meanwhile
            pb.clearContents()
            pb.writeObjects(saved.map { d -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (t, v) in d { item.setData(v, forType: t) }
                return item
            })
        }
    }
}
