import Cocoa

/// Use explicit marked-text attributes instead of the host's default block
/// treatment. Never set a font/foreground color or select the composed word.
enum CompositionAppearance {
    static func attributes(supportedNames: [Any]) -> [NSAttributedString.Key: Any] {
        let supported = Set(supportedNames.compactMap { value -> String? in
            if let key = value as? NSAttributedString.Key { return key.rawValue }
            return value as? String
        })
        let desired: [NSAttributedString.Key: Any] = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .backgroundColor: NSColor.clear,
            .markedClauseSegment: 0
        ]
        return desired.filter { supported.contains($0.key.rawValue) }
    }
    static func selection(for text: String) -> NSRange {
        NSRange(location: text.utf16.count, length: 0)
    }
    static func text(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        NSAttributedString(string: text, attributes: attributes)
    }
}
