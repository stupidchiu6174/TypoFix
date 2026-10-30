import AppKit
import TypoFix

// 單獨執行打字修正:只有選單列圖示,沒有 Dock 圖示
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = TypoFixController()
controller.start()
app.run()
