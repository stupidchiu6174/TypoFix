import Foundation

/// Plain-text diagnostics at ~/Library/Logs/TypoFix.log (toggle in the menu).
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TypoFix.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static var lastLine = ""

    static func write(_ message: String) {
        guard Settings.debugLog, message != lastLine else { return }
        lastLine = message
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    }

    /// Short, single-line preview of typed text.
    static func preview(_ s: String, _ n: Int = 40) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count > n ? "…" + flat.suffix(n) : flat
    }
}
