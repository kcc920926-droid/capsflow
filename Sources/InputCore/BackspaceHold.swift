import Foundation

/// Only tracks one physical hold. No text, selection, timer, or synthetic keys.
public struct BackspaceHold {
    public static let threshold: TimeInterval = 1
    public static let preferenceKey = "longBackspaceEnabled"
    private var began: TimeInterval?
    private var previous: TimeInterval?
    public init() {}
    public mutating func reset() { began = nil; previous = nil }

    /// Called for Backspace keyDown events only. Key up, other keys, clicks,
    /// modifiers, focus/mode changes, and disabled/secure contexts reset it.
    public mutating func wordDeletion(repeating: Bool, at time: TimeInterval, eligible: Bool) -> Bool {
        guard eligible, time.isFinite else { reset(); return false }
        if !repeating {
            began = time; previous = time; return false
        }
        guard let began, let previous, time >= previous,
              time - previous <= 2 else { reset(); return false }
        self.previous = time
        return time - began >= Self.threshold
    }
}
