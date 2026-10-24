import Cocoa
import ApplicationServices
import InputCore

struct SelectedTextSnapshot {
    let element: AXUIElement
    let pid: pid_t
    let range: NSRange
    let text: String
    let writable: Bool
    let directWrite: Bool

    func matches(_ other: SelectedTextSnapshot) -> Bool {
        pid == other.pid && CFEqual(element, other.element) && range == other.range && text == other.text && other.writable
    }
}

struct TextSnapshot {
    let element: AXUIElement
    let pid: pid_t
    let before: String
    let after: String
    let caret: Int
}

enum TextValidationIssue: String {
    case unreadable = "입력란 조회 실패"
    case tokenMismatch = "입력 단어 불일치"
    case invalidBoundary = "단어 시작 경계 불일치"
    case staleContinuation = "이어쓰기 위치 불일치"
}

/// Only created after CapsFlow has explicitly replaced text. Allows the next
/// typed Roman run to follow that known replacement without requiring a space.
struct TextContinuation {
    let element: AXUIElement
    let pid: pid_t
    let caret: Int
    let suffix: String

    static func afterReplacing(_ snapshot: TextSnapshot, original: String, replacement: String, delimiter: String) -> TextContinuation? {
        guard delimiter.isEmpty, !replacement.isEmpty else { return nil }
        return TextContinuation(element: snapshot.element, pid: snapshot.pid,
                                caret: snapshot.caret - original.utf16.count + replacement.utf16.count,
                                suffix: replacement)
    }
}

enum AccessibilityContext {
    // Called only on context workers, never inside the keyboard event tap.
    private static var prepared: [pid_t: URL] = [:]
    private static let preparedLock = NSLock()
    static func prepare(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid), let url = app.bundleURL else { return }
        preparedLock.lock()
        let alreadyPrepared = prepared[pid] == url
        preparedLock.unlock()
        guard !alreadyPrepared else { return }
        let frameworks = url.appendingPathComponent("Contents/Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        guard names.contains(where: { $0.contains("Electron") || $0.contains("Chromium") || $0.contains("Chrome Framework") || $0.contains("Codex Framework") }) else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.06)
        // Electron's documented opt-in exposes contenteditable caret/text APIs.
        // This is not a TCC permission grant and does not launch/restart the app.
        if AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
            preparedLock.lock()
            prepared[pid] = url
            preparedLock.unlock()
        }
    }
    private static func isSecure(_ element: AXUIElement) -> Bool {
        for attribute in [kAXRoleAttribute, kAXSubroleAttribute] {
            var value: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if (value as? String)?.contains("Secure") == true { return true }
        }
        var protected: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, "AXProtectedContent" as CFString, &protected)
        return (protected as? Bool) == true
    }
    private static func focusedField(pid: pid_t) -> AXUIElement? {
        prepare(pid: pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.06)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let focusedElement = focused as! AXUIElement
        // Rich editors sometimes focus an inner text node. Walk only toward an
        // actual text field/area, never read the entire page or scan other fields.
        var candidate = focusedElement
        var field: AXUIElement?
        for _ in 0..<5 {
            AXUIElementSetMessagingTimeout(candidate, 0.06)
            guard !isSecure(candidate) else { return nil }
            var role: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(candidate, kAXRoleAttribute as CFString, &role)
            if let role = role as? String, role == kAXTextAreaRole || role == kAXTextFieldRole || role == kAXComboBoxRole {
                field = candidate; break
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(candidate, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            candidate = parent as! AXUIElement
        }
        guard let element = field else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.06)
        return element
    }

    static func selectedText(pid: pid_t) -> SelectedTextSnapshot? {
        guard let element = focusedField(pid: pid) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0,
              range.length >= 0, range.length <= SelectionConversion.maximumUTF16,
              range.location <= Int.max - range.length else { return nil }
        var writable: DarwinBoolean = false, direct: DarwinBoolean = false
        _ = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &direct)
        _ = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &writable)
        let nsRange = NSRange(location: range.location, length: range.length)
        if range.length == 0 {
            return SelectedTextSnapshot(element: element, pid: pid, range: nsRange, text: "", writable: writable.boolValue || direct.boolValue, directWrite: direct.boolValue)
        }
        var selected: CFTypeRef?
        if let request = AXValueCreate(.cfRange, &range) {
            _ = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, request, &selected)
        }
        if selected as? String == nil {
            _ = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected)
        }
        guard let text = selected as? String, text.utf16.count == range.length else { return nil }
        return SelectedTextSnapshot(element: element, pid: pid, range: nsRange, text: text,
                                    writable: writable.boolValue || direct.boolValue, directWrite: direct.boolValue)
    }

    static func read(pid: pid_t, limit: Int = 2200) -> TextSnapshot? {
        guard let element = focusedField(pid: pid) else { return nil }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection), selection.length == 0, selection.location >= 0 else { return nil }
        let start = max(0, selection.location - limit)
        var requestRange = CFRange(location: start, length: selection.location - start)
        guard let request = AXValueCreate(.cfRange, &requestRange) else { return nil }
        var prefix: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, request, &prefix)
        var before = prefix as? String
        var after = ""
        if result != .success || before == nil {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
                  let text = value as? String, selection.location <= (text as NSString).length else { return nil }
            let ns = text as NSString
            before = ns.substring(with: NSRange(location: start, length: selection.location - start))
            if selection.location < ns.length { after = ns.substring(with: NSRange(location: selection.location, length: 1)) }
        } else {
            var nextRange = CFRange(location: selection.location, length: 1)
            if let next = AXValueCreate(.cfRange, &nextRange) {
                var nextValue: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, next, &nextValue) == .success {
                    after = nextValue as? String ?? ""
                }
            }
        }
        return TextSnapshot(element: element, pid: pid, before: before ?? "", after: after, caret: selection.location)
    }

    static func selectionReplacementVisible(_ original: SelectedTextSnapshot, replacement: String) -> Bool {
        guard let field = focusedField(pid: original.pid), CFEqual(field, original.element) else { return false }
        var range = CFRange(location: original.range.location, length: replacement.utf16.count)
        guard let request = AXValueCreate(.cfRange, &range) else { return false }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString, request, &text) == .success else { return false }
        return text as? String == replacement
    }

    static func validates(_ snapshot: TextSnapshot, token: String, continuation: TextContinuation? = nil) -> Bool {
        validationIssue(snapshot, token: token, continuation: continuation) == nil
    }

    static func validationIssue(_ snapshot: TextSnapshot, token: String, continuation: TextContinuation? = nil) -> TextValidationIssue? {
        guard !token.isEmpty, snapshot.before.hasSuffix(token) else { return .tokenMismatch }
        let prefix = snapshot.before.dropLast(token.count)
        // Never convert only the newly typed suffix of an existing word/identifier.
        // Existing text to the right is not part of the replacement. Only the
        // exact typed run on the left is backspaced; no forward deletion occurs.
        if let previous = prefix.last, previous.isLetter || previous.isNumber || "_/@\\`".contains(previous) {
            guard let continuation else { return .invalidBoundary }
            guard !continuation.suffix.isEmpty,
                  snapshot.pid == continuation.pid, CFEqual(snapshot.element, continuation.element),
                  snapshot.caret == continuation.caret + token.utf16.count,
                  prefix.hasSuffix(continuation.suffix) else { return .staleContinuation }
        }
        return nil
    }

    static func validatesReplacement(_ snapshot: TextSnapshot, element: AXUIElement, caret: Int, original: String, continuation: TextContinuation? = nil) -> Bool {
        snapshot.caret == caret && CFEqual(snapshot.element, element) && validates(snapshot, token: original, continuation: continuation)
    }

    // Only queried on the context worker for suggestions, not the typing tap.
    static func caretBounds(_ snapshot: TextSnapshot) -> CGRect? {
        for range in [CFRange(location: snapshot.caret, length: 0), CFRange(location: max(0, snapshot.caret - 1), length: min(1, snapshot.caret))] {
            var range = range
            guard let request = AXValueCreate(.cfRange, &range) else { continue }
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(snapshot.element, kAXBoundsForRangeParameterizedAttribute as CFString, request, &result) == .success,
                  let result, CFGetTypeID(result) == AXValueGetTypeID() else { continue }
            var bounds = CGRect.zero
            if AXValueGetValue(result as! AXValue, .cgRect, &bounds), bounds.height > 0,
               bounds.width.isFinite, bounds.height.isFinite, bounds.minX.isFinite, bounds.minY.isFinite { return bounds }
        }
        // Some rich editors expose text/caret but not per-character bounds.
        // Use only that same focused field's upper edge, never another field.
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(snapshot.element, kAXPositionAttribute as CFString, &positionValue) == .success,
           AXUIElementCopyAttributeValue(snapshot.element, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let positionValue, let sizeValue,
           CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            var position = CGPoint.zero, size = CGSize.zero
            if AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
               AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
               position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
               size.width > 0, size.height > 0 {
                return CGRect(x: position.x + 10, y: position.y, width: 1, height: min(18, size.height))
            }
        }
        return nil
    }
}
