import Foundation
import InputCore

/// A narrow adapter to IMKTextInput. Tests use an in-memory client, never an
/// accessibility reader, clipboard, event injection, or another app's UI.
protocol CompositionClient: AnyObject {
    var selection: NSRange { get }
    var marked: NSRange { get }
    /// Queried only after destructive editing, never for every ordinary key.
    var documentLength: Int? { get }
    func substring(_ range: NSRange) -> String?
    func mark(_ text: String)
    /// Delete the active composition, not merely commit/end it with empty text.
    func clearMarkedText()
    func insert(_ text: String, replacing range: NSRange)
}

extension CompositionClient {
    var isEffectivelyEmpty: Bool? {
        guard let length = documentLength else { return nil }
        if length == 0 { return true }
        // Some editors keep a paragraph terminator/zero-width placeholder in
        // visually empty fields. Inspect at most 64 UTF-16 units, never scan a
        // large document or infer emptiness just from caret position.
        guard length <= 64 else { return false }
        guard let text = substring(NSRange(location: 0, length: length)), text.utf16.count == length else { return nil }
        return text.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0) || [0x200B, 0xFEFF, 0x2060].contains($0.value)
        }
    }
}

struct InputStroke {
    var key: UInt16
    var text: String
    var time: TimeInterval
    var command = false
    var option = false
    var control = false
    var shift = false
}

final class CompositionSession {
    static let currentSelection = NSRange(location: NSNotFound, length: NSNotFound)
    private(set) var composition = KoreanFirstComposition()
    let language: LanguageEngine
    private var optionDown: TimeInterval?
    private var optionAlone = false
    private var needsEmptyDocumentCheck = false
    private struct Undo { let range: NSRange; let shown: String; let original: String }
    private var undo: Undo?
    private var lastWord: Undo?
    var onChange: (() -> Void)?
    init(language: LanguageEngine) { self.language = language }

    static func validInsertionRange(_ range: NSRange) -> Bool {
        range.location >= 0 && range.location != NSNotFound && range.length >= 0 &&
            range.length != NSNotFound && range.location <= Int.max - range.length
    }

    var candidate: String? {
        guard !composition.isEmpty, !composition.englishOverride else { return nil }
        return composition.decision(using: language).englishCandidate
    }
    func reset() {
        composition.reset(); optionDown = nil; optionAlone = false
        needsEmptyDocumentCheck = false
        undo = nil; lastWord = nil; onChange?()
    }
    private func resetIfDocumentWasCleared(_ client: CompositionClient) {
        guard needsEmptyDocumentCheck, composition.isEmpty else { return }
        needsEmptyDocumentCheck = false
        // Native deletion runs in the host after we return false. Check on the
        // next non-delete key, before deciding its language. A client without
        // document-length support gets a conservative fresh language context.
        if client.isEffectivelyEmpty ?? true { reset() }
    }
    func commit(to client: CompositionClient, delimiter: String = "") {
        guard !composition.isEmpty else {
            if !delimiter.isEmpty { client.insert(delimiter, replacing: Self.currentSelection) }
            return
        }
        let selected = client.selection, marked = client.marked
        guard Self.validInsertionRange(marked) || Self.validInsertionRange(selected) else {
            reset(); return
        }
        let start = marked.location != NSNotFound ? marked.location : selected.location
        let raw = composition.raw
        let result = composition.finish(using: language)
        client.insert(result.output + delimiter, replacing: Self.currentSelection)
        if start != NSNotFound {
            lastWord = Undo(range: NSRange(location: start, length: (result.output + delimiter).utf16.count),
                            shown: result.output + delimiter,
                            original: (result.language == .korean ? raw : result.korean) + delimiter)
        }
        onChange?()
    }
    private func update(_ client: CompositionClient) { client.mark(composition.display); onChange?() }
    @discardableResult func toggle(_ client: CompositionClient) -> Bool {
        resetIfDocumentWasCleared(client)
        if !composition.isEmpty {
            composition.toggleLanguage(); update(client); return true
        }
        let selected = client.selection
        if selected.location != NSNotFound, selected.length > 0 {
            guard selected.length <= SelectionConversion.maximumUTF16,
                  let raw = client.substring(selected), raw.utf16.count == selected.length else { return false }
            let restored = undo.flatMap { $0.range == selected && $0.shown == raw ? $0.original : nil }
            let hasHangul = raw.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x3163).contains($0.value) }
            let converted = hasHangul ? Hangul.keystrokes(for: raw) : SelectionConversion.korean(raw)
            guard let output = restored ?? converted, output != raw else { return false }
            client.insert(output, replacing: selected)
            undo = Undo(range: NSRange(location: selected.location, length: output.utf16.count), shown: output, original: raw)
            lastWord = nil; onChange?(); return true
        }
        // Only a verified immediate suffix can be reversed. Never read or edit
        // surrounding paragraphs, and never fall back to synthetic backspaces.
        if let record = lastWord, selected.length == 0,
           selected.location == NSMaxRange(record.range), client.substring(record.range) == record.shown {
            client.insert(record.original, replacing: record.range)
            lastWord = Undo(range: NSRange(location: record.range.location, length: record.original.utf16.count),
                            shown: record.original, original: record.shown)
            onChange?(); return true
        }
        return false
    }
    func flags(key: UInt16, option: Bool, command: Bool, control: Bool, shift: Bool,
               at time: TimeInterval, client: CompositionClient) -> Bool {
        guard key == 61 else { if optionDown != nil { optionAlone = false }; return false }
        if option {
            optionDown = time; optionAlone = !command && !control && !shift
        } else if let down = optionDown {
            let eligible = optionAlone && time >= down && time - down <= 0.6 && !command && !control && !shift
            optionDown = nil; optionAlone = false
            if eligible { return toggle(client) }
        }
        return false
    }
    func handle(_ stroke: InputStroke, client: CompositionClient) -> Bool {
        if stroke.key != 51 && stroke.key != 117 { resetIfDocumentWasCleared(client) }
        if optionDown != nil { optionAlone = false }
        if stroke.key == 6, stroke.command, stroke.option, !stroke.control { return toggle(client) }
        if stroke.command || stroke.option || stroke.control {
            commit(to: client); lastWord = nil
            if stroke.command && [UInt16(7), 6].contains(stroke.key) {
                // Cut / Undo may leave the document empty, too.
                undo = nil; needsEmptyDocumentCheck = true; onChange?()
            }
            return false
        }
        if stroke.key == 51 {
            lastWord = nil; undo = nil
            guard !composition.isEmpty else {
                needsEmptyDocumentCheck = true; optionDown = nil; optionAlone = false
                onChange?(); return false
            }
            guard Self.validInsertionRange(client.marked) || Self.validInsertionRange(client.selection) else {
                reset(); return false
            }
            composition.backspace()
            // Empty commit and empty composition are not interchangeable in
            // Chromium editors. Explicitly clear the composition in this key
            // event, consuming the Backspace once (never send a second delete).
            if composition.isEmpty {
                client.clearMarkedText()
                // Renderer document metadata may still be asynchronous here.
                // Recheck before the next input, not immediately after cancel.
                needsEmptyDocumentCheck = true; onChange?()
            }
            else { update(client) }
            return true
        }
        if stroke.key == 117 {
            commit(to: client); lastWord = nil; undo = nil
            needsEmptyDocumentCheck = true; onChange?(); return false
        }
        if [UInt16(36), 76, 48, 53, 115, 119, 116, 121, 123, 124, 125, 126].contains(stroke.key) {
            commit(to: client); lastWord = nil; return false
        }
        let text = stroke.text
        guard !text.isEmpty else { return false }
        // Some hosts keep an IMK session while no editable client/range exists.
        // Never consume text and pretend a failed marked-text write succeeded.
        guard Self.validInsertionRange(client.marked) || Self.validInsertionRange(client.selection) else {
            reset(); return false
        }
        if text == " " || stroke.key == 49 {
            guard !composition.isEmpty else { return false }
            commit(to: client, delimiter: " "); return true
        }
        if WordBoundary.isPunctuation(text) {
            if composition.retains(text, using: language),
               composition.append(text == "’" ? "'" : text, at: stroke.time) {
                update(client); return true
            }
            guard !composition.isEmpty else { return false }
            commit(to: client, delimiter: text); return true
        }
        if WordBoundary.isOpening(text) {
            commit(to: client); lastWord = nil; return false
        }
        guard text.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            commit(to: client); lastWord = nil; return false
        }
        // Bounded composition. Overflow finalizes the existing run, then starts
        // a new one; it never swallows the new character.
        if composition.raw.count + text.count > KoreanFirstComposition.maximumKeys { commit(to: client) }
        guard composition.append(text, at: stroke.time) else { return false }
        lastWord = nil; undo = nil; update(client); return true
    }
}
