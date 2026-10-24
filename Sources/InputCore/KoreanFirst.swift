import Foundation

public struct KoreanFirstDecision: Sendable {
    public let korean: String
    public let output: String
    public let englishCandidate: String?
    public let language: InputLanguage
    public let reason: String
}

/// Timing statistics only. No text, timestamps, or per-key history is retained.
/// Idle/thinking gaps are excluded; speed can never classify an unknown word.
public struct TypingCadence: Sendable {
    private var previous: TimeInterval?
    private var wordMean = 0.0
    private var wordCount = 0
    private var koreanMean: Double?
    public init() {}
    public mutating func observe(at time: TimeInterval) {
        defer { previous = time }
        guard let previous, time > previous else { return }
        let gap = time - previous
        guard (0.015...0.7).contains(gap) else { return }
        wordCount += 1
        wordMean += (gap - wordMean) / Double(wordCount)
    }
    public var slowdown: Double {
        guard wordCount >= 3, let baseline = koreanMean, baseline > 0 else { return 1 }
        return min(3, max(0.3, wordMean / baseline))
    }
    public mutating func finish(language: InputLanguage) {
        if language == .korean, wordCount >= 3 {
            koreanMean = koreanMean.map { $0 * 0.9 + wordMean * 0.1 } ?? wordMean
        }
        resetWord()
    }
    public mutating func resetWord() { previous = nil; wordMean = 0; wordCount = 0 }
}

/// One native IMK composition. Pauses do not commit or invalidate a Korean run.
/// Only the current composition lives here, never a document/key log.
public struct KoreanFirstComposition {
    public private(set) var raw = ""
    public private(set) var explicitLanguage: InputLanguage?
    public var englishOverride: Bool { explicitLanguage == .english }
    public private(set) var recentEnglish = 0
    public private(set) var cadence = TypingCadence()
    public static let maximumKeys = 512
    public init() {}
    public var display: String {
        if explicitLanguage == .korean { return Hangul.compose(raw) }
        return englishOverride || Self.isStructured(raw) ? raw : Hangul.compose(raw)
    }
    public var isEmpty: Bool { raw.isEmpty }
    @discardableResult public mutating func append(_ text: String, at time: TimeInterval) -> Bool {
        guard !text.isEmpty, raw.count + text.count <= Self.maximumKeys,
              text.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { return false }
        cadence.observe(at: time); raw += text
        return true
    }
    public mutating func backspace() {
        if !raw.isEmpty { raw.removeLast() }
        cadence.resetWord()
        // A fully erased run must never lend its explicit language to the next.
        if raw.isEmpty { explicitLanguage = nil }
    }
    public mutating func toggleLanguage() {
        explicitLanguage = explicitLanguage == .english ? .korean : .english
    }
    public func decision(using engine: LanguageEngine) -> KoreanFirstDecision {
        if englishOverride {
            return KoreanFirstDecision(korean: Hangul.compose(raw), output: raw,
                                       englishCandidate: nil, language: .english, reason: "사용자가 영어 선택")
        }
        if explicitLanguage == .korean {
            return KoreanFirstDecision(korean: Hangul.compose(raw), output: Hangul.compose(raw),
                                       englishCandidate: raw, language: .korean, reason: "사용자가 한글 선택")
        }
        return engine.koreanFirst(raw, recentEnglish: recentEnglish, slowdown: cadence.slowdown)
    }
    public mutating func finish(using engine: LanguageEngine) -> KoreanFirstDecision {
        let result = decision(using: engine)
        cadence.finish(language: result.language)
        recentEnglish = result.language == .english ? min(8, recentEnglish + 1) : max(0, recentEnglish - 2)
        raw = ""; explicitLanguage = nil
        return result
    }
    public mutating func reset() { self = Self() }
    public static func isStructured(_ raw: String) -> Bool {
        raw.contains(where: { "@/\\_=`.:".contains($0) })
    }
    public static func isContractionStem(_ raw: String) -> Bool {
        Set("i you he she it we they that this what who where when why how there here let don can won didn isn aren wasn weren wouldn couldn shouldn hasn haven hadn mustn needn shan ain".split(separator: " ").map(String.init)).contains(raw.lowercased())
    }
    public static func isContraction(_ raw: String) -> Bool {
        let parts = raw.lowercased().replacingOccurrences(of: "’", with: "'").split(separator: "'", omittingEmptySubsequences: false)
        return parts.count == 2 && isContractionStem(String(parts[0])) &&
            ["s", "t", "re", "ve", "ll", "d", "m"].contains(String(parts[1]))
    }
    public func retains(_ delimiter: String, using engine: LanguageEngine) -> Bool {
        if delimiter == "'" || delimiter == "’" { return Self.isContractionStem(raw) }
        if delimiter == "." || delimiter == ":" {
            return !raw.isEmpty && (Self.isStructured(raw) || decision(using: engine).language == .english || raw.allSatisfy(\.isNumber))
        }
        return false
    }
}
