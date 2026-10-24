import Foundation

/// Standard two-set Korean composition, including isolated/compound jamo.
public enum Hangul {
    static let initials = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    static let vowels = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ")
    static let finals = Array(" ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ")
    static let keys: [Character: Character] = Dictionary(uniqueKeysWithValues:
        zip(Array("rRseEfaqQtTdwWczxvgkoiOjpuPhynbml"),
            Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎㅏㅐㅑㅒㅓㅔㅕㅖㅗㅛㅜㅠㅡㅣ")))
    static let joinedVowels: [String: Character] = [
        "ㅗㅏ":"ㅘ", "ㅗㅐ":"ㅙ", "ㅗㅣ":"ㅚ", "ㅜㅓ":"ㅝ", "ㅜㅔ":"ㅞ", "ㅜㅣ":"ㅟ", "ㅡㅣ":"ㅢ"
    ]
    static let joinedFinals: [String: Character] = [
        "ㄱㅅ":"ㄳ", "ㄴㅈ":"ㄵ", "ㄴㅎ":"ㄶ", "ㄹㄱ":"ㄺ", "ㄹㅁ":"ㄻ", "ㄹㅂ":"ㄼ",
        "ㄹㅅ":"ㄽ", "ㄹㅌ":"ㄾ", "ㄹㅍ":"ㄿ", "ㄹㅎ":"ㅀ", "ㅂㅅ":"ㅄ"
    ]

    public static func compose(_ text: String) -> String {
        var output = ""
        var lead: Character?, vowel: Character?, tail: Character?
        func syllable(_ l: Character, _ v: Character, _ t: Character?) -> String {
            let li = initials.firstIndex(of: l)!, vi = vowels.firstIndex(of: v)!
            let ti = t.flatMap { finals.firstIndex(of: $0) } ?? 0
            return String(UnicodeScalar(0xAC00 + (li * 21 + vi) * 28 + ti)!)
        }
        func flush() {
            if let l = lead, let v = vowel { output += syllable(l, v, tail) }
            else {
                if let l = lead { output.append(l) }
                if let v = vowel { output.append(v) }
            }
            lead = nil; vowel = nil; tail = nil
        }
        for key in text {
            let lowered = Character(key.lowercased())
            guard let jamo = keys[key] ?? keys[lowered] else { flush(); output.append(key); continue }
            if vowels.contains(jamo) {
                if let t = tail, let l = lead, let v = vowel {
                    if let pair = joinedFinals.first(where: { $0.value == t })?.key {
                        let pieces = Array(pair)
                        output += syllable(l, v, pieces[0]); lead = pieces[1]
                    } else {
                        output += syllable(l, v, nil); lead = t
                    }
                    vowel = jamo; tail = nil
                } else if let v = vowel {
                    if let joined = joinedVowels[String(v) + String(jamo)] { vowel = joined }
                    else { flush(); vowel = jamo }
                } else { vowel = jamo }
            } else {
                if lead != nil && vowel != nil {
                    if let t = tail {
                        if let joined = joinedFinals[String(t) + String(jamo)] { tail = joined }
                        else { flush(); lead = jamo }
                    } else if finals.contains(jamo) { tail = jamo }
                    else { flush(); lead = jamo }
                } else { flush(); lead = jamo }
            }
        }
        flush()
        return output
    }

    public static func keystrokes(for text: String) -> String {
        let reverse = Dictionary(uniqueKeysWithValues: keys.map { ($0.value, $0.key) })
        func appendJamo(_ j: Character, to result: inout String) {
            if let key = reverse[j] { result.append(key) }
            else if let split = joinedVowels.first(where: { $0.value == j })?.key ?? joinedFinals.first(where: { $0.value == j })?.key {
                for c in split { if let key = reverse[c] { result.append(key) } }
            } else { result.append(j) }
        }
        var result = ""
        for c in text {
            if let value = c.unicodeScalars.first?.value, (0xAC00...0xD7A3).contains(value) {
                let n = Int(value - 0xAC00)
                appendJamo(initials[n / 588], to: &result)
                appendJamo(vowels[(n % 588) / 28], to: &result)
                if n % 28 != 0 { appendJamo(finals[n % 28], to: &result) }
            } else { appendJamo(c, to: &result) }
        }
        return result
    }
}
