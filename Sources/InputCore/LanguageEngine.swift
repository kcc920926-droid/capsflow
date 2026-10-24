import Foundation

public enum InputMode: Int, CaseIterable, Sendable {
    case korean, english, automatic
    public var title: String { ["한글", "English", "한/영 자동"][rawValue] }
    public var badge: String { ["한", "EN", "자동"][rawValue] }
    public var next: InputMode { InputMode(rawValue: (rawValue + 1) % 3)! }
}
public enum InputLanguage: String, Sendable, Codable { case korean, english }

public struct Decision: Sendable, Codable {
    public let original: String
    public let korean: String
    public let output: String
    /// A heuristic ranking score, NOT a calibrated probability.
    public let rawKoreanScore: Double
    public let koreanScore: Double
    public let usedContext: Bool
    public let contextCharacters: Int
    public let reason: String
    public var changed: Bool { output != original }
    public var language: InputLanguage { output == original ? .english : .korean }
}

public struct ContextWindow: Sendable {
    public let text: String
    public init(precedingText: String, maxCharacters: Int = 2000) {
        let suffix = String(precedingText.suffix(maxCharacters))
        // Current paragraph plus the immediately preceding paragraph. Single line breaks
        // also count as paragraph boundaries, as they do in common chat editors.
        text = suffix.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(2).joined(separator: "\n")
    }
    public var koreanBias: Double {
        func evidence(_ text: String) -> (Double, Double) {
            var ko = 0.0, en = 0.0
            var latinRun = 0
            for scalar in text.unicodeScalars {
                if (0xAC00...0xD7A3).contains(scalar.value) || (0x3131...0x3163).contains(scalar.value) { ko += 1.8 }
                if (65...90).contains(scalar.value) || (97...122).contains(scalar.value) { latinRun += 1 }
                else if latinRun > 0 { en += min(3, Double(latinRun) * 0.45); latinRun = 0 }
            }
            if latinRun > 0 { en += min(3, Double(latinRun) * 0.45) }
            return (ko, en)
        }
        let (ko, en) = evidence(text)
        let current = text.components(separatedBy: "\n").last ?? ""
        let (nearKo, nearEn) = evidence(String(current.suffix(240)))
        let totalKo = ko + nearKo, totalEn = en + nearEn
        let total = totalKo + totalEn
        guard total >= 3 else { return 0 }
        return (totalKo - totalEn) / (total + 3)
    }
}

public final class LanguageEngine: @unchecked Sendable {
    private let english: [String: Int]
    private let korean: [String: Int]
    public var lexiconCounts: (english: Int, korean: Int) { (english.count, korean.count) }
    private static let technical = Set("api app apps ai openai codex claude swift swiftui macos ios github git npm node python docker json yaml html css javascript typescript react nextjs sql http https localhost url usb cpu gpu sdk cli llm mcp xcode chatgpt slack notion google apple vscode bash zsh brew ssh sudo curl pip rust go java kotlin ruby php linux windows tcp udp dns uuid utf pdf png jpg svg csv xml nil null true false var let func struct enum class import return async await todo fixme readme test tests main src dist build dev prod utf8 utf16".split(separator: " ").map(String.init))
    private static let slang = Set("ㅇㅇ ㄴㄴ ㄱㄱ ㄷㄷ ㅂㅂ ㅅㅅ ㅈㅈ ㅊㅊ ㅉㅉ ㅍㅍ ㅡㅡ ㅇㅋ ㄱㅅ ㅈㅅ ㅊㅋ ㅇㅈ ㅎㅇ ㅂㅇ ㅅㄱ ㄹㅇ ㅁㅊ ㄱㅊ ㄲㅂ ㅇㅎ ㅈㅂ ㅅㅂ ㄱㄷ".split(separator: " ").map(String.init))
    private static let numericUnits = Set("b kb mb gb tb pb kib mib gib tib hz khz mhz ghz w kw mw v kv a ma mm cm m km kg mg g l ml s ms ns fps dpi".split(separator: " ").map(String.init))

    public init() {
        func load(_ name: String) -> [String: Int] {
            let installed = Bundle.main.resourceURL?.appendingPathComponent("CapsFlow_InputCore.bundle")
            let resources = installed.flatMap { Bundle(url: $0) } ?? Bundle.module
            guard let url = resources.url(forResource: name, withExtension: "txt"),
                  let data = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
            var words: [String: Int] = [:]
            for (rank, line) in data.split(separator: "\n").enumerated() {
                if let word = line.split(separator: " ").first { words[String(word).lowercased()] = rank + 1 }
            }
            return words
        }
        english = load("en_50k"); korean = load("ko_50k")
    }

    /// Korean is the default, including new words, Shift syllables and isolated
    /// jamo. English recovery requires lexical/structural evidence, not speed.
    public func koreanFirst(_ raw: String, recentEnglish: Int = 0, slowdown: Double = 1) -> KoreanFirstDecision {
        let ko = Hangul.compose(raw)
        let parts = TokenSyntax.romanParts(raw)
        let letters = parts?.letters ?? raw
        let lower = letters.lowercased()
        let er = english[lower], kr = korean[Hangul.compose(letters)]
        let single = parts?.letters.count == 1
        let slang = Self.slang.contains(ko) || (ko.count >= 2 && ko.allSatisfy { "ㅋㅎㅜㅠ".contains($0) })
        let unit = parts?.digits.isEmpty == false && Self.numericUnits.contains(lower)
        let structured = KoreanFirstComposition.isStructured(raw)
        let contraction = KoreanFirstComposition.isContraction(raw)
        // Both valid (go/해, to/새 etc.) stay Korean, regardless of cadence.
        let clearTerm = Self.technical.contains(lower) && kr == nil && !single
        let clearWord = er.map { $0 <= 12_000 } == true && kr == nil && !single
        // A less common dictionary word may use independently observed English
        // context AND a slowdown; neither signal alone is sufficient.
        let supportedSwitch = er != nil && kr == nil && !single && recentEnglish >= 3 && slowdown >= 1.4
        let recover = !slang && (structured || contraction || unit || clearTerm || clearWord || supportedSwitch)
        let candidate = !recover && !slang && (kr == nil || er != nil || single) && !raw.isEmpty && raw != ko ? raw : nil
        return KoreanFirstDecision(korean: ko, output: recover ? raw : ko,
                                   englishCandidate: candidate, language: recover ? .english : .korean,
                                   reason: recover ? "명확한 영어·개발 용어·구조 보존" : "한국어 기본 · 영어는 명시 선택")
    }

    public func decide(_ token: String, precedingText: String = "", preferred: InputLanguage = .korean) -> Decision {
        let core = TokenSyntax.core(token)
        let parts = TokenSyntax.romanParts(core)
        let letters = parts?.letters ?? core
        let candidateLetters = Hangul.compose(letters)
        let candidate = (parts?.digits ?? "") + candidateLetters
        let context = ContextWindow(precedingText: precedingText)
        var score = 0.0, reason = "영문·기호 유지"
        let asciiLetters = parts != nil
        let protected = token.contains("@") || token.contains("/") || token.contains("\\") || token.contains("_") || token.contains("=") || token.contains("`") || core.contains(".")
        let lower = letters.lowercased()
        var unknownComposition: (syllables: Int, fraction: Double)?
        let numericUnit = parts?.digits.isEmpty == false && Self.numericUnits.contains(lower)
        let singleLetter = parts?.letters.count == 1
        if singleLetter { reason = "한 글자 영문 유지 · 자모는 추천으로 선택" }
        if asciiLetters && !protected && !numericUnit && !singleLetter {
            let jamo = Array(candidateLetters)
            let expressive = jamo.count >= 2 && jamo.allSatisfy { "ㅋㅎㅜㅠ".contains($0) }
            if expressive || Self.slang.contains(candidateLetters) {
                score = 0.99; reason = "반복 자모·채팅 표현"
            } else {
                let enRank = english[lower], koRank = korean[candidateLetters]
                let allCaps = letters.count >= 2 && letters == letters.uppercased()
                let camelCase = letters.dropFirst().contains { $0.isUppercase }
                let syllables = candidateLetters.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
                // Korean Shift affects R/E/Q/T/W/O/P; the other capital letters
                // retain their ordinary two-set value (e.g. QKfmrp -> 빠르게).
                // In a strongly Korean field, a clean multi-syllable sequence
                // is not an identifier solely because Shift produced capitals.
                let koreanShiftWord = (allCaps || camelCase) && enRank == nil &&
                    context.koreanBias >= 0.55 && syllables >= 2 &&
                    Double(syllables) / Double(max(1, candidateLetters.count)) >= 0.8
                // 'go' is intentionally NOT protected: 해/go must use paragraph context.
                if (Self.technical.contains(lower) && lower != "go") || ((allCaps || camelCase) && koRank == nil && !koreanShiftWord) {
                    score = 0.01; reason = "개발 용어·영문 식별자"
                } else if let er = enRank, let kr = koRank {
                    let difference = 0.025 * log(Double(er) / Double(kr))
                    score = min(0.55, max(0.45, 0.5 + difference))
                    reason = "한·영 양쪽 사전에 있는 중의적 입력"
                } else if koRank != nil {
                    score = 0.94; reason = "한글 어휘"
                } else if enRank != nil {
                    score = 0.04; reason = "영어 어휘"
                } else {
                    let fraction = Double(syllables) / Double(max(1, candidateLetters.count))
                    unknownComposition = (syllables, fraction)
                    score = syllables >= 2 && fraction >= 0.8 ? 0.74 : (fraction >= 0.5 ? 0.5 : 0.12)
                    reason = syllables >= 2 ? "사전 밖 한글 조합" : "짧거나 불완전한 입력"
                    if koreanShiftWord { reason += " · 한국어 Shift 자판" }
                }
            }
        }
        let raw = score
        let ambiguous = (0.45...0.55).contains(score)
        let bias = context.koreanBias
        let koreanDominant = bias >= 0.55 && unknownComposition.map { $0.syllables >= 1 && $0.fraction >= 0.3 } == true
        let usesContext = (ambiguous && abs(bias) > 0.08) || koreanDominant
        if koreanDominant {
            score = max(score, min(0.90, 0.56 + bias * 0.25))
            reason += " · 주 언어 한국어 우선"
        } else if usesContext {
            score = min(0.96, max(0.04, score + bias * 0.40))
            reason += " · 앞 문단의 " + (bias > 0 ? "한국어" : "영어") + " 문맥"
        } else if ambiguous {
            score = preferred == .korean ? 0.56 : 0.44
            reason += " · 최근 언어 유지"
        }
        var output = token
        if score > 0.5, let range = token.range(of: core), !core.isEmpty {
            output.replaceSubrange(range, with: candidate)
        }
        return Decision(original: token, korean: candidate, output: output,
                        rawKoreanScore: raw, koreanScore: score, usedContext: usesContext,
                        contextCharacters: context.text.count, reason: reason)
    }
}
