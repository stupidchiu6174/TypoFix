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
    static func setSelectedRange(_ el: AXUIElement, _ r: CFRange) -> Bool {
        var r = r
        guard let v = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    static func setSelectedText(_ el: AXUIElement, _ s: String) -> Bool {
        AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, s as CFString) == .success
    }

    /// Screen rect (top-left origin) of a text range, if the app supports it.
    static func bounds(_ el: AXUIElement, _ r: CFRange) -> CGRect? {
        var r = r
        guard let rv = AXValueCreate(.cfRange, &r) else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            el, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &v) == .success else { return nil }
        guard let rect = axValue(v, .cgRect, CGRect.zero), rect.width > 0 || rect.height > 0,
              rect.origin != .zero else { return nil }
        return rect
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
