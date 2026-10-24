import CoreGraphics
import Foundation

/// Event-shape recognition only; no keys are posted and no text is retained.
/// Local remapped Caps arrives as F18. Remote clients may instead send raw
/// Caps key pairs, latch transitions, or both for the same physical press.
struct CapsToggleTrigger {
    enum Result: Equatable { case pass, consume, toggle }
    private var mappedDown = false
    private var rawDown = false
    private var shortcutDown = false
    private var capsFlag: Bool?
    private var lastRawDown: TimeInterval?
    private var lastFlagToggle: TimeInterval?
    private(set) var capturedRawCaps = false

    mutating func reset() { self = Self() }
    mutating func releaseHeldKeys() { mappedDown = false; rawDown = false; shortcutDown = false }

    mutating func observe(type: CGEventType, key: Int64, flags: CGEventFlags,
                          repeating: Bool, time: TimeInterval) -> Result {
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else { return .pass }
        // Ctrl+Shift+Space is a remote fallback, not text conversion.
        let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn])
        if key == 49 {
            if type == .keyUp, shortcutDown { shortcutDown = false; return .consume }
            if type == .keyDown, modifiers == [.maskControl, .maskShift] {
                guard !repeating, !shortcutDown else { return .consume }
                shortcutDown = true; return .toggle
            }
        }
        if key == 79 {
            if type == .keyUp { mappedDown = false; return .consume }
            guard type == .keyDown, !repeating, !mappedDown else { return .consume }
            mappedDown = true; return .toggle
        }
        guard key == 57 else { return .pass }
        capturedRawCaps = true
        let on = flags.contains(.maskAlphaShift)
        if type == .keyUp { rawDown = false; return .consume }
        if type == .keyDown {
            guard !repeating, !rawDown else { return .consume }
            rawDown = true; lastRawDown = time
            // Coalesce only a near-simultaneous flags/down representation.
            // Two flags-only latch transitions are never time-debounced.
            if let previous = lastFlagToggle, (0...0.03).contains(time - previous) { return .consume }
            return .toggle
        }
        let changed = capsFlag == nil || capsFlag != on
        capsFlag = on
        guard changed, !rawDown else { return .consume }
        if let previous = lastRawDown, (0...0.03).contains(time - previous) { return .consume }
        lastFlagToggle = time
        return .toggle
    }

    /// A consumed remote Caps must not leave subsequent Latin keys locked in
    /// uppercase. Preserve real Shift and non-ASCII/Option/command payloads.
    static func unlatchedASCII(_ text: String, flags: CGEventFlags) -> String {
        guard flags.contains(.maskAlphaShift),
              flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty,
              text.utf8.count == 1, let byte = text.utf8.first,
              (65...90).contains(byte) || (97...122).contains(byte) else { return text }
        return flags.contains(.maskShift) ? text.uppercased() : text.lowercased()
    }
}
