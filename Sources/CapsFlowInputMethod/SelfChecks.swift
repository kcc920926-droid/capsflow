import Cocoa
import InputCore

private final class MemoryClient: CompositionClient {
    var text: String
    var selection: NSRange
    var marked = NSRange(location: NSNotFound, length: NSNotFound)
    private(set) var writes = 0
    var reportsLength = true
    private(set) var lengthReads = 0
    var emptyCommitKeepsText = false
    private(set) var clearCalls = 0
    private(set) var emptyCommitCalls = 0
    var documentLength: Int? { lengthReads += 1; return reportsLength ? text.utf16.count : nil }
    init(_ text: String = "", caret: Int? = nil) {
        self.text = text; selection = NSRange(location: caret ?? text.utf16.count, length: 0)
    }
    func substring(_ range: NSRange) -> String? {
        guard range.location != NSNotFound, range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location else { return nil }
        return (text as NSString).substring(with: range)
    }
    private func replace(_ value: String, range: NSRange) {
        precondition(substring(range) != nil, "Invalid native replacement range")
        text = (text as NSString).replacingCharacters(in: range, with: value)
        selection = NSRange(location: range.location + value.utf16.count, length: 0)
        writes += 1
    }
    func mark(_ text: String) {
        let range = marked.location != NSNotFound ? marked : selection
        replace(text, range: range)
        marked = NSRange(location: range.location, length: text.utf16.count)
    }
    func clearMarkedText() {
        clearCalls += 1
        guard marked.location != NSNotFound else { return }
        replace("", range: marked)
        marked = NSRange(location: NSNotFound, length: NSNotFound)
    }
    func insert(_ text: String, replacing range: NSRange) {
        if text.isEmpty, range.location == NSNotFound, marked.location != NSNotFound {
            emptyCommitCalls += 1
            if emptyCommitKeepsText {
                marked = NSRange(location: NSNotFound, length: NSNotFound)
                return
            }
        }
        let actual = range.location == NSNotFound ? (marked.location == NSNotFound ? selection : marked) : range
        replace(text, range: actual)
        marked = NSRange(location: NSNotFound, length: NSNotFound)
    }
    func hostBackspace() {
        if selection.length > 0 { insert("", replacing: selection) }
        else if selection.location > 0 && selection.location <= text.utf16.count {
            let range = (text as NSString).rangeOfComposedCharacterSequence(at: selection.location - 1)
            insert("", replacing: range)
        }
    }
}

func runInputMethodChecks() {
    var count = 0
    func expect(_ result: @autoclosure () -> Bool, _ label: String) {
        count += 1; precondition(result(), "Input method check failed: \(label)")
    }
    let engine = LanguageEngine()
    func new(_ prefix: String = "", caret: Int? = nil) -> (CompositionSession, MemoryClient) {
        (CompositionSession(language: engine), MemoryClient(prefix, caret: caret))
    }
    var clock = 0.0
    func type(_ raw: String, _ session: CompositionSession, _ client: MemoryClient, gap: Double = 0.04) {
        for c in raw {
            clock += gap
            let key: UInt16 = c == " " ? 49 : 0
            if !session.handle(InputStroke(key: key, text: String(c), time: clock), client: client) {
                client.insert(String(c), replacing: CompositionSession.currentSelection)
            }
        }
    }
    func backspace(_ session: CompositionSession, _ client: MemoryClient) {
        clock += 0.04
        if !session.handle(InputStroke(key: 51, text: "", time: clock), client: client) { client.hostBackspace() }
    }
    // Model a host where empty insert merely ends the marked session. Deletion
    // must use the composition-cancel operation, not rely on a second key press.
    for english in [false, true] {
        for raw in ["r", "R", "k", "g", "asdf"] {
            let (session, client) = new("😀앞뒤", caret: 3)
            client.emptyCommitKeepsText = true
            type(raw, session, client)
            if english { _ = session.toggle(client) }
            for _ in raw { backspace(session, client) }
            expect(client.text == "😀앞뒤", "one Backspace per raw key, including last jamo/Latin")
            expect(client.clearCalls == 1 && client.emptyCommitCalls == 0, "explicit cancel, not empty commit")
            expect(client.selection == NSRange(location: 3, length: 0), "last deletion preserves neighboring text/caret")
            type("gksrmf ", session, client)
            expect(client.text == "😀앞한글 뒤", "typing immediately after cancel keeps suffix")
        }
    }
    do {
        let (session, client) = new()
        client.emptyCommitKeepsText = true
        type("hello world python ", session, client)
        client.text = ""; client.selection = NSRange(location: 0, length: 0)
        type("r", session, client); _ = session.toggle(client)
        backspace(session, client)
        expect(client.text.isEmpty && client.clearCalls == 1, "single Backspace erases final explicit r")
        type("gksrmf", session, client)
        expect(client.text == "한글" && session.composition.recentEnglish == 0, "cancel then empty-document context reset")
    }
    // Regression: fully erasing an explicitly English preedit left its Boolean
    // override stuck on, so the following Korean run displayed/committed Latin.
    for raw in ["r", "asdf", "hello", "QKfmrp"] {
        let (session, client) = new()
        type(raw, session, client)
        expect(session.toggle(client), "choose English before erase")
        expect(session.composition.englishOverride, "English override active")
        for _ in raw { backspace(session, client) }
        expect(client.text.isEmpty, "erased English run")
        expect(session.composition.explicitLanguage == nil, "no sticky explicit choice")
        expect(session.composition.recentEnglish == 0, "empty field clears language context")
        expect(session.candidate == nil, "empty field clears candidate")
        type("asdf ", session, client)
        expect(client.text == "ㅁㄴㅇㄹ ", "new Korean after erase \(raw)")
    }
    do {
        let (session, client) = new()
        type("hello", session, client)
        expect(session.toggle(client), "manual English")
        expect(session.toggle(client), "explicitly reject English")
        expect(session.composition.explicitLanguage == .korean, "explicit Korean stored")
        type(" ", session, client)
        expect(client.text == Hangul.compose("hello") + " ", "Space cannot override explicit Korean with dictionary English")
        expect(session.composition.explicitLanguage == nil, "choice ends with word")
    }
    do {
        let (session, client) = new()
        type("hello world python ", session, client)
        expect(session.composition.recentEnglish == 3, "prime English context")
        client.selection = NSRange(location: 0, length: client.text.utf16.count)
        backspace(session, client)
        expect(client.text.isEmpty, "native selected document erase")
        let readsBefore = client.lengthReads
        type("r", session, client)
        expect(client.text == "ㄱ", "fresh Korean after selected erase")
        expect(session.composition.recentEnglish == 0, "selected erase resets old language evidence")
        expect(client.lengthReads == readsBefore + 1, "check host deletion once before next word")
        type("kskek", session, client)
        expect(client.lengthReads == readsBefore + 1, "no document-length IPC on ordinary letters")
    }
    for existing in ["a", "한", "😀", "👨‍👩‍👧‍👦"] {
        let (session, client) = new()
        type("hello world python ", session, client)
        client.text = existing; client.selection = NSRange(location: existing.utf16.count, length: 0)
        backspace(session, client)
        expect(client.text.isEmpty, "host deletes final grapheme \(existing)")
        type("gks", session, client)
        expect(session.composition.recentEnglish == 0, "final grapheme erase resets history")
        expect(client.text == "한", "fresh Korean after final grapheme")
    }
    for blank in [" ", "\n", "\r\n", "\u{200B}", "\u{FEFF}", "\u{2060}", " \n\u{200B}"] {
        let (session, client) = new()
        type("hello world python ", session, client)
        client.text = blank + "x"; client.selection = NSRange(location: client.text.utf16.count, length: 0)
        backspace(session, client); type("r", session, client)
        expect(session.composition.recentEnglish == 0, "blank/placeholder field resets language context")
        expect(client.text == blank + "ㄱ", "blank markers are preserved, not deleted")
    }
    do {
        let (session, client) = new()
        type("hello world python ", session, client)
        client.text = "뒤쪽"; client.selection = NSRange(location: 0, length: 0)
        backspace(session, client)
        type("r", session, client)
        expect(client.text == "ㄱ뒤쪽", "caret zero is not an empty document")
        expect(session.composition.recentEnglish == 3, "preserve context when suffix remains")
    }
    do {
        let (session, client) = new()
        type("hello world python ", session, client)
        client.reportsLength = false
        client.selection = NSRange(location: 0, length: client.text.utf16.count)
        backspace(session, client); type("r", session, client)
        expect(session.composition.recentEnglish == 0, "unsupported length gets safe fresh context")
        expect(client.text == "ㄱ", "unsupported length never changes native deletion")
    }
    do {
        let (session, client) = new()
        type("asdf", session, client); _ = session.toggle(client)
        backspace(session, client)
        expect(client.text == "asd" && session.composition.englishOverride, "partial deletion keeps current word choice")
        for _ in 0..<3 { backspace(session, client) }
        type("r", session, client)
        expect(client.text == "ㄱ" && session.composition.explicitLanguage == nil, "full deletion resets choice")
    }
    for key in [UInt16(7), 6, 117] {
        let (session, client) = new()
        type("hello world python ", session, client)
        expect(!session.handle(InputStroke(key: key, text: "", time: clock, command: key != 117), client: client), "host destructive action passed through")
        client.selection = NSRange(location: 0, length: client.text.utf16.count)
        client.insert("", replacing: client.selection)
        expect(!session.toggle(client), "cleared field cannot resurrect old last-word/selection edit")
        expect(session.composition.recentEnglish == 0, "cut/undo/delete empty-field reset")
    }
    // Marked-text appearance is separate from composition/language policy.
    do {
        let names: [Any] = [NSAttributedString.Key.underlineStyle.rawValue,
                            NSAttributedString.Key.backgroundColor.rawValue, NSAttributedString.Key.markedClauseSegment]
        let attributes = CompositionAppearance.attributes(supportedNames: names)
        expect(attributes[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue, "single thin underline")
        expect((attributes[.backgroundColor] as? NSColor)?.alphaComponent == 0, "no block background")
        expect(attributes[.font] == nil && attributes[.foregroundColor] == nil, "inherit host font and text color")
        let limited = CompositionAppearance.attributes(supportedNames: [NSAttributedString.Key.underlineStyle.rawValue])
        expect(limited.count == 1, "send supported attributes only")
        expect(CompositionAppearance.attributes(supportedNames: []).isEmpty, "no unsupported styling")
        for text in ["", "한글", "r", "😀한"] {
            let marked = CompositionAppearance.text(text, attributes: attributes)
            expect(marked.string == text, "style preserves Unicode text")
            expect(CompositionAppearance.selection(for: text) == NSRange(location: text.utf16.count, length: 0), "caret not selection")
        }
        // Own in-process AppKit view only, no external app/UI inspection.
        _ = NSApplication.shared
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        view.markedTextAttributes = [.backgroundColor: NSColor.yellow, .underlineStyle: NSUnderlineStyle.thick.rawValue]
        let styled = CompositionAppearance.text("한글", attributes: attributes)
        expect(styled.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue, "payload requests thin underline")
        expect((styled.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor)?.alphaComponent == 0, "payload requests no highlight")
        view.setMarkedText(styled,
                           selectedRange: CompositionAppearance.selection(for: "한글"),
                           replacementRange: CompositionSession.currentSelection)
        expect(view.string == "한글" && view.hasMarkedText(), "native attributed composition remains active")
        expect(view.selectedRange() == NSRange(location: 2, length: 0), "native caret is after composition")
        // AppKit's marked rendering is not represented as persistent textStorage
        // attributes. The host's visible rendering needs a separate UI check.
        view.insertText("한글 ", replacementRange: CompositionSession.currentSelection)
        expect(view.string == "한글 " && !view.hasMarkedText(), "Space/commit finishes attributed composition")
        expect((view.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int ?? 0) == 0, "underline does not leak into committed text")
        for value in ["r", "ㄱ"] {
            view.string = "앞뒤"; view.setSelectedRange(NSRange(location: 1, length: 0))
            view.setMarkedText(CompositionAppearance.text(value, attributes: attributes),
                               selectedRange: CompositionAppearance.selection(for: value),
                               replacementRange: CompositionSession.currentSelection)
            view.setMarkedText(CompositionAppearance.text("", attributes: attributes),
                               selectedRange: CompositionAppearance.selection(for: ""),
                               replacementRange: CompositionSession.currentSelection)
            expect(view.string == "앞뒤" && !view.hasMarkedText(), "native empty composition deletes \(value) once")
            expect(view.selectedRange() == NSRange(location: 1, length: 0), "native cancel preserves neighbors")
        }
    }
    for text in ["안녕", "심지어", "분위기는", "바꿔보겠어요", "빠르게", "한글", "ㄱ", "ㅁㄴㅇㄹ", "3번이", "ㅋㅋㅋㅋ"] {
        let (session, client) = new()
        type(Hangul.keystrokes(for: text), session, client)
        expect(client.text == text, "native Korean preedit \(text)")
        type(" ", session, client)
        expect(client.text == text + " ", "Korean-first commit \(text)")
        expect(client.marked.location == NSNotFound, "unmarked commit")
    }
    for text in ["hello", "world", "API", "Codex", "python", "128GB", "https://example.com", "user@example.com", "foo_bar", "we're", "didn't"] {
        let (session, client) = new()
        type(text + " ", session, client)
        expect(client.text == text + " ", "clear English \(text)")
    }
    // All uncertainty defaults to Korean, even with a long English streak and
    // an arbitrarily large slowdown. Speed alone is never evidence of English.
    for raw in ["r", "go", "qkRnjqhrpTdjdy", "QKfmrp", "tlawldj", "dkslrrk", "asdf", "zzzz"] {
        expect(engine.koreanFirst(raw, recentEnglish: 8, slowdown: 99).output == Hangul.compose(raw), "uncertain/KO stays Korean \(raw)")
    }
    do {
        let (session, client) = new()
        type("gks", session, client); clock += 10
        type("rmf", session, client)
        expect(client.text == "한글", "pause and append within composition")
        session.commit(to: client)
        type("gks", session, client); session.commit(to: client)
        type("rmf", session, client); session.commit(to: client)
        expect(client.text == "한글한글", "append after committed Korean prefix")
    }
    for delimiter in Array(WordBoundary.punctuation).map(String.init) {
        let (session, client) = new("😀existing", caret: 2)
        type("3qjsdl" + delimiter, session, client)
        expect(client.text == "😀3번이" + delimiter + "existing", "suffix preserved: \(delimiter)")
    }
    do {
        let (session, client) = new()
        type("(dkssud) [3qjsdl] \"dkssud\"", session, client)
        expect(client.text == "(안녕) [3번이] \"안녕\"", "brackets and quotes")
    }
    for _ in 0..<3 {
        let (session, client) = new()
        for iteration in 0..<4 {
            type("r", session, client)
            expect(client.text.hasSuffix("ㄱ"), "r defaults to ㄱ")
            expect(!session.flags(key: 61, option: true, command: false, control: false, shift: false, at: clock, client: client), "Option down")
            expect(session.flags(key: 61, option: false, command: false, control: false, shift: false, at: clock + 0.1, client: client), "Option apply")
            expect(client.text.hasSuffix("r"), "manual English")
            type(" ", session, client)
            type("asdf", session, client)
            expect(client.text.hasSuffix("ㅁㄴㅇㄹ"), "next word Korean after Option and Space")
            type(" ", session, client)
            expect(client.text == String(repeating: "r ㅁㄴㅇㄹ ", count: iteration + 1), "repeated Option cycles")
        }
    }
    do {
        let (session, client) = new("😀뒤쪽", caret: 2)
        type("gks", session, client)
        for expected in ["하", "ㅎ", ""] {
            expect(session.handle(InputStroke(key: 51, text: "", time: clock), client: client), "native backspace consumed")
            expect(client.text == "😀" + expected + "뒤쪽", "backspace jamo \(expected)")
        }
        expect(!session.handle(InputStroke(key: 51, text: "", time: clock), client: client), "empty delete passed through")
    }
    do {
        let text = "안녕. 지금 문장을 바꾸고 있어요, 두세 문장을 한번에 바꿔보겠어요. 빠르게 한글을 쓰고 있습니다!"
        for _ in 0..<20 {
            let (session, client) = new("앞😀뒤", caret: 3)
            type(Hangul.keystrokes(for: text), session, client, gap: 0.001)
            session.commit(to: client)
            expect(client.text == "앞😀" + text + "뒤", "rapid native sentence composition")
        }
    }
    do {
        let (session, client) = new("😀dkssud. rkskek! suffix")
        let original = "dkssud. rkskek!"
        client.selection = NSRange(location: 2, length: original.utf16.count)
        expect(session.toggle(client), "selected sentence conversion")
        expect(client.text == "😀안녕. 가나다! suffix", "selected range only")
        client.selection = NSRange(location: 2, length: "안녕. 가나다!".utf16.count)
        expect(session.toggle(client), "selection exact undo")
        expect(client.text == "😀dkssud. rkskek! suffix", "undo preserves suffix")
        client.selection = NSRange(location: NSNotFound, length: NSNotFound)
        expect(!session.toggle(client), "unsupported range fails safely")
    }
    for key in [UInt16(36), 48, 53, 123, 124, 125, 126] {
        let (session, client) = new()
        type("hello", session, client)
        expect(!session.handle(InputStroke(key: key, text: "", time: clock), client: client), "native navigation/Enter passed once")
        expect(client.text == "hello", "commit before host navigation")
        expect(session.composition.isEmpty, "navigation clears raw buffer")
    }
    do {
        var timing = TypingCadence()
        for i in 0..<10 { timing.observe(at: Double(i) * 0.05) }
        timing.finish(language: .korean)
        for i in 0..<10 { timing.observe(at: 10 + Double(i) * 0.15) }
        expect(timing.slowdown > 2.5, "relative cadence signal")
        timing.finish(language: .english)
        timing.observe(at: 100); timing.observe(at: 150)
        expect(timing.slowdown == 1, "idle gap ignored")
    }
    print("Native IME checks: \(count) passed (in-memory client; no external UI input)")
}
