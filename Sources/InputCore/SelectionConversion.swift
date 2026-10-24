import Foundation

/// Explicit keyboard-layout conversion, not translation or spelling correction.
public enum SelectionConversion {
    public static let maximumUTF16 = 4096
    private static let runs = try! NSRegularExpression(pattern: "[A-Za-z0-9_]+")
    private static let preserved = Set("api ai openai codex claude swift macos ios github git npm node python docker json yaml html css javascript typescript react sql http https localhost url usb cpu gpu sdk cli llm mcp xcode chatgpt slack notion google apple vscode bash zsh brew ssh sudo curl pip rust java kotlin ruby php linux windows tcp udp dns uuid utf pdf png jpg svg csv xml utf8 utf16".split(separator: " ").map(String.init))
    private static let units = Set("b kb mb gb tb pb kib mib gib tib hz khz mhz ghz w kw mw v kv a ma mm cm m km kg mg g l ml s ms ns fps dpi".split(separator: " ").map(String.init))

    public static func korean(_ text: String) -> String? {
        guard !text.isEmpty, text.utf16.count <= maximumUTF16 else { return nil }
        func convert(_ segment: String) -> String {
            if segment.contains(where: { "@/\\_=".contains($0) }) { return segment }
            if segment.range(of: #"(?i)\b[a-z0-9-]+\.(com|net|org|edu|gov|io|ai|dev|app|kr|co|uk|me)(?:\b|$)"#, options: .regularExpression) != nil { return segment }
            let ns = segment as NSString
            var result = segment
            for match in runs.matches(in: segment, range: NSRange(location: 0, length: ns.length)).reversed() {
                let raw = ns.substring(with: match.range)
                guard let parts = TokenSyntax.romanParts(raw),
                      !preserved.contains(parts.letters.lowercased()),
                      parts.digits.isEmpty || !units.contains(parts.letters.lowercased()),
                      let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: parts.digits + Hangul.compose(parts.letters))
            }
            return result
        }
        let characters = Array(text)
        var output = "", segment = "", codeDelimiter = 0, index = 0
        func flush() { output += convert(segment); segment = "" }
        while index < characters.count {
            let character = characters[index]
            if character == "`" {
                flush()
                var end = index
                while end < characters.count && characters[end] == "`" { end += 1 }
                let count = end - index
                if codeDelimiter == 0 { codeDelimiter = count }
                else if codeDelimiter == count { codeDelimiter = 0 }
                output += String(repeating: "`", count: count); index = end; continue
            }
            if codeDelimiter > 0 { output.append(character) }
            else if character.isWhitespace { flush(); output.append(character) }
            else { segment.append(character) }
            index += 1
        }
        flush()
        return output == text ? nil : output
    }
}
