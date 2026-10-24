import Cocoa
import InputCore

/// A normal NSTextView exercising the same language engine without TCC permissions.
/// Global event interception deliberately skips this app to prevent double conversion.
final class DemoTextView: NSTextView {
    var engine: EventEngine!
    var report: ((Decision) -> Void)?
    var legacySmokeTesting = false
    private var lastWord: (range: NSRange, shown: String, other: String, caret: Int)?
    private var preference: InputLanguage = .korean
    private var selectionUndo: (range: NSRange, shown: String, original: String)?

    override func becomeFirstResponder() -> Bool {
        if engine != nil { _ = InputSources.select(engine.mode) }
        return super.becomeFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        if !legacySmokeTesting {
            // Actual input, including composition/English recovery, is owned by
            // the selected native IME, not a second local word converter.
            super.keyDown(with: event); return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        if event.keyCode == 6 && flags == [.command, .option], selectedRange().length > 0 {
            let range = selectedRange(), ns = string as NSString
            guard range.location <= ns.length, range.length <= ns.length - range.location,
                  range.length <= SelectionConversion.maximumUTF16 else { return }
            let raw = ns.substring(with: range)
            let restored = selectionUndo.flatMap { $0.range == range && $0.shown == raw ? $0.original : nil }
            guard let output = restored ?? SelectionConversion.korean(raw) else { return }
            insertText(output, replacementRange: range)
            let replaced = NSRange(location: range.location, length: output.utf16.count)
            setSelectedRange(replaced)
            selectionUndo = (replaced, output, raw)
            lastWord = nil
            return
        }
        if event.keyCode == 6 && flags == [.command, .option], let record = lastWord,
           selectedRange().location == record.caret, selectedRange().length == 0,
           NSMaxRange(record.range) <= (string as NSString).length,
           (string as NSString).substring(with: record.range) == record.shown {
            insertText(record.other, replacementRange: record.range)
            let difference = (record.other as NSString).length - record.range.length
            setSelectedRange(NSRange(location: record.caret + difference, length: 0))
            lastWord = (NSRange(location: record.range.location, length: (record.other as NSString).length), record.other, record.shown, record.caret + difference)
            return
        }
        lastWord = nil
        guard engine.mode == .automatic, flags.isEmpty,
              WordBoundary.delimiter(key: Int64(event.keyCode), text: event.characters ?? "") != nil,
              selectedRange().length == 0 else { super.keyDown(with: event); return }
        let location = selectedRange().location
        let prefix = (string as NSString).substring(to: location)
        let raw = String(prefix.reversed().prefix(while: { !$0.isWhitespace }).reversed())
        guard !raw.isEmpty, raw.count <= 128 else { super.keyDown(with: event); return }
        let before = String(prefix.dropLast(raw.count))
        let decision = engine.language.decide(raw, precedingText: before, preferred: preference)
        let range = NSRange(location: location - (raw as NSString).length, length: (raw as NSString).length)
        if decision.changed { insertText(decision.output, replacementRange: range) }
        preference = decision.language
        report?(decision)
        super.keyDown(with: event)
        let other = decision.changed ? raw : raw.replacingOccurrences(of: TokenSyntax.core(raw), with: decision.korean)
        lastWord = (NSRange(location: range.location, length: (decision.output as NSString).length), decision.output, other, selectedRange().location)
    }
}
