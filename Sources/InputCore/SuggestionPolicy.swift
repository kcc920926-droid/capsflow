import Foundation

/// A literal two-set alternative, not a spelling correction or an auto-apply.
public enum SuggestionPolicy {
    public static func koreanCandidate(for decision: Decision) -> String? {
        let core = TokenSyntax.core(decision.original)
        guard (1...80).contains(core.count),
              let parts = TokenSyntax.romanParts(core), !parts.letters.isEmpty,
              decision.korean != core,
              let range = decision.original.range(of: core) else { return nil }
        var candidate = decision.original
        candidate.replaceSubrange(range, with: decision.korean)
        return candidate
    }

    /// Offer only the fallback: auto-converted words need no duplicate popup.
    /// Candidate generation intentionally ignores lexicon/confidence scores.
    public static func fallbackCandidate(for decision: Decision) -> String? {
        guard !decision.changed else { return nil }
        return koreanCandidate(for: decision)
    }
}
