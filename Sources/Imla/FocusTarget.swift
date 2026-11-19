import AppKit
import ApplicationServices

/// The text field that had focus when dictation started, so the text can go
/// back there even if focus moves while you talk.
@MainActor
struct FocusTarget {
    enum Capture {
        /// A focused field that takes text.
        case field(FocusTarget)
        /// The app doesn't say what has focus (Chrome, for example); target its window.
        case unknown(FocusTarget)
        /// Something has focus, and it isn't a text field.
        case notEditable
    }

    let app: NSRunningApplication
    let window: AXUIElement?
    let element: AXUIElement?
    /// The caret, or failing that a small focused field, in screen points with a top-left origin.
    let anchor: CGRect?

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    static func capture() -> Capture? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Electron apps such as Slack only build their accessibility tree when asked.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let window = element(appElement, kAXFocusedWindowAttribute)
        guard let focused = element(appElement, kAXFocusedUIElementAttribute) else {
            return .unknown(FocusTarget(app: app, window: window, element: nil, anchor: nil))
        }
        guard isEditable(focused) else { return .notEditable }
        let anchor = caretRect(focused) ?? frame(focused).flatMap { $0.height <= 120 ? $0 : nil }
        return .field(FocusTarget(app: app, window: window, element: focused, anchor: anchor))
    }

    /// Brings the original field back into focus. Returns false when it can't,
    /// so the caller doesn't paste into whatever has focus now.
    func restore() async -> Bool {
        guard !app.isTerminated else { return false }
        if isCurrent { return true }
        app.activate()
        if let window { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
        if let element { AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(50))
            if isCurrent { return true }
        }
        return false
    }

    private var isCurrent: Bool {
        guard app.isActive else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if let element {
            return Self.element(appElement, kAXFocusedUIElementAttribute).map { CFEqual($0, element) } ?? false
        }
        guard let window else { return true }
        return Self.element(appElement, kAXFocusedWindowAttribute).map { CFEqual($0, window) } ?? false
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        if let role = value(element, kAXRoleAttribute) as? String, textRoles.contains(role) { return true }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue && axValue(element, kAXSelectedTextRangeAttribute) != nil
    }

    private static func caretRect(_ element: AXUIElement) -> CGRect? {
        guard let rangeValue = axValue(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        // Some apps return an empty rect for a zero-length range; the previous character works there.
        let candidates = [CFRange(location: range.location, length: 0),
                          CFRange(location: max(0, range.location - 1), length: 1)]
        for var candidate in candidates {
            guard let param = AXValueCreate(.cfRange, &candidate) else { continue }
            var result: AnyObject?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                             param, &result) == .success,
                  let boundsValue = result, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { continue }
            var rect = CGRect.zero
            AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect)
            if rect.height > 0, rect.origin != .zero { return rect }
        }
        return nil
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let posValue = axValue(element, kAXPositionAttribute),
              let sizeValue = axValue(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    // CF types cast unconditionally in Swift, so check the CFTypeID before trusting one.
    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = value(element, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let v = value(element, attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }
}
