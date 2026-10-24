import Cocoa
import ApplicationServices
import ServiceManagement
import InputCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let language = LanguageEngine()
    lazy var engine = EventEngine(language: language)
    var window: NSWindow!
    var demo: DemoTextView!
    private var statusItem: NSStatusItem!
    private var stateLabel = NSTextField(labelWithString: "")
    private var detailLabel = NSTextField(wrappingLabelWithString: "아래에서 입력을 시험해보세요.")
    private var modeControl: NSSegmentedControl!
    private var capsBehaviorControl: NSPopUpButton!
    private var switchHint = NSTextField(labelWithString: "")
    private var startButton: NSButton!
    private var loginButton: NSButton!
    private var permissionTimer: Timer?
    private var wantsRunning = true
    private var lastStartAttempt = Date.distantPast
    private let lookupLabel = NSTextField(labelWithString: "")
    private var menuApp: NSRunningApplication?
    private let smokeTest: Bool
    private let suggestionPanel = SuggestionPanel()

    init(smokeTest: Bool = false) { self.smokeTest = smokeTest; super.init() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        CapsKeyMapper.recover(onlyIfDead: true)
        engine.onUpdate = { [weak self] in self?.refresh() }
        engine.onDecision = { [weak self] decision in self?.show(decision) }
        engine.onSuggestion = { [weak self] suggestion in
            if let suggestion { self?.suggestionPanel.show(suggestion) }
            else { self?.suggestionPanel.hide() }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        buildWindow()
        refresh()
        if smokeTest { runSmokeTest(); return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.engine.running && !AXIsProcessTrusted() { self.engine.stop() }
            self.engine.checkConnection()
            if self.wantsRunning && !self.engine.running && AXIsProcessTrusted(), Date().timeIntervalSince(self.lastStartAttempt) > 5 {
                self.lastStartAttempt = Date(); _ = self.engine.start()
            }
            self.refresh()
        }
        if AXIsProcessTrusted() { _ = engine.start() }
    }
    func applicationWillTerminate(_ notification: Notification) { suggestionPanel.hide(); engine.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openWindow(); return true }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
        return field
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 10
        stack.alignment = .centerY; return stack
    }
    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 850), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "CapsFlow · 한 / EN / 자동"; window.center(); window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 760)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
        stack.addArrangedSubview(label("CapsFlow", size: 30, weight: .bold))
        switchHint.font = .systemFont(ofSize: 16, weight: .medium)
        stack.addArrangedSubview(switchHint)
        stateLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stateLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(stateLabel)
        startButton = NSButton(title: "전역 입력 켜기", target: self, action: #selector(toggleRunning))
        startButton.bezelStyle = .rounded
        let access = NSButton(title: "접근성 권한 허용…", target: self, action: #selector(requestAccess)); access.bezelStyle = .rounded
        let monitor = NSButton(title: "입력 모니터링 설정…", target: self, action: #selector(openMonitoring)); monitor.bezelStyle = .rounded
        stack.addArrangedSubview(row([startButton, access, monitor]))
        stack.addArrangedSubview(label("전역 입력에는 macOS 접근성 권한이 필요합니다. 권한 없이도 아래 테스트창은 작동합니다.", size: 12, color: .secondaryLabelColor))
        modeControl = NSSegmentedControl(labels: InputMode.allCases.map(\.title), trackingMode: .selectOne, target: self, action: #selector(changeMode))
        modeControl.segmentStyle = .rounded; modeControl.controlSize = .large
        for index in 0..<3 { modeControl.setWidth(150, forSegment: index) }
        stack.addArrangedSubview(modeControl)
        capsBehaviorControl = NSPopUpButton(frame: .zero, pullsDown: false)
        capsBehaviorControl.addItems(withTitles: CapsLockBehavior.allCases.map(\.title))
        capsBehaviorControl.target = self; capsBehaviorControl.action = #selector(changeCapsBehavior)
        capsBehaviorControl.setAccessibilityIdentifier("caps-lock-behavior")
        stack.addArrangedSubview(row([label("Caps Lock 동작", size: 13, weight: .medium), capsBehaviorControl]))
        stack.addArrangedSubview(label("Speed는 Caps Lock 순환에서만 자동을 건너뜁니다. 위 모드 버튼으로 자동을 직접 선택할 수 있습니다.", size: 12, color: .secondaryLabelColor))
        let instructions = label("자동 모드: 한국어 기본 조합 · 명확한 영어만 공백·구두점에서 영어로 확정\n오른쪽 ⌥ / ⌘⌥Z: 조합 중 한·영 선택 · ⌘⌥Z: 선택 문장 자판 변환 / 직전 단어 뒤집기", size: 13, color: .secondaryLabelColor)
        stack.addArrangedSubview(instructions)
        let preview = NSButton(title: "추천 미리보기", target: self, action: #selector(previewSuggestion))
        preview.bezelStyle = .rounded
        lookupLabel.font = .systemFont(ofSize: 10)
        lookupLabel.textColor = .secondaryLabelColor
        lookupLabel.lineBreakMode = .byTruncatingMiddle
        lookupLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(row([label("키보드 테스트", size: 15, weight: .semibold), preview, lookupLabel]))
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        demo = DemoTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 230))
        demo.engine = engine
        demo.report = { [weak self] decision in self?.show(decision) }
        demo.isRichText = false; demo.font = .systemFont(ofSize: 17)
        demo.isAutomaticSpellingCorrectionEnabled = false; demo.isAutomaticTextReplacementEnabled = false
        demo.isAutomaticQuoteSubstitutionEnabled = false; demo.isAutomaticDashSubstitutionEnabled = false
        demo.textContainerInset = NSSize(width: 14, height: 14)
        demo.isVerticallyResizable = true; demo.isHorizontallyResizable = false
        demo.autoresizingMask = [.width]; demo.textContainer?.widthTracksTextView = true
        demo.setAccessibilityIdentifier("capsflow-demo")
        scroll.documentView = demo
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(label("예: dkssud → 안녕   ·   zzzzzz → ㅋㅋㅋㅋㅋㅋ   ·   한국어 문단 뒤 go → 해", size: 12, color: .secondaryLabelColor))
        detailLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(detailLabel)
        loginButton = NSButton(checkboxWithTitle: "로그인 시 CapsFlow 실행", target: self, action: #selector(toggleLogin))
        loginButton.state = SMAppService.mainApp.status == .enabled ? .on : .off
        stack.addArrangedSubview(loginButton)
        stack.addArrangedSubview(label("로컬 처리 · 입력 기록 저장 없음 · 네트워크 전송 없음\n자동은 CapsFlow 한국어 우선 입력기, 한글은 macOS 두벌식, EN은 ABC를 사용합니다. 타속은 간격 통계만 메모리에 유지합니다.", size: 11, color: .tertiaryLabelColor))
        for view in stack.arrangedSubviews where view is NSTextField {
            view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }
    }
    private func refresh() {
        guard window != nil else { return }
        lookupLabel.stringValue = engine.lastLookupFailure
        stateLabel.stringValue = engine.running ? engine.status : (AXIsProcessTrusted() ? engine.status : "● 접근성 권한 대기 · 테스트창 사용 가능")
        stateLabel.textColor = engine.running ? .systemGreen : .systemOrange
        modeControl.selectedSegment = engine.mode.rawValue
        capsBehaviorControl.selectItem(withTitle: engine.capsLockBehavior.title)
        switchHint.stringValue = engine.capsLockBehavior.hint
        startButton.title = engine.running ? "전역 입력 일시 정지" : "전역 입력 켜기"
        statusItem.button?.title = (engine.running ? "" : "○ ") + engine.mode.badge
        statusItem.button?.font = .systemFont(ofSize: 13, weight: .semibold)
        statusItem.button?.toolTip = "CapsFlow · " + engine.mode.title + " · " + engine.capsLockBehavior.title
    }
    private func show(_ decision: Decision) {
        let raw = Int((decision.rawKoreanScore * 100).rounded()), score = Int((decision.koreanScore * 100).rounded())
        detailLabel.stringValue = "\(decision.reason)\n한글 판정 점수 \(raw) → \(score) / 100\(decision.usedContext ? " · 앞 문맥 \(decision.contextCharacters)자 참조" : "") · 확률이 아닌 휴리스틱 점수"
    }
    @objc private func changeMode() { engine.setMode(InputMode(rawValue: modeControl.selectedSegment)!); refresh() }
    @objc private func changeCapsBehavior() {
        guard let title = capsBehaviorControl.selectedItem?.title,
              let value = CapsLockBehavior.allCases.first(where: { $0.title == title }) else { return }
        engine.setCapsLockBehavior(value)
    }
    @objc private func useCycleBehavior() { engine.setCapsLockBehavior(.cycle) }
    @objc private func useSpeedBehavior() { engine.setCapsLockBehavior(.speed) }
    @objc private func previewSuggestion() {
        let anchor = window.convertToScreen(demo.convert(NSRect(x: 15, y: 15, width: 1, height: 22), to: nil))
        suggestionPanel.show(SuggestionPresentation(text: "심지어", anchor: anchor), preview: true)
    }
    @objc private func toggleRunning() {
        if engine.running { wantsRunning = false; engine.stop() }
        else { wantsRunning = true; if AXIsProcessTrusted() { _ = engine.start() } else { requestAccess() } }
    }
    @objc private func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openMonitoring() {
        _ = CGRequestListenEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc private func toggleLogin() {
        do {
            if loginButton.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let alert = NSAlert(); alert.messageText = "로그인 항목을 변경하지 못했습니다."; alert.informativeText = error.localizedDescription; alert.runModal()
            loginButton.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }
    @objc private func openWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func selectKorean() { engine.setMode(.korean) }
    @objc private func selectEnglish() { engine.setMode(.english) }
    @objc private func selectAuto() { engine.setMode(.automatic) }
    @objc private func excludeApp() { if let menuApp { engine.toggleExclusion(for: menuApp) } }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, checked: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.state = checked ? .on : .off; menu.addItem(item)
        }
        add("한글", #selector(selectKorean), checked: engine.mode == .korean)
        add("English", #selector(selectEnglish), checked: engine.mode == .english)
        add("한/영 자동", #selector(selectAuto), checked: engine.mode == .automatic)
        menu.addItem(.separator())
        add("Caps Lock · " + CapsLockBehavior.cycle.title, #selector(useCycleBehavior), checked: engine.capsLockBehavior == .cycle)
        add("Caps Lock · " + CapsLockBehavior.speed.title, #selector(useSpeedBehavior), checked: engine.capsLockBehavior == .speed)
        menu.addItem(.separator())
        add(engine.running ? "일시 정지 / Caps Lock 복구" : "전역 입력 켜기", #selector(toggleRunning))
        menuApp = NSWorkspace.shared.frontmostApplication
        if let app = menuApp, app.processIdentifier != getpid() {
            add("\(app.localizedName ?? "현재 앱")에서 자동 변환 제외", #selector(excludeApp), checked: engine.isExcluded(app))
        }
        add("설정 및 키보드 테스트…", #selector(openWindow))
        menu.addItem(.separator()); add("CapsFlow 종료", #selector(quit))
    }

    private func runSmokeTest() {
        demo.legacySmokeTesting = true
        let originalSource = InputSources.currentID
        let originalMode = UserDefaults.standard.object(forKey: "mode")
        engine.setMode(.automatic, selectSource: false)
        let originals: [(String, String, String)] = [
            ("", "dkssud", "안녕"), ("", "zzzzzz", "ㅋㅋㅋㅋㅋㅋ"), ("", "gggg", "ㅎㅎㅎㅎ"),
            ("오늘 할 일을 정리하고 있어.\n\n", "go", "해"),
            ("We should finish this paragraph in English.\n\n", "go", "go"),
            ("", "hello", "hello"), ("", "user@example.com", "user@example.com")
        ]
        var cases = originals.map { (context: $0.0, raw: $0.1, expected: $0.2, delimiter: " ", key: UInt16(49), suffix: "") }
        for (delimiter, key) in [(".", UInt16(47)), (",", 43), ("?", 44), ("!", 18), (";", 41), (":", 41)] {
            cases.append(("", "dkssud", "안녕", delimiter, key, ""))
            cases.append(("문맥 ", "3qjsdl", "3번이", delimiter, key, "뒤쪽 기존단어"))
        }
        cases.append(("", "3qjsdl", "3번이", " ", 49, "suffix"))
        cases.append(("앞 문장 ", "dkssud", "안녕", " ", 49, "뒤쪽 문장"))
        cases.append(("", "3.14", "3.14", " ", 49, ""))
        cases.append(("", "3qjsdl2", "3qjsdl2", " ", 49, ""))
        for (opening, closing) in [("(", ")"), ("[", "]"), ("{", "}"), ("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"), ("「", "」"), ("『", "』"), ("【", "】")] {
            cases.append((opening, "dkssud", "안녕", closing, 0, "기존단어"))
            cases.append((opening, "3qjsdl", "3번이", closing, 0, ""))
        }
        for raw in ["r", "g", "k", "R", "3r", "don't", "we're", "I'm", "we’re"] {
            cases.append(("", raw, raw, " ", 49, ""))
        }
        var failures: [String] = []
        for (context, raw, expected, delimiter, key, suffix) in cases {
            demo.string = context + raw + suffix
            demo.setSelectedRange(NSRange(location: (context + raw).utf16.count, length: 0))
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: delimiter, charactersIgnoringModifiers: delimiter, isARepeat: false, keyCode: key)!
            demo.keyDown(with: event)
            if demo.string != context + expected + delimiter + suffix || demo.selectedRange().location != (context + expected + delimiter).utf16.count {
                failures.append("\(raw)\(delimiter): \(demo.string.debugDescription)")
            }
        }
        var total = cases.count
        for raw in ["dkssud. wlrma answkddmf qkRnrh dlTdjdy!", "(dkssud)\n3qjsdl? rkskek.", "r API https://example.com `hello world`", "r 😀\n\nr"] {
            guard let expected = SelectionConversion.korean(raw) else { failures.append("missing selection result"); total += 1; continue }
            let left = "앞 문장 😀 ", right = " 뒤쪽 문장"
            demo.string = left + raw + right
            demo.setSelectedRange(NSRange(location: left.utf16.count, length: raw.utf16.count))
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
            demo.keyDown(with: event); total += 1
            if demo.string != left + expected + right || demo.selectedRange() != NSRange(location: left.utf16.count, length: expected.utf16.count) {
                failures.append("selection replacement / surrounding text")
            }
            demo.keyDown(with: event); total += 1
            if demo.string != left + raw + right { failures.append("selection original restoration") }
        }
        print("AppKit smoke test: \(total - failures.count)/\(total) passed")
        for failure in failures { print(failure) }
        engine.stop()
        InputSources.selectID(originalSource)
        if let originalMode { UserDefaults.standard.set(originalMode, forKey: "mode") }
        else { UserDefaults.standard.removeObject(forKey: "mode") }
        exit(failures.isEmpty ? 0 : 1)
    }
}
