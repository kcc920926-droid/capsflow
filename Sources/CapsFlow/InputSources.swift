import Cocoa
import Carbon
import InputCore

enum InputSources {
    static let automaticID = "local.inputmethod.capsflow.koreanfirst"
    // Keep retained TIS objects on the main thread. Enumerating every input
    // method on every Caps press is unnecessary; enabled-source changes invalidate.
    private static var cachedSources: [String: TISInputSource] = [:]
    private static var loaded = false
    static func id(_ source: TISInputSource) -> String {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }
    static var currentID: String { id(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) }
    static var enabled: [TISInputSource] { TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource] }
    static var enabledIDs: [String] { enabled.map(id) }
    static func invalidate() { cachedSources.removeAll(); loaded = false }
    private static func source(for mode: InputMode) -> TISInputSource? {
        if !loaded {
            cachedSources = Dictionary(enabled.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
            loaded = true
        }
        if mode == .korean { return cachedSources["com.apple.inputmethod.Korean.2SetKorean"] }
        if mode == .automatic { return cachedSources[automaticID] }
        return cachedSources["com.apple.keylayout.ABC"] ?? cachedSources["com.apple.keylayout.US"]
    }
    static func matches(_ mode: InputMode, identifier: String) -> Bool {
        if mode == .korean { return identifier == "com.apple.inputmethod.Korean.2SetKorean" }
        if mode == .automatic { return identifier == automaticID }
        return identifier == "com.apple.keylayout.ABC" || identifier == "com.apple.keylayout.US"
    }
    // Follow macOS/manual source changes; never force CapsFlow's IME back over
    // Control-Space, the input menu, or a document's restored input method.
    static func modeAfterSourceChange(_ mode: InputMode, identifier: String) -> InputMode {
        if matches(mode, identifier: identifier) { return mode }
        if matches(.automatic, identifier: identifier) { return .automatic }
        if matches(.korean, identifier: identifier) { return .korean }
        if matches(.english, identifier: identifier) { return .english }
        return .english // unsupported IME: do not reinterpret its keystrokes
    }
    static func selectID(_ identifier: String) {
        if currentID == identifier { return }
        if let source = enabled.first(where: { id($0) == identifier }) { _ = TISSelectInputSource(source) }
    }
    @discardableResult static func select(_ mode: InputMode) -> Bool {
        // Auto is a real IMK input source, distinct from built-in ABC and 2-Set.
        if matches(mode, identifier: currentID) { return true }
        guard let source = source(for: mode) else { return false }
        return TISSelectInputSource(source) == noErr
    }
}
