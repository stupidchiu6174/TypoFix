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
}
