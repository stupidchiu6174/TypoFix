import AppKit
import ApplicationServices

/// Thin wrappers around the Accessibility C API.
enum AX {
    static func string(_ el: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func axValue<T: BitwiseCopyable>(_ v: CFTypeRef?, _ type: AXValueType, _ empty: T) -> T? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var out = empty
        guard AXValueGetValue(v as! AXValue, type, &out) else { return nil }
        return out
    }

    static func selectedRange(_ el: AXUIElement) -> CFRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &v) == .success else { return nil }
        return axValue(v, .cfRange, CFRange())
    }

    @discardableResult
    /// The app's own text for a range (kAXStringForRangeParameterizedAttribute).
    static func stringForRange(_ el: AXUIElement, _ r: CFRange) -> String? {
        var range = r
        guard let v = AXValueCreate(.cfRange, &range) else { return nil }
        return parameterized(el, kAXStringForRangeParameterizedAttribute, v) as? String
    }

    static func setSelectedRange(_ el: AXUIElement, _ r: CFRange) -> Bool {
        var r = r
        guard let v = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    static func setSelectedText(_ el: AXUIElement, _ s: String) -> Bool {
        AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, s as CFString) == .success
    }

    /// Screen rect (top-left origin) of a text range, if the app supports it.
    /// Chromium's rich-text fields (Claude's message box) fail AXBoundsForRange; for those, go through
    /// text markers instead.
    static func bounds(_ el: AXUIElement, _ r: CFRange) -> CGRect? {
        rangeBounds(el, r) ?? markerBounds(el, r)
    }

    private static func usable(_ v: CFTypeRef?) -> CGRect? {
        guard let rect = axValue(v, .cgRect, CGRect.zero), rect.width > 0 || rect.height > 0,
              rect.origin != .zero else { return nil }
        return rect
    }

    private static func rangeBounds(_ el: AXUIElement, _ r: CFRange) -> CGRect? {
        var r = r
        guard let rv = AXValueCreate(.cfRange, &r) else { return nil }
        var v: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &v)
        guard err == .success else { noteFailure("AXBoundsForRange error \(err.rawValue)"); return nil }
        guard let rect = usable(v) else { noteFailure("AXBoundsForRange returned an empty rect"); return nil }
        return rect
    }

    private static func parameterized(_ el: AXUIElement, _ name: String, _ arg: CFTypeRef) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, name as CFString, arg, &v) == .success else { return nil }
        return v
    }

    private static func markerBounds(_ el: AXUIElement, _ r: CFRange) -> CGRect? {
        guard let start = parameterized(el, "AXTextMarkerForIndex", r.location as CFNumber),
              let end = parameterized(el, "AXTextMarkerForIndex", (r.location + r.length) as CFNumber)
        else { noteFailure("AXTextMarkerForIndex unsupported"); return nil }
        guard let range = parameterized(el, "AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray)
        else { noteFailure("AXTextMarkerRangeForUnorderedTextMarkers unsupported"); return nil }
        guard let rect = usable(parameterized(el, "AXBoundsForTextMarkerRange", range))
        else { noteFailure("AXBoundsForTextMarkerRange gave nothing"); return nil }
        return rect
    }

    // MARK: Text leaves (Chromium rich-text fields)

    /// A run of text inside a field: Chromium answers AXBoundsForRange on these even when the field
    /// itself (a contenteditable like Claude's message box) doesn't.
    struct Leaf {
        let element: AXUIElement
        let start: Int    // UTF-16 offset in the field's AXValue
        let length: Int
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr
    }

    /// The field's static-text descendants in order, each matched to where its text sits in `text`.
    static func textLeaves(_ root: AXUIElement, text: String) -> [Leaf] {
        let ns = text as NSString
        var out: [Leaf] = []
        var cursor = 0, visited = 0
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 8, visited < 400 else { return }
            visited += 1
            if string(el, kAXRoleAttribute) == kAXStaticTextRole as String,
               let v = string(el, kAXValueAttribute), !v.isEmpty {
                let r = ns.range(of: v, options: .literal, range: NSRange(location: cursor, length: ns.length - cursor))
                if r.location != NSNotFound {
                    out.append(Leaf(element: el, start: r.location, length: r.length))
                    cursor = NSMaxRange(r)
                }
                return
            }
            for c in children(el) { walk(c, depth: depth + 1) }
        }
        for c in children(root) { walk(c, depth: 0) }
        return out
    }

    /// Screen rect of `r` (AXValue offsets of the field) through the leaf holding it. When the leaf won't
    /// say either, estimate from the leaf's frame — fine for a single line.
    static func leafBounds(_ leaves: [Leaf], _ r: NSRange) -> CGRect? {
        guard let leaf = leaves.first(where: { r.location >= $0.start && r.location < $0.start + $0.length })
        else { noteFailure("no text leaf holds the typo"); return nil }
        let local = r.location - leaf.start
        let len = max(1, min(r.length, leaf.start + leaf.length - r.location))
        if let b = rangeBounds(leaf.element, CFRange(location: local, length: len)) { return b }
        guard let f = frame(leaf.element), f.width > 0, leaf.length > 0 else { noteFailure("text leaf has no frame"); return nil }
        noteFailure("estimating from the text leaf's frame")
        let unit = f.width / CGFloat(leaf.length)
        return CGRect(x: f.minX + unit * CGFloat(local), y: f.minY, width: unit * CGFloat(len), height: min(f.height, 24))
    }

    /// Log each distinct reason a bounds lookup failed, once.
    private static var notedFailures = Set<String>()
    private static func noteFailure(_ why: String) {
        guard notedFailures.insert(why).inserted else { return }
        Log.write("bounds: \(why)")
    }

    /// Screen rect (top-left origin) of the element itself.
    static func frame(_ el: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success,
              let pos = axValue(p, .cgPoint, CGPoint.zero),
              let size = axValue(s, .cgSize, CGSize.zero) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    static func numberOfCharacters(_ el: AXUIElement) -> Int? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute as CFString, &v) == .success else { return nil }
        return (v as? NSNumber)?.intValue
    }

    /// Text offsets as the app's AX range attributes count them vs. offsets into AXValue.
    ///
    /// Chromium's rich-text fields (Claude's message box, for one) put a "\n" between paragraphs in
    /// AXValue but don't count it in AXSelectedTextRange / AXNumberOfCharacters / bounds-for-range.
    /// Without converting, every position after a line break is off by one per break: a fix for
    /// "has" selected "as" and turned it into "hhave".
    struct OffsetMap {
        var skipsNewlines = false

        /// Work out which way this field counts, from its AXValue and AXNumberOfCharacters.
        static func detect(_ el: AXUIElement, text: String) -> OffsetMap {
            let ns = text as NSString
            let newlines = newlineCount(ns, upTo: ns.length)
            guard newlines > 0, let n = numberOfCharacters(el) else { return OffsetMap() }
            return OffsetMap(skipsNewlines: n == ns.length - newlines)
        }

        func toAX(_ v: Int, in text: String) -> Int {
            guard skipsNewlines else { return v }
            return v - Self.newlineCount(text as NSString, upTo: v)
        }

        func toAX(_ r: NSRange, in text: String) -> CFRange {
            let start = toAX(r.location, in: text)
            return CFRange(location: start, length: toAX(NSMaxRange(r), in: text) - start)
        }

        func toValue(_ a: Int, in text: String) -> Int {
            guard skipsNewlines else { return a }
            let ns = text as NSString
            var counted = 0, i = 0
            while i < ns.length, counted < a {
                if ns.character(at: i) != 10 { counted += 1 }
                i += 1
            }
            return i
        }

        private static func newlineCount(_ ns: NSString, upTo end: Int) -> Int {
            var n = 0
            for i in 0..<min(max(end, 0), ns.length) where ns.character(at: i) == 10 { n += 1 }
            return n
        }
    }
}
