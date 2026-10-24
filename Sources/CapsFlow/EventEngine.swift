import Cocoa
import ApplicationServices
import Carbon
import InputCore

private let generatedMarker: Int64 = 0x43415053464C4F57
private let replayMarker: Int64 = 0x434150535245504C

final class EventEngine {
    let language: LanguageEngine
    private(set) var mode: InputMode
    private(set) var capsLockBehavior: CapsLockBehavior
    private(set) var running = false
    private(set) var status = "접근성 권한을 허용하면 전역 입력을 처리합니다."
    private(set) var lastLookupFailure = "최근 조회 실패 없음"
    private(set) var preferred: InputLanguage = .korean
    var onUpdate: (() -> Void)?
    var onDecision: ((Decision) -> Void)?
    var onSuggestion: ((SuggestionPresentation?) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let mapper = CapsKeyMapper()
    private let worker = DispatchQueue(label: "local.capsflow.context", qos: .userInteractive)
    // Preview geometry must not queue ahead of actual Space/Enter conversion.
    private let suggestionWorker = DispatchQueue(label: "local.capsflow.suggestion", qos: .userInitiated)
    private var token = ""
    private var invalidToken = false
    private var generation = 0
    private var pending: Pending?
    private var last: LastWord?
    private var workspaceObserver: NSObjectProtocol?
    private var sourceObserver: NSObjectProtocol?
    private var enabledSourceObserver: NSObjectProtocol?
    private var excluded = Set(UserDefaults.standard.stringArray(forKey: "excludedApps") ?? [])
    private var suggestionRequest: DispatchWorkItem?
    private var suggestionExpiry: DispatchWorkItem?
    private var activeSuggestion: Candidate?
    private var rightOptionTap = RightOptionTap()
    private var continuation: TextContinuation?
    private struct SelectionEdit { let id: Int; let pid: pid_t; var events: [CGEvent] }
    private var selectionEdit: SelectionEdit?
    private struct SelectionUndo {
        let element: AXUIElement
        let pid: pid_t
        let location: Int
        let shown: String
        let original: String
    }
    private var selectionUndo: SelectionUndo?

    private struct Candidate {
        let pid: pid_t
        let original: String
        let replacement: String
        let delimiter: String
        let element: AXUIElement
        let caret: Int
        let continuation: TextContinuation?
    }

    private struct Pending {
        let id: Int
        let pid: pid_t
        let raw: String
        let continuation: TextContinuation?
        let delimiter: String
        var events: [CGEvent]
    }
    private struct LastWord {
        let pid: pid_t
        var shown: String
        var alternative: String
        let delimiter: String
    }

    init(language: LanguageEngine) {
        self.language = language
        self.mode = InputMode(rawValue: UserDefaults.standard.object(forKey: "mode") as? Int ?? 2) ?? .automatic
        self.capsLockBehavior = CapsLockBehavior.restored(UserDefaults.standard.string(forKey: CapsLockBehavior.preferenceKey))
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.cancelPending(toOriginalProcess: true)
            self.reset()
            if self.running { self.prepareFrontmostContext() }
        }
        sourceObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            let id = InputSources.currentID
            let next = InputSources.modeAfterSourceChange(self.mode, identifier: id)
            if next != self.mode { self.setMode(next, selectSource: false) }
        }
        enabledSourceObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil, queue: .main) { _ in
            InputSources.invalidate()
        }
    }

    @discardableResult func start() -> Bool {
        guard !running else { return true }
        guard AXIsProcessTrusted() else { status = "접근성 권한이 필요합니다. 설정에서 CapsFlow를 켜주세요."; onUpdate?(); return false }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { proxy, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                return Unmanaged<EventEngine>.fromOpaque(info).takeUnretainedValue().handle(proxy: proxy, type: type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            status = "키 이벤트 연결에 실패했습니다. 권한을 확인한 뒤 다시 시작해주세요."; onUpdate?(); return false
        }
        tap = newTap
        CGEvent.tapEnable(tap: newTap, enable: true)
        // macOS can return a non-nil tap but silently strip keyDown/keyUp
        // from its mask when Input Monitoring has not been granted. Never
        // swallow physical Caps via IOKit unless keyboard delivery is verified.
        guard hasLiveKeyboardTap() else {
            CFMachPortInvalidate(newTap); tap = nil
            status = "키 누름 연결 안 됨 · 입력 모니터링 권한을 허용하고 CapsFlow를 다시 실행해주세요. Caps Lock은 원래대로 유지합니다."
            onUpdate?(); return false
        }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        do { try mapper.start() }
        catch { stop(); status = error.localizedDescription; onUpdate?(); return false }
        running = true
        setMode(mode)
        status = "Caps Lock 연결됨 · " + capsLockBehavior.title
        onUpdate?()
        return true
    }

    func stop() {
        cancelPending()
        running = false
        if InputSources.matches(.automatic, identifier: InputSources.currentID) {
            // Pausing/quitting the menu app must not silently leave its native
            // converter active. Both built-in sources remain untouched.
            _ = InputSources.select(.korean)
        }
        selectionUndo = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil
        mapper.stop()
        reset()
        status = "일시 정지 · Caps Lock 원래 기능으로 복구됨"
        onUpdate?()
    }

    func setMode(_ value: InputMode, selectSource: Bool = true) {
        cancelPending(); reset()
        let previous = mode
        // Commit before selecting TIS so a synchronous source notification
        // sees the new intent, not the mode we are leaving.
        mode = value
        if selectSource {
            if !InputSources.select(value) {
                mode = previous
                status = "CapsFlow 한국어 우선·ABC·두벌식 입력 소스를 macOS 키보드 설정에서 확인해주세요."
                onUpdate?(); return
            }
        }
        if value != .automatic { preferred = value == .korean ? .korean : .english }
        UserDefaults.standard.set(value.rawValue, forKey: "mode")
        onUpdate?()
        prepareFrontmostContext()
    }
    private func prepareFrontmostContext() {
        // Native IMK owns Auto composition. No AX context reads or prewarming.
    }
    func setCapsLockBehavior(_ value: CapsLockBehavior) {
        capsLockBehavior = value
        UserDefaults.standard.set(value.rawValue, forKey: CapsLockBehavior.preferenceKey)
        if running { status = "Caps Lock 연결됨 · " + value.title }
        // Changing a key route must not silently switch the current IME/mode.
        onUpdate?()
    }
    func cycle() { setMode(capsLockBehavior.next(from: mode)) }
    func reset() { releaseSelectionEdit(toOriginalProcess: true); clearSuggestion(); continuation = nil; token = ""; invalidToken = false; last = nil; generation += 1 }

    private func clearSuggestion() {
        rightOptionTap.reset()
        suggestionRequest?.cancel(); suggestionRequest = nil
        suggestionExpiry?.cancel(); suggestionExpiry = nil
        activeSuggestion = nil
        onSuggestion?(nil)
    }

    private func scheduleSuggestion(raw: String, pid: pid_t, delimiter: String = "", anchor: TextContinuation? = nil) {
        clearSuggestion()
        guard running, mode == .automatic, (1...80).contains(raw.count) else { return }
        let id = generation, preference = preferred, language = language, continuation = anchor ?? continuation
        let request = DispatchWorkItem { [weak self] in
            guard let self, self.generation == id, self.running, self.mode == .automatic,
                  !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            self.suggestionWorker.async { [weak self] in
                // Only reject structurally unsafe tokens here, not words that
                // our automatic classifier decided to preserve as English.
                guard SuggestionPolicy.koreanCandidate(for: language.decide(raw, preferred: preference)) != nil else { return }
                let expected = raw + delimiter
                let lookup = ContextLookup.find(token: expected, continuation: continuation, budget: 0.22,
                                                read: { AccessibilityContext.read(pid: pid) })
                guard let snapshot = lookup.snapshot else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == id else { return }
                        self.recordLookupFailure(lookup, phase: "추천")
                    }
                    return
                }
                let decision = language.decide(raw, precedingText: String(snapshot.before.dropLast(expected.count)), preferred: preference)
                guard let candidate = SuggestionPolicy.fallbackCandidate(for: decision),
                      let bounds = AccessibilityContext.caretBounds(snapshot) else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == id, self.running, self.mode == .automatic,
                          !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                          let anchor = SuggestionPanel.fromAX(bounds) else { return }
                    self.activeSuggestion = Candidate(pid: pid, original: expected, replacement: candidate + delimiter,
                                                      delimiter: delimiter, element: snapshot.element, caret: snapshot.caret,
                                                      continuation: continuation)
                    self.onSuggestion?(SuggestionPresentation(text: candidate, anchor: anchor))
                    let expiry = DispatchWorkItem { [weak self] in
                        guard let self, self.generation == id else { return }
                        self.clearSuggestion()
                    }
                    self.suggestionExpiry = expiry
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: expiry)
                }
            }
        }
        suggestionRequest = request
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: request)
    }

    static let keyboardMask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    static func hasKeyboardEvents(_ mask: CGEventMask) -> Bool { mask & keyboardMask == keyboardMask }
    private func hasLiveKeyboardTap() -> Bool {
        var entries = [CGEventTapInformation](repeating: CGEventTapInformation(), count: 128)
        var count: UInt32 = 0
        guard CGGetEventTapList(UInt32(entries.count), &entries, &count) == .success else { return false }
        return entries.prefix(min(Int(count), entries.count)).contains {
            $0.tappingProcess == getpid() && $0.tapPoint == .cgSessionEventTap &&
            $0.enabled && Self.hasKeyboardEvents($0.eventsOfInterest)
        }
    }
    func checkConnection() {
        guard running else { return }
        if let tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
        guard !hasLiveKeyboardTap() else { return }
        stop()
        status = "키 누름 연결이 끊겨 Caps Lock을 원래대로 복원했습니다. 입력 모니터링 권한을 확인해주세요."
        onUpdate?()
    }

    func toggleExclusion(for app: NSRunningApplication) {
        guard let id = app.bundleIdentifier else { return }
        if excluded.contains(id) { excluded.remove(id) } else { excluded.insert(id) }
        UserDefaults.standard.set(Array(excluded), forKey: "excludedApps")
        cancelPending(); reset(); onUpdate?()
    }
    func isExcluded(_ app: NSRunningApplication) -> Bool { app.bundleIdentifier.map { excluded.contains($0) } ?? false }

    private func handle(proxy: CGEventTapProxy?, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelPending(); reset()
            lastLookupFailure = "키 이벤트 연결 일시 중단 후 복구"
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            onUpdate?()
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == generatedMarker { return Unmanaged.passUnretained(event) }
        guard running else { return Unmanaged.passUnretained(event) }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let isKeyboard = type == .keyDown || type == .keyUp || type == .flagsChanged
        if isKeyboard && key == 79 { // Physical Caps Lock has been remapped to F18.
            if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { cycle() }
            return nil
        }
        // The input method receives the original event, including Option and
        // command shortcuts. Never run AX replacement/event replay alongside it.
        if mode == .automatic { return Unmanaged.passUnretained(event) }
        if !isKeyboard {
            // Drain held input before the click changes the caret/focus.
            cancelPending(proxy: proxy); reset()
            return Unmanaged.passUnretained(event)
        }
        if selectionEdit != nil {
            if let copy = event.copy() { selectionEdit!.events.append(copy) }
            if selectionEdit!.events.count >= 128 { releaseSelectionEdit() }
            return nil
        }
        if pending != nil {
            if let copy = event.copy() { pending!.events.append(copy) }
            if pending!.events.count >= 128 { cancelPending(proxy: proxy); reset() }
            return nil
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(), !isExcluded(app), mode == .automatic else {
            rightOptionTap.reset()
            continuation = nil
            token = ""; return Unmanaged.passUnretained(event)
        }
        let optionTap = rightOptionTap.observe(type: type, key: key, flags: event.flags,
                                              time: TimeInterval(event.timestamp) / 1_000_000_000,
                                              eligible: activeSuggestion != nil && !IsSecureEventInputEnabled())
        if optionTap, let candidate = activeSuggestion {
            applySuggestion(candidate)
            // Deliver the modifier release before generated replacement keys.
            return Unmanaged.passUnretained(event)
        }
        if type != .keyDown { return Unmanaged.passUnretained(event) }
        let modifiers = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl])
        if key == 6 && modifiers == [.maskCommand, .maskAlternate] {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                generation += 1
                reverseLastWord()
            }
            return nil
        }
        generation += 1
        if key == 53 && modifiers.isEmpty && activeSuggestion != nil { clearSuggestion(); return nil }
        guard modifiers.isEmpty else { reset(); return Unmanaged.passUnretained(event) }
        // An external secure-input owner suppresses taps; this check also stops processing
        // the first event when the system returns to normal input.
        if IsSecureEventInputEnabled() { reset(); return Unmanaged.passUnretained(event) }
        if Self.restartsAtCaret(key: key) {
            // Navigation starts a new observed run. AX still checks the left
            // boundary, so moving into an existing identifier is not a bypass.
            reset(); return Unmanaged.passUnretained(event)
        }
        if key == 51 {
            clearSuggestion()
            last = nil
            if !token.isEmpty { token.removeLast() } else { invalidToken = true; continuation = nil }
            if !invalidToken { scheduleSuggestion(raw: token, pid: app.processIdentifier) }
            return Unmanaged.passUnretained(event)
        }
        let text = Self.characters(event)
        if WordBoundary.isOpening(text), !text.unicodeScalars.allSatisfy({ $0.value < 128 }) {
            // Curly/Asian opening punctuation must not mark the following Roman
            // input invalid. ASCII openers already travel with the raw token.
            reset(); return Unmanaged.passUnretained(event)
        }
        if let delimiter = WordBoundary.delimiter(key: key, text: text) {
            clearSuggestion()
            if !token.isEmpty && !invalidToken {
                begin(raw: token, boundary: event, delimiter: delimiter, pid: app.processIdentifier)
                token = ""; invalidToken = false; continuation = nil
                return nil
            }
            token = ""; invalidToken = false; last = nil; continuation = nil
            return Unmanaged.passUnretained(event)
        }
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            reset(); invalidToken = true
            return Unmanaged.passUnretained(event)
        }
        last = nil
        if token.count + text.count <= 128 { token += text } else { token = ""; invalidToken = true }
        if !invalidToken { scheduleSuggestion(raw: token, pid: app.processIdentifier) }
        return Unmanaged.passUnretained(event)
    }

    static func characters(_ event: CGEvent) -> String {
        var data = [UniChar](repeating: 0, count: 16), count = 0
        event.keyboardGetUnicodeString(maxStringLength: data.count, actualStringLength: &count, unicodeString: &data)
        return String(utf16CodeUnits: data, count: count)
    }
    static func restartsAtCaret(key: Int64) -> Bool {
        // Escape, Home/End, Page Up/Down, Forward Delete and arrow keys.
        [53, 115, 119, 116, 121, 117, 123, 124, 125, 126].contains(key)
    }
    private static func post(_ event: CGEvent, replay: Bool = false, pid: pid_t? = nil) {
        event.setIntegerValueField(.eventSourceUserData, value: replay ? replayMarker : generatedMarker)
        if let pid { event.postToPid(pid) } else { event.post(tap: .cgSessionEventTap) }
    }
    private func replaceTyped(_ original: String, with replacement: String, pid: pid_t? = nil) {
        // The original has been verified at the caret by AX. No clipboard is used.
        let source = CGEventSource(stateID: .privateState)
        for _ in original {
            for down in [true, false] {
                if let event = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: down) { event.flags = []; Self.post(event, pid: pid) }
            }
        }
        insertUnicode(replacement, pid: pid)
    }
    private func insertUnicode(_ replacement: String, pid: pid_t? = nil) {
        let source = CGEventSource(stateID: .privateState)
        // Small chunks respect Quartz's UTF-16 payload limit, even with emoji.
        var chunk = ""
        func sendChunk() {
            guard !chunk.isEmpty else { return }
            let units = Array(chunk.utf16)
            for down in [true, false] {
                if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) {
                    event.flags = []
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    Self.post(event, pid: pid)
                }
            }
            chunk = ""
        }
        for character in replacement {
            if chunk.utf16.count + String(character).utf16.count > 16 { sendChunk() }
            chunk.append(character)
        }
        sendChunk()
    }
    private func begin(raw: String, boundary: CGEvent, delimiter: String, pid: pid_t) {
        generation += 1
        let id = generation, preference = preferred, continuation = continuation
        guard let copy = boundary.copy() else { Self.post(boundary); return }
        let notBefore = DispatchTime.now() + WordBoundary.settlingDelay(delimiter)
        pending = Pending(id: id, pid: pid, raw: raw, continuation: continuation,
                          delimiter: delimiter, events: [copy])
        let language = language
        worker.async { [weak self] in
            let lookup = ContextLookup.find(token: raw, continuation: continuation,
                                            read: { AccessibilityContext.read(pid: pid) })
            let decision = lookup.snapshot.map { language.decide(raw, precedingText: String($0.before.dropLast(raw.count)), preferred: preference) }
            DispatchQueue.main.asyncAfter(deadline: notBefore) {
                guard let self, self.pending?.id == id else { return }
                if lookup.snapshot == nil { self.recordLookupFailure(lookup, phase: "확정") }
                self.finish(id: id, decision: decision)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.pending?.id == id else { return }
            self.cancelPending(); self.token = ""; self.invalidToken = false
            self.lastLookupFailure = "확정: 입력란 응답 기한 초과"
            self.status = "입력란 응답 지연 · 이번 단어는 원문 유지"; self.onUpdate?()
        }
    }
    private func recordLookupFailure(_ lookup: ContextLookupResult, phase: String) {
        // Category/count only. No input text, key history, files, or telemetry.
        lastLookupFailure = phase + ": " + (lookup.issue?.rawValue ?? "조회 실패") + " (\(lookup.attempts)회)"
        onUpdate?()
    }
    private func finish(id: Int, decision: Decision?) {
        guard let held = pending, held.id == id else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == held.pid else {
            cancelPending(toOriginalProcess: true); reset(); return
        }
        pending = nil
        let finishingGeneration = generation
        // Only inspect already-held key events; never read a different field or
        // predict from text beyond the caret. Whitespace terminates this look-ahead.
        let followingEvent = held.events.dropFirst().first { $0.type == .keyDown }
        let following = followingEvent.flatMap { event -> String? in
            guard event.flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty else { return nil }
            return Self.characters(event)
        }
        if WordBoundary.retainsStructuredRun(raw: held.raw, delimiter: held.delimiter,
                                             following: following, converted: decision?.changed == true,
                                             ambiguous: decision.map { (0.45...0.55).contains($0.rawKoreanScore) } ?? false) {
            token = held.raw + held.delimiter
            invalidToken = false; continuation = held.continuation; last = nil
            Self.post(held.events[0], pid: held.pid)
            replayHeld(Array(held.events.dropFirst()), pid: held.pid)
            status = "주소·숫자·식별자 형태 유지"; onUpdate?()
            if let decision, !decision.changed, generation == finishingGeneration, pending == nil {
                scheduleSuggestion(raw: held.raw, pid: held.pid, delimiter: held.delimiter, anchor: held.continuation)
            }
            return
        }
        if let decision {
            if decision.changed { replaceTyped(held.raw, with: decision.output, pid: held.pid) }
            preferred = decision.language
            let delimiter = held.delimiter
            let alternative = decision.changed ? held.raw : decoratedKorean(decision)
            last = LastWord(pid: held.pid, shown: decision.output, alternative: alternative, delimiter: delimiter)
            onDecision?(decision)
            status = "전역 입력 처리 중 · " + decision.reason
        } else {
            last = nil
            status = "문맥·커서 위치를 확인할 수 없는 입력란 · 원문 유지"
        }
        Self.post(held.events[0], pid: held.pid)
        replayHeld(Array(held.events.dropFirst()), pid: held.pid)
        onUpdate?()
        if let decision, !decision.changed, generation == finishingGeneration, pending == nil,
           held.delimiter == " " || WordBoundary.isPunctuation(held.delimiter) {
            scheduleSuggestion(raw: held.raw, pid: held.pid, delimiter: held.delimiter, anchor: held.continuation)
        }
    }
    private func decoratedKorean(_ decision: Decision) -> String {
        let core = TokenSyntax.core(decision.original)
        guard let range = decision.original.range(of: core) else { return decision.original }
        var text = decision.original; text.replaceSubrange(range, with: decision.korean); return text
    }
    private func cancelPending(proxy: CGEventTapProxy? = nil, toOriginalProcess: Bool = false) {
        guard let held = pending else { return }
        pending = nil; generation += 1
        for event in held.events {
            if let proxy {
                event.setIntegerValueField(.eventSourceUserData, value: generatedMarker)
                event.tapPostEvent(proxy)
            } else {
                // Cancellation passes raw input through in its original order;
                // it must not create another asynchronous tracking round-trip.
                Self.post(event, pid: held.pid)
            }
        }
    }
    func reverseLastWord() {
        if let candidate = activeSuggestion { applySuggestion(candidate); return }
        guard running, pending == nil, !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(), !isExcluded(app) else { return }
        generation += 1
        let id = generation, pid = app.processIdentifier
        worker.async { [weak self] in
            let selected = AccessibilityContext.selectedText(pid: pid)
            DispatchQueue.main.async {
                guard let self, self.generation == id, self.running, self.pending == nil,
                      !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                guard let selected else {
                    self.status = "선택 영역을 읽을 수 없거나 4,096 UTF-16자 제한을 넘었습니다."; self.onUpdate?(); return
                }
                if selected.range.length == 0 { self.reverseLastWordOnly(); return }
                guard selected.writable else {
                    self.status = "읽기 전용 입력란 · 선택 영역은 바꾸지 않았습니다."; self.onUpdate?(); return
                }
                let undo = self.selectionUndo
                let restored = undo.flatMap { $0.pid == pid && CFEqual($0.element, selected.element) && $0.location == selected.range.location && $0.shown == selected.text ? $0.original : nil }
                guard let replacement = restored ?? SelectionConversion.korean(selected.text), replacement != selected.text else {
                    self.status = "선택 영역에 변환할 영타가 없습니다."; self.onUpdate?(); return
                }
                self.clearSuggestion()
                self.afterModifiersReleased(id: id, deadline: .now() + 1.5) { [weak self] in
                    self?.commitSelection(selected, replacement: replacement, id: id)
                }
            }
        }
    }
    private func reverseLastWordOnly() {
        guard let last, last.shown != last.alternative, pending == nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == last.pid else { return }
        generation += 1
        let id = generation
        worker.async { [weak self] in
            let snapshot = AccessibilityContext.read(pid: last.pid)
            DispatchQueue.main.async {
                guard let self, self.generation == id, self.pending == nil,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == last.pid,
                      snapshot?.before.hasSuffix(last.shown + last.delimiter) == true else { return }
                self.replaceTyped(last.shown + last.delimiter, with: last.alternative + last.delimiter)
                self.last = LastWord(pid: last.pid, shown: last.alternative, alternative: last.shown, delimiter: last.delimiter)
                self.status = "직전 단어의 한·영 판정을 뒤집었습니다."; self.onUpdate?()
            }
        }
    }

    private func commitSelection(_ selected: SelectedTextSnapshot, replacement: String, id: Int) {
        worker.async { [weak self] in
            let fresh = AccessibilityContext.selectedText(pid: selected.pid)
            DispatchQueue.main.async {
                guard let self, self.generation == id, self.running, self.pending == nil,
                      !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == selected.pid,
                      let fresh, selected.matches(fresh) else { return }
                self.token = ""; self.invalidToken = false; self.continuation = nil; self.last = nil
                self.selectionEdit = SelectionEdit(id: id, pid: selected.pid, events: [])
                // Never replace AXValue/the whole field. Either replace exactly
                // AXSelectedText or type Unicode over that revalidated selection.
                if fresh.directWrite {
                    guard AXUIElementSetAttributeValue(fresh.element, kAXSelectedTextAttribute as CFString, replacement as CFString) == .success else {
                        // An error can be an uncertain outcome. Never inject a
                        // second replacement after a potentially applied write.
                        self.releaseSelectionEdit()
                        self.status = "선택 영역 교체 응답을 확인하지 못했습니다. 추가 입력 없이 화면을 확인해주세요."; self.onUpdate?(); return
                    }
                } else { self.insertUnicode(replacement, pid: selected.pid) }
                self.worker.async {
                    var verified = false
                    for _ in 0..<6 {
                        if AccessibilityContext.selectionReplacementVisible(selected, replacement: replacement) { verified = true; break }
                        Thread.sleep(forTimeInterval: 0.016)
                    }
                    DispatchQueue.main.async {
                        guard self.selectionEdit?.id == id else { return }
                        if verified {
                            self.selectionUndo = SelectionUndo(element: selected.element, pid: selected.pid,
                                                               location: selected.range.location, shown: replacement, original: selected.text)
                        }
                        self.status = verified ? "선택 영역을 한 번에 변환했습니다. 같은 부분을 다시 선택해 ⌘⌥Z로 원문 복원 가능" : "선택 영역 변환 입력 전달 · 화면 결과를 확인해주세요."
                        self.releaseSelectionEdit(); self.onUpdate?()
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, self.selectionEdit?.id == id else { return }
                    self.releaseSelectionEdit()
                    self.status = "선택 영역 변환 확인 시간 초과 · 추가 교체 없이 입력을 재개합니다."; self.onUpdate?()
                }
            }
        }
    }

    private func releaseSelectionEdit(toOriginalProcess: Bool = false) {
        guard let edit = selectionEdit else { return }
        selectionEdit = nil
        if toOriginalProcess {
            for event in edit.events { Self.post(event, pid: edit.pid) }
        } else { replayHeld(edit.events, pid: edit.pid) }
    }

    static func needsSessionReplay(type: CGEventType, key: Int64, flags: CGEventFlags) -> Bool {
        !flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty ||
        (type == .flagsChanged && [54, 55, 58, 61, 59, 62].contains(key))
    }

    private func replayHeld(_ events: [CGEvent], pid: pid_t) {
        // Feed held plain typing synchronously through our state machine, then
        // deliver directly to the original app. Re-posting it to the session tap
        // used to let newer hardware input overtake old buffered characters.
        for (index, event) in events.enumerated() {
            if pending != nil {
                pending!.events.append(contentsOf: events[index...])
                if pending!.events.count >= 128 { cancelPending(); reset() }
                return
            }
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            if Self.needsSessionReplay(type: event.type, key: key, flags: event.flags) {
                // Preserve system/global shortcuts. Do not reinterpret a burst
                // across a native input-source/app shortcut as an ordinary word.
                reset()
                for remaining in events[index...] { Self.post(remaining) }
                return
            }
            event.setIntegerValueField(.eventSourceUserData, value: replayMarker)
            if handle(proxy: nil, type: event.type, event: event) != nil { Self.post(event, pid: pid) }
        }
    }

    private func applySuggestion(_ candidate: Candidate) {
        guard running, mode == .automatic, pending == nil, !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == candidate.pid else { clearSuggestion(); return }
        generation += 1
        let id = generation
        clearSuggestion()
        status = "추천 적용 단축키 감지 · 보조키를 모두 떼면 적용합니다."
        onUpdate?()
        afterModifiersReleased(id: id, deadline: .now() + 1.5) { [weak self] in
            self?.replaceSuggestion(candidate, id: id)
        }
    }

    private func afterModifiersReleased(id: Int, deadline: DispatchTime, action: @escaping () -> Void) {
        guard generation == id, running, mode == .automatic else { return }
        let held = CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskAlternate, .maskControl])
        if held.isEmpty { action(); return }
        guard DispatchTime.now() < deadline else {
            status = "추천 적용 취소 · 보조키를 뗀 뒤 다시 시도해주세요."
            onUpdate?(); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            self?.afterModifiersReleased(id: id, deadline: deadline, action: action)
        }
    }

    private func replaceSuggestion(_ candidate: Candidate, id: Int) {
        worker.async { [weak self] in
            let snapshot = AccessibilityContext.read(pid: candidate.pid)
            DispatchQueue.main.async {
                guard let self, self.generation == id, self.pending == nil, self.running, self.mode == .automatic,
                      !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == candidate.pid else { return }
                guard let snapshot else {
                    self.status = "추천 적용 취소 · 입력란의 커서를 다시 확인할 수 없습니다."
                    self.onUpdate?(); return
                }
                guard AccessibilityContext.validatesReplacement(snapshot, element: candidate.element, caret: candidate.caret,
                                                               original: candidate.original, continuation: candidate.continuation) else {
                    self.status = "추천 적용 취소 · 입력란·커서 또는 원문이 변경되었습니다."
                    self.onUpdate?(); return
                }
                self.replaceTyped(candidate.original, with: candidate.replacement)
                self.continuation = TextContinuation.afterReplacing(snapshot, original: candidate.original,
                                                                    replacement: candidate.replacement, delimiter: candidate.delimiter)
                self.token = ""; self.invalidToken = false
                self.last = nil
                self.preferred = .korean
                self.status = "추천한 한글 후보를 적용했습니다."
                self.onUpdate?()
            }
        }
    }
}
