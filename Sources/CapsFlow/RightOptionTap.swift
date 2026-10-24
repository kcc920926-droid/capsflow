import Foundation
import CoreGraphics
import IOKit.hidsystem

/// A tap-only gesture. Modifier events always continue to the target app.
/// Other keys/modifiers, clicks, focus changes, or a long hold cancel it.
struct RightOptionTap {
    static let rightMask = CGEventFlags(rawValue: UInt64(NX_DEVICERALTKEYMASK))
    static let leftMask = CGEventFlags(rawValue: UInt64(NX_DEVICELALTKEYMASK))
    private var down = false
    private var beganAt: TimeInterval?

    mutating func reset() { down = false; beganAt = nil }

    mutating func observe(type: CGEventType, key: Int64, flags: CGEventFlags, time: TimeInterval, eligible: Bool) -> Bool {
        guard type == .flagsChanged, key == 61 else {
            beganAt = nil
            return false
        }
        // Prefer device-side flags. Some keyboards expose aggregate flags only;
        // in that case the right-Option key code still identifies the gesture.
        let hasSideFlags = !flags.intersection([Self.rightMask, Self.leftMask]).isEmpty
        let pressed = flags.contains(Self.rightMask) || (!hasSideFlags && flags.contains(.maskAlternate))
        if pressed {
            if !down {
                down = true
                let other = flags.intersection([.maskShift, .maskCommand, .maskControl, .maskSecondaryFn, Self.leftMask])
                beganAt = eligible && other.isEmpty && time.isFinite ? time : nil
            }
            return false
        }
        let start = beganAt, wasDown = down
        reset()
        let held = flags.intersection([.maskAlternate, .maskShift, .maskCommand, .maskControl, .maskSecondaryFn])
        guard wasDown, eligible, held.isEmpty, let start, time.isFinite else { return false }
        return (0...0.6).contains(time - start)
    }
}
