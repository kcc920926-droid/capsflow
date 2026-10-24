import Cocoa
import Carbon
import InputMethodKit
import InputCore

final class NativeClient: CompositionClient {
    let client: IMKTextInput
    private let markedAttributes: [NSAttributedString.Key: Any]
    init(_ client: IMKTextInput, markedAttributes: [NSAttributedString.Key: Any] = [:]) {
        self.client = client; self.markedAttributes = markedAttributes
    }
    var selection: NSRange {
        InputHealth.shared.phase("selection.begin")
        let range = client.selectedRange()
        InputHealth.shared.phase("selection.end", count: CompositionSession.validInsertionRange(range) ? "validSelections" : "invalidSelections")
        return range
    }
    var marked: NSRange {
        InputHealth.shared.phase("markedRange.begin")
        let range = client.markedRange()
        InputHealth.shared.phase("markedRange.end", count: CompositionSession.validInsertionRange(range) ? "validMarks" : "invalidMarks")
        return range
    }
    var documentLength: Int? {
        InputHealth.shared.phase("length.begin")
        let length = client.length()
        InputHealth.shared.phase("length.end")
        return length >= 0 && length != NSNotFound ? length : nil
    }
    func substring(_ range: NSRange) -> String? {
        guard range.location != NSNotFound, range.length <= SelectionConversion.maximumUTF16 else { return nil }
        var actual = NSRange(location: NSNotFound, length: 0)
        InputHealth.shared.phase("substring.begin")
        let result = client.string(from: range, actualRange: &actual)
        InputHealth.shared.phase("substring.end")
        guard let text = result, actual == range else { return nil }
        return text
    }
    func mark(_ text: String) {
        InputHealth.shared.phase("mark.begin", count: "markRequests")
        client.setMarkedText(CompositionAppearance.text(text, attributes: markedAttributes),
                             selectionRange: CompositionAppearance.selection(for: text),
                             replacementRange: CompositionSession.currentSelection)
        InputHealth.shared.phase("mark.end")
    }
    func clearMarkedText() {
        // setMarkedText("") cancels/deletes the marked range. insertText("")
        // can merely unmark it in Chromium, leaving a visible orphan character.
        // Never synthesize Backspace or replace surrounding committed text.
        mark("")
    }
    func insert(_ text: String, replacing range: NSRange) {
        InputHealth.shared.phase("insert.begin", count: "insertRequests")
        client.insertText(text, replacementRange: range)
        InputHealth.shared.phase("insert.end")
    }
}

@objc(CapsFlowInputController)
final class CapsFlowInputController: IMKInputController {
    private static let language = LanguageEngine()
    private let session = CompositionSession(language: CapsFlowInputController.language)
    private var panel: EnglishPanel?
    private var preview: DispatchWorkItem?
    private var active = false
    private var passthrough = false
    private var markedAttributes: [NSAttributedString.Key: Any] = [:]
    private static let menuDefaults = UserDefaults(suiteName: "local.capsflow.app")
    private static var optionSelectsCandidate: Bool {
        // Only modifier events/preview refreshes query this shared setting;
        // ordinary character composition is unchanged and remains local.
        menuDefaults?.synchronize()
        return CapsLockBehavior.restored(menuDefaults?.string(forKey: CapsLockBehavior.preferenceKey)).usesRightOptionForCandidate
    }

    override func activateServer(_ sender: Any!) {
        InputHealth.shared.phase("activate.begin", count: "activations")
        active = true; session.reset()
        let native = sender as? IMKTextInput
        InputHealth.shared.phase("activate.layout")
        native?.overrideKeyboard(withKeyboardNamed: "com.apple.keylayout.ABC")
        // Query once per activation, not over IPC for every typed character.
        InputHealth.shared.phase("activate.attributes")
        markedAttributes = CompositionAppearance.attributes(supportedNames: native?.validAttributesForMarkedText() ?? [])
        let excluded = UserDefaults(suiteName: "local.capsflow.app")?.stringArray(forKey: "excludedApps") ?? []
        InputHealth.shared.phase("activate.identity")
        let identifier = native?.bundleIdentifier()
        InputHealth.shared.client(identifier)
        passthrough = identifier.map { excluded.contains($0) } ?? false
        session.onChange = { [weak self] in self?.schedulePreview() }
        InputHealth.shared.phase("activate.end")
    }
    override func deactivateServer(_ sender: Any!) {
        InputHealth.shared.phase("deactivate.begin", count: "deactivations")
        if let client = sender as? IMKTextInput { session.commit(to: NativeClient(client)) }
        active = false; session.reset(); hidePreview()
        InputHealth.shared.phase("deactivate.end")
    }
    override func commitComposition(_ sender: Any!) {
        if let client = sender as? IMKTextInput { session.commit(to: NativeClient(client)) }
        hidePreview()
    }
    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue |
            NSEvent.EventTypeMask.leftMouseDown.rawValue | NSEvent.EventTypeMask.rightMouseDown.rawValue |
            NSEvent.EventTypeMask.otherMouseDown.rawValue)
    }
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        InputHealth.shared.phase("handle.begin", count: "events")
        var accepted = false
        defer { InputHealth.shared.phase(accepted ? "handle.accepted" : "handle.passed", count: accepted ? "accepted" : "passed") }
        guard active, !passthrough, let event, let client = sender as? IMKTextInput else { return false }
        let native = NativeClient(client, markedAttributes: markedAttributes)
        let flags = event.modifierFlags
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            session.commit(to: native); session.reset(); hidePreview(); return false
        }
        if event.type == .flagsChanged {
            accepted = session.flags(key: event.keyCode, option: flags.contains(.option), command: flags.contains(.command),
                                 control: flags.contains(.control), shift: flags.contains(.shift),
                                 at: event.timestamp, client: native,
                                 candidateSelectionEnabled: event.keyCode == 61 ? Self.optionSelectsCandidate : true)
            return accepted
        }
        guard event.type == .keyDown else { return false }
        accepted = session.handle(InputStroke(key: event.keyCode, text: event.characters ?? "", time: event.timestamp,
                                          command: flags.contains(.command), option: flags.contains(.option),
                                          control: flags.contains(.control), shift: flags.contains(.shift)), client: native)
        return accepted
    }
    private func hidePreview() { preview?.cancel(); preview = nil; panel?.hide() }
    private func schedulePreview() {
        hidePreview()
        guard active, session.candidate != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, let text = self.session.candidate, let client = self.client() else { return }
            var rect = NSRect.zero
            _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
            guard rect.minX.isFinite, rect.minY.isFinite, rect.height > 0 else { return }
            if self.panel == nil { self.panel = EnglishPanel() }
            self.panel?.show(text, caret: rect, clientLevel: client.windowLevel(), optionSelectsCandidate: Self.optionSelectsCandidate)
        }
        preview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }
}

/// Passive, nonactivating English alternative. Coordinates come from IMK, not AX.
private final class EnglishPanel {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let label = NSTextField(labelWithString: "")
    init() {
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.setAccessibilityTitle("CapsFlow 영어 후보")
        let background = NSVisualEffectView()
        background.material = .popover; background.blendingMode = .behindWindow; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 8; background.layer?.masksToBounds = true
        panel.contentView = background
        label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false; background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6)
        ])
    }
    func show(_ text: String, caret: NSRect, clientLevel: CGWindowLevel, optionSelectsCandidate: Bool) {
        label.stringValue = "영어 · \(text)    " + (optionSelectsCandidate ? "오른쪽 ⌥ / ⌘⌥Z" : "⌘⌥Z")
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(caret) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = min(max(220, label.intrinsicContentSize.width + 18), min(440, visible.width - 12))
        let height: CGFloat = 29
        let x = min(max(caret.minX, visible.minX + 6), visible.maxX - width - 6)
        let y = caret.maxY + height + 6 <= visible.maxY ? caret.maxY + 5 : caret.minY - height - 5
        panel.level = NSWindow.Level(rawValue: max(Int(clientLevel) + 1, NSWindow.Level.floating.rawValue))
        panel.setFrame(NSRect(x: x, y: min(max(y, visible.minY + 6), visible.maxY - height - 6), width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
}
