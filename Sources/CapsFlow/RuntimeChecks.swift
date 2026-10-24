import Cocoa
import InputCore

// Pure regression checks: no keystrokes, text reads, permission prompts or IME changes.
func runRuntimeChecks() {
    var checks = 0
    func expect(_ value: Bool) { checks += 1; precondition(value, "Runtime check \(checks) failed") }
    var hold = BackspaceHold()
    expect(EventEngine.isUnmodifiedBackspace([]))
    expect(EventEngine.isUnmodifiedBackspace(.maskAlphaShift))
    for flags: CGEventFlags in [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn,
                               [.maskCommand, .maskAlternate], [.maskControl, .maskShift]] {
        expect(!EventEngine.isUnmodifiedBackspace(flags))
    }
    expect(!hold.wordDeletion(repeating: true, at: 10, eligible: true)) // lost initial keyDown
    expect(!hold.wordDeletion(repeating: false, at: 10, eligible: true))
    expect(!hold.wordDeletion(repeating: true, at: 10.4, eligible: true))
    expect(!hold.wordDeletion(repeating: true, at: 10.999, eligible: true))
    expect(hold.wordDeletion(repeating: true, at: 11, eligible: true))
    expect(hold.wordDeletion(repeating: true, at: 11.04, eligible: true))
    hold.reset() // release/focus/click/modifier/mode/pause
    expect(!hold.wordDeletion(repeating: true, at: 11.1, eligible: true))
    for start in 0..<40 {
        let time = Double(start) * 3
        expect(!hold.wordDeletion(repeating: false, at: time, eligible: true))
        expect(!hold.wordDeletion(repeating: true, at: time + 0.5, eligible: true))
        expect(hold.wordDeletion(repeating: true, at: time + 1, eligible: true))
        expect(hold.wordDeletion(repeating: true, at: time + 1.1, eligible: true))
        hold.reset()
        expect(!hold.wordDeletion(repeating: true, at: time + 1.2, eligible: true))
    }
    expect(!hold.wordDeletion(repeating: false, at: 10, eligible: true))
    expect(!hold.wordDeletion(repeating: true, at: 11, eligible: false))
    expect(!hold.wordDeletion(repeating: true, at: 11.1, eligible: true))
    for time in [Double.nan, Double.infinity, -Double.infinity] {
        _ = hold.wordDeletion(repeating: false, at: 0, eligible: true)
        expect(!hold.wordDeletion(repeating: true, at: time, eligible: true))
        expect(!hold.wordDeletion(repeating: true, at: 1, eligible: true))
    }
    _ = hold.wordDeletion(repeating: false, at: 20, eligible: true)
    expect(!hold.wordDeletion(repeating: true, at: 19, eligible: true))
    _ = hold.wordDeletion(repeating: false, at: 20, eligible: true)
    expect(!hold.wordDeletion(repeating: true, at: 23, eligible: true)) // stale/missing keyUp
    expect(!hold.wordDeletion(repeating: false, at: 30, eligible: false))
    expect(!hold.wordDeletion(repeating: true, at: 31, eligible: true))
    // A fast new tap starts over even if a remote keyUp was lost.
    _ = hold.wordDeletion(repeating: false, at: 40, eligible: true)
    expect(hold.wordDeletion(repeating: true, at: 41, eligible: true))
    expect(!hold.wordDeletion(repeating: false, at: 41.1, eligible: true))
    expect(!hold.wordDeletion(repeating: true, at: 41.2, eligible: true))
    // Remote Caps packets and local F18 are tested without posting any input.
    var trigger = CapsToggleTrigger()
    func packet(_ type: CGEventType, _ key: Int64, _ flags: CGEventFlags = [], _ time: Double = 1,
                repeatKey: Bool = false) -> CapsToggleTrigger.Result {
        trigger.observe(type: type, key: key, flags: flags, repeating: repeatKey, time: time)
    }
    expect(packet(.keyDown, 0) == .pass)
    expect(packet(.leftMouseDown, 57) == .pass)
    expect(!trigger.capturedRawCaps)
    expect(packet(.keyDown, 79) == .toggle)
    expect(packet(.keyDown, 79) == .consume)
    expect(packet(.keyDown, 79, [], 1.1, repeatKey: true) == .consume)
    expect(packet(.keyUp, 79) == .consume)
    expect(packet(.keyDown, 79) == .toggle)
    trigger.reset()
    // Flags-only clients toggle on either latch edge, not on a duplicate release.
    for index in 0..<40 {
        let flags: CGEventFlags = index.isMultiple(of: 2) ? .maskAlphaShift : []
        let time = 2 + Double(index) * 0.02
        expect(packet(.flagsChanged, 57, flags, time) == .toggle)
        expect(packet(.flagsChanged, 57, flags, time + 0.001) == .consume)
    }
    expect(trigger.capturedRawCaps)
    trigger.reset()
    expect(packet(.flagsChanged, 57, [], 1) == .toggle) // first edge may be Off
    trigger.reset()
    for index in 0..<40 {
        let time = 3 + Double(index) * 0.05
        expect(packet(.keyDown, 57, [], time) == .toggle)
        expect(packet(.keyDown, 57, [], time + 0.001, repeatKey: true) == .consume)
        expect(packet(.keyUp, 57, [], time + 0.002) == .consume)
    }
    // Key-pair clients that additionally publish latch transitions count once.
    for flagsFirst in [false, true] {
        trigger.reset()
        for index in 0..<20 {
            let flags: CGEventFlags = index.isMultiple(of: 2) ? .maskAlphaShift : []
            let time = 10 + Double(index) * 0.1
            if flagsFirst {
                expect(packet(.flagsChanged, 57, flags, time) == .toggle)
                expect(packet(.keyDown, 57, flags, time + 0.005) == .consume)
            } else {
                expect(packet(.keyDown, 57, flags, time) == .toggle)
                expect(packet(.flagsChanged, 57, flags, time + 0.005) == .consume)
            }
            expect(packet(.keyUp, 57, flags, time + 0.01) == .consume)
        }
    }
    trigger.reset()
    expect(packet(.keyDown, 57, .maskAlphaShift, 1) == .toggle)
    expect(packet(.keyUp, 57, .maskAlphaShift, 1.005) == .consume)
    expect(packet(.flagsChanged, 57, .maskAlphaShift, 1.01) == .consume)
    expect(packet(.flagsChanged, 57, [], 1.1) == .toggle)
    trigger.reset()
    expect(packet(.keyDown, 49, [.maskControl, .maskShift]) == .toggle)
    expect(packet(.keyDown, 49, [.maskControl, .maskShift], 1, repeatKey: true) == .consume)
    expect(packet(.keyUp, 49) == .consume) // modifiers can be released first
    expect(packet(.keyDown, 49, [.maskControl, .maskShift]) == .toggle)
    trigger.releaseHeldKeys()
    expect(packet(.keyDown, 49, [.maskControl, .maskShift]) == .toggle)
    trigger.reset()
    for flags: CGEventFlags in [[], .maskShift, .maskControl, [.maskControl, .maskShift, .maskCommand],
                               [.maskControl, .maskShift, .maskAlternate]] {
        expect(packet(.keyDown, 49, flags) == .pass)
    }
    for scalar in Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz") {
        let text = String(scalar)
        expect(CapsToggleTrigger.unlatchedASCII(text, flags: .maskAlphaShift) == text.lowercased())
        expect(CapsToggleTrigger.unlatchedASCII(text, flags: [.maskAlphaShift, .maskShift]) == text.uppercased())
    }
    for text in ["안녕", "😀", "ABC", "aB", "1", "!", "", "é"] {
        expect(CapsToggleTrigger.unlatchedASCII(text, flags: .maskAlphaShift) == text)
    }
    for flags: CGEventFlags in [[], .maskShift, [.maskAlphaShift, .maskAlternate],
                               [.maskAlphaShift, .maskCommand], [.maskAlphaShift, .maskControl]] {
        expect(CapsToggleTrigger.unlatchedASCII("A", flags: flags) == "A")
    }
    expect(CapsLockBehavior.restored(nil) == .cycle)
    expect(CapsLockBehavior.restored("unknown") == .cycle)
    expect(CapsLockBehavior.restored("speed") == .speed)
    expect(CapsLockBehavior.restored("cycle") == .cycle)
    expect(CapsLockBehavior.cycle.next(from: .korean) == .english)
    expect(CapsLockBehavior.cycle.next(from: .english) == .automatic)
    expect(CapsLockBehavior.cycle.next(from: .automatic) == .korean)
    expect(CapsLockBehavior.speed.next(from: .korean) == .english)
    expect(CapsLockBehavior.speed.next(from: .english) == .korean)
    expect(CapsLockBehavior.speed.next(from: .automatic) == .english)
    for start in InputMode.allCases {
        var mode = start
        for _ in 0..<40 {
            mode = CapsLockBehavior.speed.next(from: mode)
            expect(mode != .automatic)
        }
    }
    expect(InputSources.matches(.korean, identifier: "com.apple.inputmethod.Korean.2SetKorean"))
    expect(!InputSources.matches(.korean, identifier: "com.apple.keylayout.ABC"))
    for mode in [InputMode.english] {
        expect(InputSources.matches(mode, identifier: "com.apple.keylayout.ABC"))
        expect(InputSources.matches(mode, identifier: "com.apple.keylayout.US"))
        expect(!InputSources.matches(mode, identifier: "com.apple.inputmethod.Korean.2SetKorean"))
    }
    expect(InputSources.matches(.automatic, identifier: InputSources.automaticID))
    expect(!InputSources.matches(.automatic, identifier: "com.apple.keylayout.ABC"))
    expect(!InputSources.matches(.automatic, identifier: "com.apple.keylayout.US"))
    expect(InputSources.modeAfterSourceChange(.automatic, identifier: "com.apple.inputmethod.Korean.2SetKorean") == .korean)
    expect(InputSources.modeAfterSourceChange(.automatic, identifier: "com.apple.keylayout.ABC") == .english)
    expect(InputSources.modeAfterSourceChange(.automatic, identifier: "com.apple.keylayout.US") == .english)
    expect(InputSources.modeAfterSourceChange(.english, identifier: InputSources.automaticID) == .automatic)
    expect(InputSources.modeAfterSourceChange(.korean, identifier: "com.apple.keylayout.ABC") == .english)
    expect(InputSources.modeAfterSourceChange(.english, identifier: "com.apple.inputmethod.Korean.2SetKorean") == .korean)
    expect(InputSources.modeAfterSourceChange(.automatic, identifier: "another.IME") != .automatic)
    // Actual broken 0.1.2 tap: only mouse and flagsChanged were granted.
    expect(!EventEngine.hasKeyboardEvents(33_558_538))
    expect(EventEngine.hasKeyboardEvents(33_561_610))
    expect(!EventEngine.hasKeyboardEvents(EventEngine.keyboardMask & ~(CGEventMask(1) << CGEventType.keyDown.rawValue)))
    expect(!EventEngine.hasKeyboardEvents(EventEngine.keyboardMask & ~(CGEventMask(1) << CGEventType.keyUp.rawValue)))
    expect(!EventEngine.hasKeyboardEvents(0))
    expect(!EventEngine.needsSessionReplay(type: .keyDown, key: 0, flags: []))
    expect(!EventEngine.needsSessionReplay(type: .keyDown, key: 0, flags: [.maskShift]))
    expect(!EventEngine.needsSessionReplay(type: .keyUp, key: 49, flags: []))
    expect(EventEngine.needsSessionReplay(type: .keyDown, key: 49, flags: [.maskControl]))
    expect(EventEngine.needsSessionReplay(type: .keyDown, key: 6, flags: [.maskCommand, .maskAlternate]))
    expect(EventEngine.needsSessionReplay(type: .flagsChanged, key: 61, flags: []))
    for key in [Int64(53), 115, 119, 116, 121, 117, 123, 124, 125, 126] {
        expect(EventEngine.restartsAtCaret(key: key))
    }
    for key in [Int64(0), 49, 36, 48, 51, 61, 79] {
        expect(!EventEngine.restartsAtCaret(key: key))
    }
    let element = AXUIElementCreateApplication(getpid())
    let selected = SelectedTextSnapshot(element: element, pid: getpid(), range: NSRange(location: 3, length: 6), text: "dkssud", writable: true, directWrite: false)
    expect(selected.matches(selected))
    for changed in [
        SelectedTextSnapshot(element: element, pid: getpid(), range: NSRange(location: 4, length: 6), text: "dkssud", writable: true, directWrite: false),
        SelectedTextSnapshot(element: element, pid: getpid(), range: NSRange(location: 3, length: 5), text: "dkssu", writable: true, directWrite: false),
        SelectedTextSnapshot(element: element, pid: getpid() + 1, range: selected.range, text: selected.text, writable: true, directWrite: false),
        SelectedTextSnapshot(element: AXUIElementCreateApplication(getpid() + 1), pid: getpid(), range: selected.range, text: selected.text, writable: true, directWrite: false),
        SelectedTextSnapshot(element: element, pid: getpid(), range: selected.range, text: selected.text, writable: false, directWrite: false)
    ] { expect(!selected.matches(changed)) }
    for (before, after, token, expected) in [
        ("dkssud", "", "dkssud", true),
        ("앞 문맥\ndkssud", "", "dkssud", true),
        ("oldworddkssud", "", "dkssud", false),
        ("dkssud", "suffix", "dkssud", true),
        ("dkssud", "_suffix", "dkssud", true),
        ("dkssud", "뒤쪽 단어", "dkssud", true),
        ("문맥 3qjsdl", "기존 문장", "3qjsdl", true),
        ("oldworddkssud", "뒤쪽", "dkssud", false),
        ("oldword3qjsdl", "뒤쪽", "3qjsdl", false),
        ("/dkssud", "", "dkssud", false),
        ("dkssud", " ", "dkssud", true),
        ("different", "", "dkssud", false),
        ("", "", "", false)
    ] {
        let snapshot = TextSnapshot(element: element, pid: getpid(), before: before, after: after, caret: (before as NSString).length)
        expect(AccessibilityContext.validates(snapshot, token: token) == expected)
    }
    let language = LanguageEngine()
    for (raw, candidate) in [
        ("dkssud", "안녕"), ("(dkssud)", "(안녕)"), ("zzzzzz", "ㅋㅋㅋㅋㅋㅋ"),
        ("dd", "ㅇㅇ"), ("tlawldj", "심지어")
    ] { expect(SuggestionPolicy.koreanCandidate(for: language.decide(raw)) == candidate) }
    for raw in ["user@example.com", "https://example.com", "file_path", "abc123", "", String(repeating: "a", count: 81)] {
        expect(SuggestionPolicy.koreanCandidate(for: language.decide(raw)) == nil)
    }
    // A manual fallback must not inherit automatic confidence/English filters.
    for raw in ["hello", "api", "SomeUnknownIdentifier", "asdf"] {
        let decision = language.decide(raw, preferred: .english)
        expect(!decision.changed)
        expect(SuggestionPolicy.fallbackCandidate(for: decision) == Hangul.compose(raw))
    }
    expect(SuggestionPolicy.fallbackCandidate(for: language.decide("dkssud")) == nil)
    expect(SuggestionPolicy.fallbackCandidate(for: language.decide("tlawldj")) == nil)
    for raw in ["r", "R", "g", "k", "d", "3r", "(r)", "「r」"] {
        let decision = language.decide(raw)
        expect(!decision.changed)
        expect(SuggestionPolicy.fallbackCandidate(for: decision) == Hangul.compose(raw))
    }
    let replacement = TextSnapshot(element: element, pid: getpid(), before: "문맥 asdf", after: "", caret: 7)
    expect(AccessibilityContext.validatesReplacement(replacement, element: element, caret: 7, original: "asdf"))
    expect(!AccessibilityContext.validatesReplacement(replacement, element: element, caret: 8, original: "asdf"))
    expect(!AccessibilityContext.validatesReplacement(replacement, element: AXUIElementCreateApplication(getpid() + 1), caret: 7, original: "asdf"))
    expect(!AccessibilityContext.validatesReplacement(replacement, element: element, caret: 7, original: "wrong"))
    let firstInput = TextSnapshot(element: element, pid: getpid(), before: "asdf", after: "", caret: 4)
    let continued = TextContinuation.afterReplacing(firstInput, original: "asdf", replacement: "ㅁㄴㅇㄹ", delimiter: "")!
    expect(continued.caret == 4)
    let secondInput = TextSnapshot(element: element, pid: getpid(), before: "ㅁㄴㅇㄹasdf", after: "", caret: 8)
    expect(!AccessibilityContext.validates(secondInput, token: "asdf")) // no blanket partial-word bypass
    expect(AccessibilityContext.validates(secondInput, token: "asdf", continuation: continued))
    expect(AccessibilityContext.validatesReplacement(secondInput, element: element, caret: 8, original: "asdf", continuation: continued))
    let secondAccepted = TextContinuation.afterReplacing(secondInput, original: "asdf", replacement: "ㅁㄴㅇㄹ", delimiter: "")!
    let thirdInput = TextSnapshot(element: element, pid: getpid(), before: "ㅁㄴㅇㄹㅁㄴㅇㄹasdf", after: "", caret: 12)
    expect(AccessibilityContext.validates(thirdInput, token: "asdf", continuation: secondAccepted))
    let spaced = TextSnapshot(element: element, pid: getpid(), before: "ㅁㄴㅇㄹasdf ", after: "", caret: 9)
    expect(AccessibilityContext.validates(spaced, token: "asdf ", continuation: continued))
    expect(TextContinuation.afterReplacing(spaced, original: "asdf ", replacement: "ㅁㄴㅇㄹ ", delimiter: " ") == nil)
    let syllable = TextContinuation.afterReplacing(firstInput, original: "asdf", replacement: "한글", delimiter: "")!
    expect(syllable.caret == 2)
    let afterSyllable = TextSnapshot(element: element, pid: getpid(), before: "한글asdf", after: "", caret: 6)
    expect(AccessibilityContext.validates(afterSyllable, token: "asdf", continuation: syllable))
    for changed in [
        TextSnapshot(element: element, pid: getpid(), before: "가나다라asdf", after: "", caret: 8),
        TextSnapshot(element: element, pid: getpid(), before: "ㅁㄴㅇㄹasdf", after: "", caret: 9),
        TextSnapshot(element: element, pid: getpid() + 1, before: "ㅁㄴㅇㄹasdf", after: "", caret: 8),
        TextSnapshot(element: AXUIElementCreateApplication(getpid() + 1), pid: getpid(), before: "ㅁㄴㅇㄹasdf", after: "", caret: 8)
    ] { expect(!AccessibilityContext.validates(changed, token: "asdf", continuation: continued)) }
    let withSuffix = TextSnapshot(element: element, pid: getpid(), before: "ㅁㄴㅇㄹasdf", after: "기존단어", caret: 8)
    expect(AccessibilityContext.validates(withSuffix, token: "asdf", continuation: continued))
    expect(AccessibilityContext.validatesReplacement(withSuffix, element: element, caret: 8, original: "asdf", continuation: continued))
    expect(!AccessibilityContext.validatesReplacement(withSuffix, element: element, caret: 9, original: "asdf", continuation: continued))
    for delimiter in WordBoundary.punctuation.map(String.init) {
        expect(WordBoundary.delimiter(key: 999, text: delimiter) == delimiter)
        expect(WordBoundary.isPunctuation(delimiter))
    }
    expect(WordBoundary.delimiter(key: 49, text: " ") == " ")
    expect(WordBoundary.delimiter(key: 36, text: "\r") == "\n")
    expect(WordBoundary.delimiter(key: 76, text: "\r") == "\n")
    expect(WordBoundary.delimiter(key: 48, text: "\t") == "\t")
    for value in ["", "a", "3", "/", "@", "_", "..", "😀"] {
        expect(WordBoundary.delimiter(key: 999, text: value) == nil)
    }
    expect(WordBoundary.settlingDelay(".") == 0.14)
    expect(WordBoundary.settlingDelay(":") == 0.14)
    expect(WordBoundary.settlingDelay("?") == 0)
    expect(!WordBoundary.retainsStructuredRun(raw: "dkssud", delimiter: ".", following: nil, converted: true))
    expect(!WordBoundary.retainsStructuredRun(raw: "dkssud", delimiter: ".", following: " ", converted: true))
    expect(!WordBoundary.retainsStructuredRun(raw: "dkssud", delimiter: "?", following: "r", converted: true))
    expect(WordBoundary.retainsStructuredRun(raw: "go", delimiter: ".", following: "c", converted: true, ambiguous: true))
    expect(!WordBoundary.retainsStructuredRun(raw: "dkssud", delimiter: ".", following: "r", converted: true))
    expect(WordBoundary.retainsStructuredRun(raw: "3", delimiter: ".", following: "1", converted: false))
    expect(WordBoundary.retainsStructuredRun(raw: "https", delimiter: ":", following: "/", converted: false))
    expect(WordBoundary.retainsStructuredRun(raw: "user@example", delimiter: ".", following: nil, converted: false))
    expect(WordBoundary.retainsStructuredRun(raw: "https://example.com", delimiter: "?", following: nil, converted: false))
    expect(WordBoundary.retainsStructuredRun(raw: "foo_bar", delimiter: ",", following: nil, converted: false))
    expect(!WordBoundary.retainsStructuredRun(raw: "https://example.com", delimiter: " ", following: nil, converted: false))
    for quote in ["'", "’"] {
        expect(WordBoundary.retainsStructuredRun(raw: "we", delimiter: quote, following: nil, converted: false))
        expect(WordBoundary.retainsStructuredRun(raw: "I", delimiter: quote, following: "m", converted: false))
        expect(!WordBoundary.retainsStructuredRun(raw: "dkssud", delimiter: quote, following: nil, converted: true))
        for stem in ["didn", "isn", "wouldn", "couldn", "shouldn", "weren", "hadn", "hasn", "haven", "mustn"] {
            // Keep the whole English contraction even if its unfinished stem
            // alone happens to look like a confident Korean keyboard sequence.
            expect(WordBoundary.retainsStructuredRun(raw: stem, delimiter: quote, following: nil, converted: true))
        }
    }
    for opener in WordBoundary.openers.map(String.init) { expect(WordBoundary.isOpening(opener)) }
    for other in ["", "a", "r", "안녕", ")", "”", "’", "[]"] { expect(!WordBoundary.isOpening(other)) }
    expect(language.decide("3qjsdl").output == "3번이")
    expect(SuggestionPolicy.koreanCandidate(for: language.decide("3asdf")) == "3ㅁㄴㅇㄹ")
    // Apply -> Space -> next word, and two further words after conversion.
    for prefix in ["ㅁㄴㅇㄹ ", "ㅁㄴㅇㄹㅁㄴㅇㄹ ", "ㅁㄴㅇㄹ 안녕 "] {
        let before = prefix + "asdf"
        let value = TextSnapshot(element: element, pid: getpid(), before: before, after: "", caret: before.utf16.count)
        expect(AccessibilityContext.validates(value, token: "asdf"))
        expect(AccessibilityContext.validates(value, token: "asdf", continuation: continued)) // old anchor must not block a fresh word
    }
    let freshWord = TextSnapshot(element: element, pid: getpid(), before: "ㅁㄴㅇㄹ asdf", after: "", caret: 9)
    let staleFrame = TextSnapshot(element: element, pid: getpid(), before: "ㅁㄴㅇㄹ asd", after: "", caret: 8)
    var fakeClock: TimeInterval = 0
    var lookupReads = 0
    let delayed = ContextLookup.find(token: "asdf", read: {
        lookupReads += 1
        return lookupReads < 4 ? staleFrame : freshWord
    }, now: { fakeClock }, pause: { fakeClock += 0.016 })
    expect(delayed.snapshot != nil)
    expect(delayed.attempts == 4) // the former three-read loop missed this update
    expect(delayed.issue == nil)
    fakeClock = 0
    let timed = ContextLookup.find(token: "asdf", budget: 0.05, read: { staleFrame },
                                  now: { fakeClock }, pause: { fakeClock += 0.02 })
    expect(timed.snapshot == nil)
    expect(timed.attempts == 3)
    expect(timed.issue == .tokenMismatch)
    let bounded = ContextLookup.find(token: "asdf", maximumAttempts: 4, read: { nil }, now: { 0 }, pause: {})
    expect(bounded.snapshot == nil)
    expect(bounded.attempts == 4)
    expect(bounded.issue == .unreadable)
    let rejected = ContextLookup.find(token: "asdf", maximumAttempts: 2, read: { secondInput }, now: { 0 }, pause: {})
    expect(rejected.snapshot == nil)
    expect(rejected.issue == .invalidBoundary) // retries never relax word boundaries
    let immediate = ContextLookup.find(token: "asdf", read: { freshWord }, now: { 0 }, pause: { preconditionFailure("fresh read must not pause") })
    expect(immediate.snapshot != nil)
    expect(immediate.attempts == 1)
    let uncertain = language.decide("go", precedingText: "We should write this in English. Let us ", preferred: .english)
    expect(!uncertain.changed)
    expect(SuggestionPolicy.koreanCandidate(for: uncertain) == "해")
    let screen = NSRect(x: 0, y: 0, width: 800, height: 600)
    let size = NSSize(width: 200, height: 49)
    let above = SuggestionPanel.placement(anchor: NSRect(x: 100, y: 100, width: 1, height: 20), size: size, visible: screen)
    expect(above.minY == 126)
    expect(screen.contains(above))
    let edge = SuggestionPanel.placement(anchor: NSRect(x: 790, y: 580, width: 1, height: 18), size: size, visible: screen)
    expect(screen.contains(edge))
    expect(edge.maxY < 580)
    let secondary = NSRect(x: -1280, y: 0, width: 1280, height: 800)
    expect(secondary.contains(SuggestionPanel.placement(anchor: NSRect(x: -20, y: 200, width: 1, height: 18), size: size, visible: secondary)))
    let rightOption: CGEventFlags = [.maskAlternate, RightOptionTap.rightMask]
    let leftOption: CGEventFlags = [.maskAlternate, RightOptionTap.leftMask]
    func tapResult(press: CGEventFlags? = nil, release: CGEventFlags = [], key: Int64 = 61,
                   duration: TimeInterval = 0.1, startEligible: Bool = true, endEligible: Bool = true,
                   interrupt: (CGEventType, Int64, CGEventFlags)? = nil, reset: Bool = false) -> Bool {
        var tap = RightOptionTap()
        _ = tap.observe(type: .flagsChanged, key: key, flags: press ?? rightOption, time: 0, eligible: startEligible)
        if let (type, key, flags) = interrupt { _ = tap.observe(type: type, key: key, flags: flags, time: 0.05, eligible: true) }
        if reset { tap.reset() }
        return tap.observe(type: .flagsChanged, key: key, flags: release, time: duration, eligible: endEligible)
    }
    expect(tapResult())
    expect(tapResult(press: [.maskAlternate])) // aggregate-only keyboard flags
    expect(tapResult(duration: 0.6))
    expect(!tapResult(duration: 0.7))
    expect(!tapResult(duration: -0.1))
    expect(!tapResult(duration: .infinity))
    expect(!tapResult(press: [], release: []))
    expect(!tapResult(press: leftOption, key: 58))
    expect(!tapResult(startEligible: false))
    expect(!tapResult(endEligible: false))
    expect(!tapResult(reset: true))
    expect(!tapResult(interrupt: (.keyDown, 0, rightOption))) // Option+A
    expect(!tapResult(interrupt: (.keyUp, 0, rightOption)))
    expect(!tapResult(interrupt: (.leftMouseDown, 0, [])))
    expect(!tapResult(interrupt: (.flagsChanged, 55, [.maskCommand, .maskAlternate])))
    expect(!tapResult(press: [.maskCommand, .maskAlternate, RightOptionTap.rightMask]))
    expect(!tapResult(press: [.maskShift, .maskAlternate, RightOptionTap.rightMask]))
    expect(!tapResult(press: [.maskControl, .maskAlternate, RightOptionTap.rightMask]))
    expect(!tapResult(press: [.maskSecondaryFn, .maskAlternate, RightOptionTap.rightMask]))
    expect(!tapResult(press: [.maskAlternate, RightOptionTap.rightMask, RightOptionTap.leftMask], release: leftOption))
    expect(!tapResult(release: [.maskCommand]))
    expect(tapResult(press: [.maskAlphaShift, .maskAlternate, RightOptionTap.rightMask], release: [.maskAlphaShift]))
    var singleTap = RightOptionTap()
    expect(!singleTap.observe(type: .flagsChanged, key: 61, flags: rightOption, time: 1, eligible: true))
    expect(singleTap.observe(type: .flagsChanged, key: 61, flags: [], time: 1.1, eligible: true))
    expect(!singleTap.observe(type: .flagsChanged, key: 61, flags: [], time: 1.2, eligible: true))
    print("Runtime checks: \(checks) passed")
}
