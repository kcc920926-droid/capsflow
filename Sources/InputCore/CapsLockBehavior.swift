import Foundation

/// Switching-key preset. The persisted name/old values stay compatible.
/// All three input modes remain manually selectable regardless of preset.
public enum CapsLockBehavior: String, CaseIterable, Sendable {
    case cycle, speed, rightAlt
    public static let preferenceKey = "capsLockBehavior"
    public static func restored(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .cycle
    }
    public var title: String {
        switch self {
        case .cycle: return "Caps Lock 3단계 · 한 → EN → 자동"
        case .speed: return "Caps Lock 2단계 · Speed · 한 ↔ EN"
        case .rightAlt: return "오른쪽 Alt 2단계 · 한 ↔ EN"
        }
    }
    public var hint: String {
        switch self {
        case .cycle: return "Caps Lock 한 번으로  한 → EN → 자동"
        case .speed: return "Caps Lock 한 번으로  한 ↔ EN · 자동은 직접 선택"
        case .rightAlt: return "오른쪽 Alt(⌥) 단독 탭으로  한 ↔ EN · Caps Lock은 원래 기능"
        }
    }
    public var capturesCapsLock: Bool { self != .rightAlt }
    public var usesRightOptionForCandidate: Bool { self != .rightAlt }
    public func next(from mode: InputMode) -> InputMode {
        switch self {
        case .cycle: return mode.next
        // Leaving a manually selected Auto goes to EN; subsequent presses toggle.
        case .speed, .rightAlt: return mode == .english ? .korean : .english
        }
    }
}
