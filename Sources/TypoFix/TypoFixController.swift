import AppKit
import ApplicationServices

/// 打字修正的選單列圖示與引擎。LiriOS 啟動時呼叫 start(),結束時呼叫 shutdown()。
public final class TypoFixController: NSObject, NSMenuDelegate {
    private let engine = Engine()
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?

    public override init() { super.init() }

    /// 是否啟用修正(與選單列圖示的「啟用」同步)
    public var enabled: Bool {
        get { engine.enabled }
        set { engine.enabled = newValue; updateIcon() }
    }

    public func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        engine.onStatusChange = { [weak self] in self?.updateIcon() }

        if !engine.start() {
            // Shows the system prompt that links to Privacy & Security → Accessibility.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                guard let self, self.engine.start() else { return }
                t.invalidate()
                self.updateIcon()
            }
        }
        if Settings.backend == .api, APIKeyStore.load()?.isEmpty ?? true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.askForKey() }
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let name: String
        if !AXIsProcessTrusted() || !engine.keyTapRunning || engine.corrector.lastError != nil { name = "exclamationmark.triangle" }
        else if !engine.enabled { name = "pause.circle" }
        else if engine.status == "檢查中…" { name = "ellipsis.circle" }
        else { name = "character.cursor.ibeam" }
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "LiriOS 打字修正")
        button.image?.isTemplate = true
    }

    // MARK: - Menu

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "打字修正（Claude Haiku 4.5・\(Settings.backend == .api ? "API" : "訂閱")）",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let statusLine: String
        if !AXIsProcessTrusted() { statusLine = "⚠️ 需要「輔助使用」權限" }
        else if !engine.keyTapRunning { statusLine = "⚠️ Tab 無法攔截：請開啟「輸入監控」權限" }
        else if !engine.enabled { statusLine = "已暫停" }
        else { statusLine = "狀態：\(engine.status)" }
        let s = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        s.isEnabled = false
        menu.addItem(s)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "啟用", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = engine.enabled ? .on : .off
        toggle.target = self
        menu.addItem(toggle)

        if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
           app.processIdentifier != getpid() {
            let name = app.localizedName ?? id
            let builtIn = Settings.builtInExcluded.contains(id)
            let off = Settings.isExcluded(id)
            let item = NSMenuItem(title: builtIn ? "「\(name)」預設不修正" : "在「\(name)」停用",
                                  action: builtIn ? nil : #selector(toggleApp(_:)), keyEquivalent: "")
            item.state = off ? .on : .off
            item.representedObject = id
            item.target = self
            menu.addItem(item)
        }

        let backendMenu = NSMenu()
        for kind in [BackendKind.subscription, .api] {
            let i = NSMenuItem(title: kind.title, action: #selector(setBackend(_:)), keyEquivalent: "")
            i.representedObject = kind.rawValue
            i.state = Settings.backend == kind ? .on : .off
            i.target = self
            backendMenu.addItem(i)
        }
        let backendItem = NSMenuItem(title: "使用方式", action: nil, keyEquivalent: "")
        backendItem.submenu = backendMenu
        menu.addItem(backendItem)

        let delayMenu = NSMenu()
        for d in [0.4, 0.7, 1.0, 1.5] {
            let i = NSMenuItem(title: String(format: "停頓 %.1f 秒", d), action: #selector(setDelay(_:)), keyEquivalent: "")
            i.representedObject = d
            i.state = abs(Settings.delay - d) < 0.01 ? .on : .off
            i.target = self
            delayMenu.addItem(i)
        }
        let delayItem = NSMenuItem(title: "觸發時機", action: nil, keyEquivalent: "")
        delayItem.submenu = delayMenu
        menu.addItem(delayItem)

        menu.addItem(.separator())
        menu.addItem(item("設定 API Key…", #selector(askForKey)))
        if !AXIsProcessTrusted() { menu.addItem(item("開啟輔助使用設定…", #selector(openAXSettings))) }
        else if !engine.keyTapRunning { menu.addItem(item("開啟輸入監控設定…", #selector(openInputMonitoringSettings))) }
        let log = item("記錄除錯日誌", #selector(toggleLog))
        log.state = Settings.debugLog ? .on : .off
        menu.addItem(log)
        menu.addItem(item("打開日誌", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item("結束 LiriOS", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleEnabled() {
        engine.enabled.toggle()
        updateIcon()
    }

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var set = Settings.userExcluded
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        Settings.userExcluded = set
    }

    @objc private func setBackend(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = BackendKind(rawValue: raw) else { return }
        Settings.backend = kind
        engine.corrector.switchTo(kind)
        if kind == .api, APIKeyStore.load()?.isEmpty ?? true { askForKey() }
        updateIcon()
    }

    @objc private func setDelay(_ sender: NSMenuItem) {
        if let d = sender.representedObject as? Double { Settings.delay = d }
    }

    @objc private func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func toggleLog() { Settings.debugLog.toggle() }

    @objc private func openLog() {
        Log.write("open log")
        NSWorkspace.shared.open(Log.url)
    }

    @objc private func askForKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "設定 Anthropic API Key"
        alert.informativeText = "到 console.anthropic.com 建立 API Key 後貼上。Key 會存在你的鑰匙圈（Keychain）。"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "儲存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            APIKeyStore.save(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            updateIcon()
        }
    }

    /// 結束背景的 Claude Code 程序(LiriOS 結束時呼叫)
    public func shutdown() {
        engine.corrector.shutdown()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
