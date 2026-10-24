import Foundation

/// Only controls the Caps Lock route. All three modes remain manually selectable.
public enum CapsLockBehavior: String, CaseIterable, Sendable {
    case cycle, speed
    public static let preferenceKey = "capsLockBehavior"
    public static func restored(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .cycle
    }
    public var title: String {
        switch self {
        case .cycle: return "3단계 · 한 → EN → 자동"
        case .speed: return "Speed · 한 ↔ EN"
        }
    }
    public var hint: String {
        switch self {
        case .cycle: return "Caps Lock 한 번으로  한 → EN → 자동"
        case .speed: return "Caps Lock 한 번으로  한 ↔ EN · 자동은 직접 선택"
        }
    }
    public func next(from mode: InputMode) -> InputMode {
        switch self {
        case .cycle: return mode.next
        // Leaving a manually selected Auto goes to EN; subsequent presses toggle.
        case .speed: return mode == .english ? .korean : .english
        }
    }
}
