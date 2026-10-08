import Foundation
import Security

enum Settings {
    private static let defaults = UserDefaults.standard

    /// Apps where corrections would do more harm than good (terminals, editors, password managers).
    static let builtInExcluded: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty",
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.jetbrains.intellij", "com.sublimetext.4", "dev.zed.Zed",
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords",
    ]

    static var userExcluded: Set<String> {
        get { Set(defaults.stringArray(forKey: "typofix.excludedApps") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "typofix.excludedApps") }
    }

    static func isExcluded(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return builtInExcluded.contains(id) || userExcluded.contains(id)
    }

    static var enabled: Bool {
        get { defaults.object(forKey: "typofix.enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "typofix.enabled") }
    }

    static var backend: BackendKind {
        get { BackendKind(rawValue: defaults.string(forKey: "typofix.backend") ?? "") ?? .subscription }
        set { defaults.set(newValue.rawValue, forKey: "typofix.backend") }
    }

    static var debugLog: Bool {
        get { defaults.object(forKey: "typofix.debugLog") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "typofix.debugLog") }
    }

    /// Seconds of no typing before a check is sent.
    static var delay: Double {
        get { defaults.object(forKey: "typofix.delay") as? Double ?? 0.7 }
        set { defaults.set(newValue, forKey: "typofix.delay") }
    }
}

/// API key in the login keychain; falls back to $ANTHROPIC_API_KEY when launched from a shell.
enum APIKeyStore {
    private static let service = "TypoFix"
    private static let account = "anthropic-api-key"
    private static var cached: String??

    static func load() -> String? {
        if let c = cached { return c }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        var key: String?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
            key = String(data: d, encoding: .utf8)
        }
        if key?.isEmpty ?? true { key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] }
        cached = .some(key)
        return key
    }

    static func save(_ key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        if !key.isEmpty {
            var add = base
            add[kSecValueData as String] = Data(key.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
        cached = nil
    }
}
