import Foundation
import InputCore

private var assertions = 0
private var failures = 0
func expect(_ result: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    assertions += 1
    if !result() { failures += 1; print("FAIL \(file):\(line) \(message)") }
}

struct InputCoreTests {
    let engine = LanguageEngine()
    func testLexiconsArePackaged() {
        expect((engine.lexiconCounts.english) > (49000))
        expect((engine.lexiconCounts.korean) > (49000))
    }
    func testTwoSetComposition() {
        let examples = ["dkssud":"안녕", "gksrmf":"한글", "rkskek":"가나다", "rhk":"과", "rnj":"궈", "rkqt":"값", "rkqtdl":"값이", "rkrtk":"각사", "Rk":"까", "rhkfr":"괅", "zzzz":"ㅋㅋㅋㅋ", "gggg":"ㅎㅎㅎㅎ", "bbbb":"ㅠㅠㅠㅠ", "dnd":"웅", "go":"해", "hello":"ㅗ디ㅣㅐ"]
        for (keys, text) in examples { expect((Hangul.compose(keys)) == (text), keys) }
    }
    func testEveryHangulSyllableRoundTrips() {
        for value in 0xAC00...0xD7A3 {
            let syllable = String(UnicodeScalar(value)!)
            expect((Hangul.compose(Hangul.keystrokes(for: syllable))) == (syllable), syllable)
        }
    }
    func testKoreanSentencesRoundTrip() {
        for text in ["안녕하세요", "값이 비싸요", "읽고 싶어요", "닭과 꽃과 흙", "괜찮아 ㅋㅋㅋㅋ", "왜 이렇게 됐지", "쌍꺼풀", "뿌듯해", "ㅜㅜㅠㅠㅎㅎㄱㄱㅇㅋ"] {
            expect((Hangul.compose(Hangul.keystrokes(for: text))) == (text), text)
        }
    }
    func testCommonKoreanAndEnglish() {
        for korean in ["안녕", "안녕하세요", "감사합니다", "오늘", "정말", "좋아요", "한글", "사랑해"] {
            let raw = Hangul.keystrokes(for: korean)
            expect((engine.decide(raw, precedingText: "지금 한국어로 이야기하는 중이야.").output) == (korean), raw)
        }
        for text in ["hello", "world", "please", "keyboard", "automatic", "meeting", "tomorrow", "project", "apple"] {
            expect((engine.decide(text, precedingText: "We are writing in English.").output) == (text))
        }
    }
    func testChatExpressions() {
        for text in ["ㅋㅋ", "ㅋㅋㅋㅋㅋㅋㅋㅋ", "ㅎㅎㅎㅎ", "ㅠㅠ", "ㅜㅜㅜㅜ", "ㄱㄱ", "ㅇㅇ", "ㄴㄴ", "ㄷㄷ", "ㅇㅋ", "ㄱㅅ", "ㅈㅅ", "ㅇㅈ", "ㄹㅇ", "ㄱㅊ", "ㅡㅡ", "ㅋㅋㅎㅎ"] {
            let keys = Hangul.keystrokes(for: text)
            expect((engine.decide(keys).output) == (text), keys)
            expect((engine.decide(text).output) == (text))
        }
    }
    func testAmbiguousGoUsesParagraphContext() {
        let ko = engine.decide("go", precedingText: "오늘 해야 할 일을 정리했어.\n이제 바로 시작하도록 ")
        let en = engine.decide("go", precedingText: "We have already discussed this plan.\nNow it is time to ")
        expect((0.45...0.55).contains(ko.rawKoreanScore))
        expect((ko.output) == ("해")); expect(ko.usedContext)
        expect((en.output) == ("go")); expect(en.usedContext)
        expect((ko.rawKoreanScore) == (en.rawKoreanScore))
    }
    func testPreviousParagraphWithBlankLine() {
        let ko = engine.decide("go", precedingText: "앞 단락은 한국어로 작성되어 있고 오늘 할 일을 이야기해.\n\n")
        let en = engine.decide("go", precedingText: "This previous paragraph provides the language context for what comes next.\n\n")
        expect((ko.output) == ("해")); expect(ko.usedContext)
        expect((en.output) == ("go")); expect(en.usedContext)
    }
    func testContextBoundAndScope() {
        let old = String(repeating: "옛 문장은 지금의 문맥과 관계가 없어요. ", count: 100)
        let context = ContextWindow(precedingText: old + "\nPlease use the current paragraph.\nWe can now ")
        expect((context.text.count) <= (2000))
        expect(!(context.text.contains("옛")))
        expect((context.koreanBias) < (0))
    }
    func testNoContextUsesPreference() {
        expect((engine.decide("go", preferred: .english).output) == ("go"))
        expect((engine.decide("go", preferred: .korean).output) == ("해"))
        expect(!(engine.decide("go").usedContext))
    }
    func testMixedKoreanParagraphWithEnglishTerms() {
        let result = engine.decide("go", precedingText: "이 프로젝트는 Swift와 API를 사용해서 만들었어. 이제 실행을 ")
        expect((result.output) == ("해")); expect(result.usedContext)
    }
    func testProtectsTechnicalTokensAndAddresses() {
        for word in ["API", "Swift", "macOS", "OpenAI", "Codex", "JSON", "fooBar", "https://example.com", "user@example.com", "hello_world", "/tmp/test", "file.swift", "git", "npm", "localhost:3000", "abc123", "--help", "`go`", "x=y", "こんにちは", "😀", "안녕하세요"] {
            expect((engine.decide(word, precedingText: "지금 한국어로 작성하고 있어.").output) == (word), word)
        }
    }
    func testPunctuationIsPreserved() {
        expect((engine.decide("\"dkssud!\"").output) == ("\"안녕!\""))
        expect((engine.decide("zzzz!").output) == ("ㅋㅋㅋㅋ!"))
        for mark in WordBoundary.punctuation.map(String.init) {
            expect(engine.decide("dkssud" + mark).output == "안녕" + mark, mark)
            expect(engine.decide("3qjsdl" + mark).output == "3번이" + mark, mark)
        }
    }
    func testLeadingNumbers() {
        for (raw, output) in [("3qjsdl", "3번이"), ("128rlrk", "128기가"), ("12dkssud", "12안녕"), ("3zzzz", "3ㅋㅋㅋㅋ"), ("(3qjsdl)", "(3번이)")] {
            expect(engine.decide(raw).output == output, raw)
        }
        for raw in ["123", "3.14", "v3qjsdl", "qjsdl3", "3qjsdl2", "3API", "128GB", "128gb", "30fps", "3hello", "3foo_bar", "3qjsdl.com", "3qjsdl@example.com", "3/qjsdl"] {
            expect(engine.decide(raw).output == raw, raw)
        }
        expect(SuggestionPolicy.fallbackCandidate(for: engine.decide("3asdf")) == "3ㅁㄴㅇㄹ")
        expect(SuggestionPolicy.koreanCandidate(for: engine.decide("(3asdf)")) == "(3ㅁㄴㅇㄹ)")
        expect(SuggestionPolicy.koreanCandidate(for: engine.decide("3asdf2")) == nil)
    }
    func testSingleLetterChoiceAndQuotes() {
        for raw in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init) {
            let decision = engine.decide(raw, precedingText: "지금 한글로 대화하는 중이야.")
            expect(!decision.changed, raw + " must remain Latin by default")
            expect(SuggestionPolicy.fallbackCandidate(for: decision) == Hangul.compose(raw), raw)
        }
        for (raw, expected) in [("r", "ㄱ"), ("g", "ㅎ"), ("k", "ㅏ"), ("R", "ㄲ"), ("3r", "3ㄱ")] {
            expect(SuggestionPolicy.fallbackCandidate(for: engine.decide(raw)) == expected, raw)
        }
        for raw in ["don't", "we're", "I'm", "it's", "you're", "they've", "can't", "didn't", "wouldn't", "isn't", "we’re", "I’m", "John's", "O'Reilly"] {
            expect(engine.decide(raw, precedingText: "한국어 문맥이어도 ").output == raw, raw)
            expect(SuggestionPolicy.koreanCandidate(for: engine.decide(raw)) == nil, raw)
        }
        for (raw, expected) in [("(dkssud)", "(안녕)"), ("[dkssud]", "[안녕]"), ("{3qjsdl}", "{3번이}"), ("\"dkssud\"", "\"안녕\""), ("'dkssud'", "'안녕'"), ("“dkssud”", "“안녕”"), ("‘dkssud’", "‘안녕’"), ("「dkssud」", "「안녕」")] {
            expect(engine.decide(raw).output == expected, raw)
        }
    }
    func testSelectedSentencesAndDominantLanguage() {
        for text in ["안녕. 지금 문장을 바꾸고 있어요!", "첫 문장이에요.\n두 번째 문장이에요?\n\n세 번째 문장입니다.", "(안녕) [3번이] ㄱ 😀"] {
            expect(SelectionConversion.korean(Hangul.keystrokes(for: text)) == text, text)
        }
        expect(SelectionConversion.korean("dkssud API https://example.com `hello world` 128GB 3qjsdl") == "안녕 API https://example.com `hello world` 128GB 3번이")
        expect(SelectionConversion.korean("dkssud\n```swift\nlet x = 3\n```\nrkskek") == "안녕\n```swift\nlet x = 3\n```\n가나다")
        expect(SelectionConversion.korean("r") == "ㄱ")
        expect(SelectionConversion.korean("rkskek.rkskek") == "가나다.가나다")
        expect(SelectionConversion.korean("안녕 😀 https://example.com user@example.com foo_bar v1 /tmp/file API 128GB") == nil)
        expect(SelectionConversion.korean("") == nil)
        expect(SelectionConversion.korean(String(repeating: "r", count: 4097)) == nil)
        expect(SelectionConversion.korean(String(repeating: "r", count: 4096)) == String(repeating: "ㄱ", count: 4096))
        let koreanContext = "지금은 한국어로 긴 문장을 작성하고 있습니다. 주로 한글을 사용하고 영어 용어만 가끔 섞어서 이야기하고 있어요. "
        for text in ["간ㅇㄷ", "가남ㄴㅇㄹ", "가나담ㄴㅇㄹ"] {
            let raw = Hangul.keystrokes(for: text)
            let ko = engine.decide(raw, precedingText: koreanContext, preferred: .english)
            expect(ko.output == text, raw)
            expect(ko.usedContext, raw)
            expect(engine.decide(raw, precedingText: "We are writing a paragraph in English. ", preferred: .english).output == raw, raw)
        }
        for raw in ["r", "hello", "world", "API", "fooBar", "user@example.com", "128GB", "file_path"] {
            expect(engine.decide(raw, precedingText: koreanContext).output == raw, raw)
        }
        let reportedContext = "안녕. 지금 문장을 바꾸고 있어요, 두세 문장을 한번에 "
        expect(engine.decide("qkRnjqhrpTdjdy", precedingText: reportedContext).output == "바꿔보겠어요")
        expect(engine.decide("qkRnjqhrpTdjdy", precedingText: "We are writing in English. ", preferred: .english).output == "qkRnjqhrpTdjdy")
        for raw in ["QKfmrp", "Qkfmrp", "qkRnjqhrpTdjdy"] {
            expect(engine.decide(raw, precedingText: reportedContext).output == Hangul.compose(raw), raw)
        }
        expect(engine.decide("QKfmrp").output == "빠르게")
        for text in ["다시써보겠습니다", "조금씩바꿔보겠어요", "깜빡깜빡해졌어요"] {
            let raw = Hangul.keystrokes(for: text)
            expect(engine.decide(raw, precedingText: koreanContext).output == text, raw)
        }
        for raw in ["fooBar", "getResponse", "setTime", "API", "OpenAI", "getUserName", "helloWorld"] {
            expect(engine.decide(raw, precedingText: koreanContext).output == raw, raw)
        }
    }
    func testModeCycle() {
        expect((InputMode.korean.next) == (.english))
        expect((InputMode.english.next) == (.automatic))
        expect((InputMode.automatic.next) == (.korean))
    }
}

let checks = InputCoreTests()
checks.testLexiconsArePackaged()
checks.testTwoSetComposition()
checks.testEveryHangulSyllableRoundTrips()
checks.testKoreanSentencesRoundTrip()
checks.testCommonKoreanAndEnglish()
checks.testChatExpressions()
checks.testAmbiguousGoUsesParagraphContext()
checks.testPreviousParagraphWithBlankLine()
checks.testContextBoundAndScope()
checks.testNoContextUsesPreference()
checks.testMixedKoreanParagraphWithEnglishTerms()
checks.testProtectsTechnicalTokensAndAddresses()
checks.testPunctuationIsPreserved()
checks.testLeadingNumbers()
checks.testSingleLetterChoiceAndQuotes()
checks.testSelectedSentencesAndDominantLanguage()
checks.testModeCycle()
print("Core checks: 17 groups, \(assertions) assertions, \(failures) failures")
exit(failures == 0 ? 0 : 1)
