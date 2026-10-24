import Foundation

/// Shared syntax for automatic decisions and explicit two-set alternatives.
public enum TokenSyntax {
    public static let edges = CharacterSet(charactersIn: "\"'“”‘’()[]{}<>.,!?;:…。，！？；：（）［］｛｝〈〉《》「」『』【】〔〕〖〗〘〙〚〛«»‹›")

    public static func core(_ token: String) -> String { token.trimmingCharacters(in: edges) }

    /// Only a leading ASCII number is allowed; embedded/trailing digits remain identifiers.
    public static func romanParts(_ core: String) -> (digits: String, letters: String)? {
        let digits = String(core.prefix { $0.isASCII && $0.isNumber })
        let letters = String(core.dropFirst(digits.count))
        guard !letters.isEmpty, letters.unicodeScalars.allSatisfy({
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }) else { return nil }
        return (digits, letters)
    }
}

public enum WordBoundary {
    public static let closers = ")]}］｝）〉》」』】〕〗〙〛»›\"'”’"
    public static let punctuation = ".,!?;:…。，！？；：" + closers
    public static let openers = "([{［｛（〈《「『【〔〖〘〚«‹“‘"
    private static let contractionStems = Set("i you he she it we they that this what who where when why how there here let don can won didn isn aren wasn weren wouldn couldn shouldn hasn haven hadn mustn needn shan ain y o".split(separator: " ").map(String.init))

    public static func isOpening(_ text: String) -> Bool {
        text.count == 1 && openers.contains(text)
    }

    public static func delimiter(key: Int64, text: String) -> String? {
        switch key {
        case 49: return " "
        case 36, 76: return "\n"
        case 48: return "\t"
        default: return text.count == 1 && punctuation.contains(text) ? text : nil
        }
    }

    public static func isPunctuation(_ delimiter: String) -> Bool {
        delimiter.count == 1 && punctuation.contains(delimiter)
    }

    /// A short look-ahead for dots/colons distinguishes fast domain/decimal typing.
    public static func settlingDelay(_ delimiter: String) -> TimeInterval {
        delimiter == "." || delimiter == ":" ? 0.14 : 0
    }

    public static func retainsStructuredRun(raw: String, delimiter: String, following: String?, converted: Bool, ambiguous: Bool = false) -> Bool {
        guard isPunctuation(delimiter) else { return false }
        // Keep already-recognizable URLs, email addresses, paths and identifiers
        // intact until whitespace instead of interpreting each segment separately.
        if raw.contains(where: { "@/\\_=`.:".contains($0) }) { return true }
        // English apostrophes are not word breaks: keep we + ' + re and I + ' + m
        // in one observed run even when the typist pauses after the apostrophe.
        // Confident Korean still commits at a closing quote; preserved text can
        // always be explicitly converted via its suggestion instead.
        if delimiter == "'" || delimiter == "’" {
            let stem = TokenSyntax.core(raw).lowercased()
            if !converted || contractionStems.contains(stem) { return true }
        }
        guard delimiter == "." || delimiter == ":" else { return false }
        if !converted { return true }
        guard let next = following?.first else { return false }
        if delimiter == ":" && (next.isNumber || next == "/" || next == "\\") { return true }
        // Confident Korean words still end at a period without requiring a
        // following space. Only ambiguous English/Korean labels (e.g. go.com)
        // use the immediate suffix as address evidence.
        return ambiguous && next.isASCII && (next.isLetter || next.isNumber)
    }
}
