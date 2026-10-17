import AppKit

/// One proposed edit: replace `wrong` at `range` (UTF-16, in the full field text) with `right`.
struct Suggestion {
    let element: AXUIElement
    let segment: String       // the snippet that was checked
    let corrected: String     // the snippet after the fix
    let range: NSRange
    let wrong: String
    let right: String
    /// Where the checked snippet starts, and where the caret was when it was checked
    /// (the snippet is `segmentStart..<checkedCaret`).
    let segmentStart: Int
    let checkedCaret: Int
    /// The caret right now — the user may have typed on after the snippet was checked.
    var caret: Int
    /// How this field's AX range attributes count offsets (see AX.OffsetMap)
    var map = AX.OffsetMap()
    let contextBefore: String
    let contextAfter: String

    /// Diff `original` against `corrected` and return the first changed spot, or nil when
    /// there is no change or it looks like a rewrite rather than a typo fix.
    static func make(element: AXUIElement, segment original: String, corrected: String,
                     segmentStart: Int, caret: Int) -> Suggestion? {
        let a = Array(original), b = Array(corrected)
        guard a != b, !a.isEmpty else { return nil }
        func isWordChar(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

        // LCS splits "ie→ei" into two edits; merge edits separated only by a couple of letters.
        var hunks: [Hunk] = []
        for h in diffHunks(a, b) {
            if let prev = hunks.last, h.a.lowerBound - prev.a.upperBound <= 2,
               a[prev.a.upperBound..<h.a.lowerBound].allSatisfy(isWordChar) {
                hunks[hunks.count - 1] = Hunk(a: prev.a.lowerBound..<h.a.upperBound, b: prev.b.lowerBound..<h.b.upperBound)
            } else {
                hunks.append(h)
            }
        }
        guard var h = hunks.first else { return nil }

        // Typo fixes are small; anything bigger is the model rewriting.
        let changed = hunks.reduce(0) { $0 + max($1.a.count, $1.b.count) }
        if changed > max(6, a.count / 3) || hunks.contains(where: { max($0.a.count, $0.b.count) > 8 }) { return nil }

        // Widen English edits to the whole word so the bubble shows "recieve → receive".
        while h.a.lowerBound > 0, isWordChar(a[h.a.lowerBound - 1]),
              (!h.a.isEmpty && isWordChar(a[h.a.lowerBound])) || (!h.b.isEmpty && isWordChar(b[h.b.lowerBound])) {
            h.a = (h.a.lowerBound - 1)..<h.a.upperBound
            h.b = (h.b.lowerBound - 1)..<h.b.upperBound
        }
        while h.a.upperBound < a.count, h.b.upperBound < b.count, a[h.a.upperBound] == b[h.b.upperBound],
              isWordChar(a[h.a.upperBound]),
              (!h.a.isEmpty && isWordChar(a[h.a.upperBound - 1])) || (!h.b.isEmpty && isWordChar(b[h.b.upperBound - 1])) {
            h.a = h.a.lowerBound..<(h.a.upperBound + 1)
            h.b = h.b.lowerBound..<(h.b.upperBound + 1)
        }

        // Don't touch the very end when it may still be being typed.
        if h.a.upperBound == a.count {
            if h.a.isEmpty { return nil }                                   // pure append
            if let last = a.last, isWordChar(last) { return nil }           // unfinished English word
        }

        let wrong = String(a[h.a]), right = String(b[h.b])
        let offset = String(a[0..<h.a.lowerBound]).utf16.count
        return Suggestion(
            element: element,
            segment: original,
            corrected: corrected,
            range: NSRange(location: segmentStart + offset, length: wrong.utf16.count),
            wrong: wrong,
            right: right,
            segmentStart: segmentStart,
            checkedCaret: caret,
            caret: caret,
            contextBefore: String(a[max(0, h.a.lowerBound - 4)..<h.a.lowerBound]),
            contextAfter: String(a[h.a.upperBound..<min(a.count, h.a.upperBound + 4)])
        )
    }

    struct Hunk { var a: Range<Int>; var b: Range<Int> }

    /// Character-level LCS diff grouped into contiguous changed regions.
    static func diffHunks(_ a: [Character], _ b: [Character]) -> [Hunk] {
        let n = a.count, m = b.count
        guard n <= 600, m <= 600 else { return [Hunk(a: 0..<n, b: 0..<m)] }
        // lcs[i][j] = LCS length of a[i...] and b[j...]
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        var open: (Int, Int)?
        func close() {
            if let (si, sj) = open { hunks.append(Hunk(a: si..<i, b: sj..<j)); open = nil }
        }
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                close(); i += 1; j += 1
            } else {
                if open == nil { open = (i, j) }
                if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] { j += 1 } else { i += 1 }
            }
        }
        close()
        return hunks
    }

    /// Still applicable to the field as it is now: same snippet in the same place, the user has only
    /// typed on after it (or not at all).
    func stillValid(text: String, caret now: Int) -> Bool {
        Self.snippet(segment, at: segmentStart, until: checkedCaret, isIn: text, caret: now)
    }

    static func snippet(_ segment: String, at start: Int, until end: Int, isIn text: String, caret: Int) -> Bool {
        let ns = text as NSString
        guard caret >= end, ns.length >= end, end >= start else { return false }
        return ns.substring(with: NSRange(location: start, length: end - start)) == segment
    }

    var display: NSAttributedString {
        let font = NSFont.systemFont(ofSize: 14)
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let out = NSMutableAttributedString()
        func ctx(_ s: String) { out.append(NSAttributedString(string: s, attributes: plain)) }

        ctx(contextBefore)
        out.append(NSAttributedString(string: wrong.isEmpty ? "␣" : wrong, attributes: [
            .font: font, .foregroundColor: NSColor.systemRed,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        ]))
        ctx(contextAfter)
        out.append(NSAttributedString(string: "  →  ", attributes: plain))
        ctx(contextBefore)
        out.append(NSAttributedString(string: right.isEmpty ? "∅" : right, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.systemGreen,
        ]))
        ctx(contextAfter)
        return out
    }
}
