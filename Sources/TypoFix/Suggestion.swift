import AppKit

/// One proposed edit: replace `wrong` at `range` (UTF-16, in the full field text) with `right`.
struct Suggestion {
    let element: AXUIElement
    let segment: String       // the snippet that was checked
    let corrected: String     // the snippet after the fix
    /// Moves as the user edits elsewhere in the field (see `relocated(in:)`).
    var range: NSRange
    let wrong: String
    let right: String
    /// Where the checked snippet starts, and where the caret was when it was checked
    /// (the snippet is `segmentStart..<checkedCaret`).
    let segmentStart: Int
    /// Where the typo sat inside the snippet (`range` moves, this doesn't).
    let segmentOffset: Int
    let checkedCaret: Int
    /// The caret right now — the user may have typed on after the snippet was checked.
    var caret: Int
    /// How this field's AX range attributes count offsets (see AX.OffsetMap)
    var map = AX.OffsetMap()
    let contextBefore: String
    let contextAfter: String

    /// Diff `original` against `corrected` and return every changed spot, or nothing when there is no
    /// change or it looks like a rewrite rather than typo fixes.
    static func all(element: AXUIElement, segment original: String, corrected: String,
                    segmentStart: Int, caret: Int) -> [Suggestion] {
        let a = Array(original), b = Array(corrected)
        guard a != b, !a.isEmpty else { return [] }
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
        guard !hunks.isEmpty else { return [] }

        // Typo fixes are small; anything bigger is the model rewriting.
        let changed = hunks.reduce(0) { $0 + max($1.a.count, $1.b.count) }
        if changed > max(6, a.count / 3) || hunks.contains(where: { max($0.a.count, $0.b.count) > 8 }) { return [] }

        var widened: [Hunk] = []
        for var h in hunks {
            // Widen English edits to the whole word so the card shows "recieve → receive".
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
            // Two edits in one word end up overlapping once widened: one issue.
            if let prev = widened.last, h.a.lowerBound <= prev.a.upperBound {
                widened[widened.count - 1] = Hunk(a: prev.a.lowerBound..<max(prev.a.upperBound, h.a.upperBound),
                                                  b: prev.b.lowerBound..<max(prev.b.upperBound, h.b.upperBound))
            } else {
                widened.append(h)
            }
        }

        return widened.compactMap { h in
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
                segmentOffset: offset,
                checkedCaret: caret,
                caret: caret,
                contextBefore: String(a[max(0, h.a.lowerBound - 4)..<h.a.lowerBound]),
                contextAfter: String(a[h.a.upperBound..<min(a.count, h.a.upperBound + 4)])
            )
        }
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

    /// Identifies "this fix at this spot" for ignoring, independent of where it has moved to.
    var key: String { contextBefore + "\u{1}" + wrong + "\u{1}" + contextAfter + "\u{1}" + right }

    /// The same typo in `text` after edits elsewhere: found by its surrounding context, nearest to where
    /// it was. Nil once the typo or the few characters around it have been edited.
    func relocated(in text: String) -> Suggestion? {
        let ns = text as NSString
        let needle = contextBefore + wrong + contextAfter
        let lead = contextBefore.utf16.count
        let expected = range.location - lead
        if expected >= 0, expected + needle.utf16.count <= ns.length,
           ns.substring(with: NSRange(location: expected, length: needle.utf16.count)) == needle { return self }
        var best: Int?
        var from = 0
        while from < ns.length {
            let r = ns.range(of: needle, options: .literal, range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound { break }
            if best.map({ abs(r.location - expected) < abs($0 - expected) }) ?? true { best = r.location }
            from = r.location + 1
        }
        guard let best else { return nil }
        var s = self
        s.range.location = best + lead
        return s
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
