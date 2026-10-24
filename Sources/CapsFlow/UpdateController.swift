import Cocoa
import UpdateCore

final class UpdateController {
    static let checkKey = "updates.automaticChecks"
    static let downloadKey = "updates.automaticDownloads"
    private let defaults: UserDefaults
    private let publicKey: Data
    private let version: String
    private let build: Int
    private var timer: Timer?
    private var metadata: UpdateDataRequest?
    private var archive: UpdateArchiveRequest?
    private var generation = 0
    private var stopped = false
    private(set) var busy = false
    private(set) var candidate: VerifiedUpdate?
    private(set) var installer: URL?
    private(set) var status = "업데이트 자동 확인 대기"
    var onChange: (() -> Void)?
    var automaticChecks: Bool { defaults.object(forKey: Self.checkKey) as? Bool ?? true }
    var automaticDownloads: Bool { defaults.object(forKey: Self.downloadKey) as? Bool ?? true }
    var available: Bool { candidate != nil }
    var actionTitle: String {
        if busy { return status }
        if installer != nil { return "v\(candidate?.payload.version ?? "") 업데이트 설치…" }
        if let c = candidate { return "v\(c.payload.version) 다운로드…" }
        return "업데이트 확인…"
    }
    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        publicKey = Data(base64Encoded: bundle.object(forInfoDictionaryKey: "CapsFlowUpdatePublicKey") as? String ?? "") ?? Data()
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        build = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    }
    func start() {
        stopped = false
        guard publicKey.count == 32 else { setStatus("서명 키가 포함된 배포 앱에서 업데이트를 사용할 수 있습니다."); return }
        schedule()
    }
    func stop() {
        stopped = true; generation += 1; timer?.invalidate(); timer = nil
        metadata?.cancel(); archive?.cancel(); metadata = nil; archive = nil
    }
    func setChecks(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.checkKey)
        if !enabled {
            generation += 1; metadata?.cancel(); archive?.cancel(); metadata = nil; archive = nil; busy = false
            timer?.invalidate(); timer = nil; setStatus("자동 업데이트 확인 꺼짐")
        } else { setStatus("업데이트 자동 확인 켜짐"); schedule() }
    }
    func setDownloads(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.downloadKey); onChange?()
    }
    private func setStatus(_ text: String) { status = text; onChange?() }
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard automaticChecks, !stopped, publicKey.count == 32 else { return }
        let now = Date(), desired = defaults.object(forKey: "updates.nextCheck") as? Date ?? now
        // Clock changes/corrupt preferences cannot postpone a check indefinitely.
        let delay = max(20, min(86_400, desired.timeIntervalSince(now)))
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.check(manual: false) }
    }
    private func record(success: Bool) {
        let failures = success ? 0 : min(29, max(0, defaults.integer(forKey: "updates.failures"))) + 1
        let interval = success ? UpdatePolicy.interval : UpdatePolicy.retryInterval(failures: failures)
        defaults.set(failures, forKey: "updates.failures")
        defaults.set(Date().addingTimeInterval(interval), forKey: "updates.nextCheck")
        schedule()
    }
    private func message(_ title: String, _ detail: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.addButton(withTitle: "확인"); alert.runModal()
    }
    func performAction() {
        guard !busy else { return }
        if let script = installer, !FileManager.default.isExecutableFile(atPath: script.path) { installer = nil }
        if installer != nil { openInstaller() }
        else if candidate != nil { download(manual: true) }
        else { check(manual: true) }
    }
    func check(manual: Bool) {
        guard !busy, !stopped else { return }
        guard publicKey.count == 32 else { if manual { message("업데이트를 확인할 수 없습니다", "배포 앱의 발행자 공개키가 없습니다.") }; return }
        busy = true; let token = generation
        setStatus("GitHub 업데이트 확인 중…")
        let request = UpdateDataRequest(); metadata = request
        request.start(UpdatePolicy.feedURL) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.generation == token, !self.stopped else { return }
                self.metadata = nil; self.busy = false
                do {
                    let data = try result.get()
                    let os = ProcessInfo.processInfo.operatingSystemVersion
                    let update = try UpdatePolicy.verify(data, publicKey: self.publicKey, currentVersion: self.version,
                        currentBuild: self.build, architecture: UpdatePolicy.architecture,
                        operatingSystem: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
                    self.record(success: true)
                    if let update {
                        if self.candidate?.payload != update.payload { self.installer = nil }
                        self.candidate = update; self.setStatus("새 버전 v\(update.payload.version)")
                        if let script = self.installer, FileManager.default.isExecutableFile(atPath: script.path) {
                            self.setStatus("v\(update.payload.version) 설치 준비 완료")
                            if manual { self.message("업데이트 준비 완료", "메뉴에서 업데이트 설치를 선택할 수 있습니다.") }
                        } else if self.automaticDownloads { self.download(manual: manual) }
                        else if manual {
                            let alert = NSAlert(); alert.messageText = "CapsFlow v\(update.payload.version)"
                            alert.informativeText = "서명된 새 버전이 있습니다. 다운로드 후에도 설치 전 입력 저장 확인이 필요합니다."
                            alert.addButton(withTitle: "다운로드"); alert.addButton(withTitle: "나중에")
                            if alert.runModal() == .alertFirstButtonReturn { self.download(manual: true) }
                        }
                    } else {
                        self.candidate = nil; self.installer = nil
                        self.setStatus("현재 v\(self.version) · 새 업데이트 없음")
                        if manual { self.message("새 업데이트가 없습니다", "현재 버전 v\(self.version)을 사용 중입니다.") }
                    }
                } catch {
                    self.record(success: false); self.setStatus("업데이트 확인 실패 · 간격을 늘려 재시도")
                    if manual { self.message("업데이트를 확인하지 못했습니다", error.localizedDescription) }
                }
            }
        }
    }
    private func download(manual: Bool) {
        guard !busy, let update = candidate, !stopped else { return }
        do {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.capsflow/Updates", isDirectory: true)
            let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            busy = true; setStatus("v\(update.payload.version) 다운로드·검증 중…")
            let token = generation, request = UpdateArchiveRequest(update: update, directory: directory)
            archive = request
            request.start { [weak self] result in
                DispatchQueue.global(qos: .utility).async {
                    let prepared = result.flatMap { url in Result { try UpdateArchivePreparation.prepare(url, update: update) } }
                    DispatchQueue.main.async {
                        guard let self, self.generation == token, !self.stopped else { return }
                        self.archive = nil; self.busy = false
                        switch prepared {
                        case .success(let script):
                            self.installer = script; self.record(success: true); self.setStatus("v\(update.payload.version) 설치 준비 완료")
                            if manual { self.message("업데이트 준비 완료", "입력 내용을 저장하고 ABC 또는 두벌식으로 전환한 뒤 메뉴의 업데이트 설치를 선택하세요. 설치 전 확인과 macOS 권한 승인은 유지됩니다.") }
                        case .failure(let error):
                            self.record(success: false); self.setStatus("업데이트 파일 검증/준비 실패 · 기존 앱 유지")
                            if manual { self.message("업데이트를 준비하지 못했습니다", error.localizedDescription) }
                        }
                    }
                }
            }
        } catch {
            busy = false; record(success: false); setStatus("업데이트 저장 폴더를 준비하지 못했습니다")
            if manual { message("업데이트 실패", error.localizedDescription) }
        }
    }
    private func openInstaller() {
        guard let script = installer else { return }
        guard !InputSources.currentID.hasPrefix("local.inputmethod.capsflow") else {
            message("입력 내용을 먼저 저장하세요", "‘자동’ 입력기를 사용 중입니다. 다른 앱의 조합 중인 글자까지 확정·저장하고 ABC 또는 두벌식으로 전환한 뒤 다시 선택하세요."); return
        }
        let alert = NSAlert(); alert.messageText = "다운로드한 업데이트 설치 파일을 열까요?"
        alert.informativeText = "발행자 서명·ZIP 해시·앱 서명을 확인했습니다. 터미널의 간편 설치기가 입력 저장 여부를 다시 확인하며, macOS 권한 재승인이 필요할 수 있습니다."
        alert.addButton(withTitle: "설치 파일 열기"); alert.addButton(withTitle: "나중에")
        guard alert.runModal() == .alertFirstButtonReturn,
              !InputSources.currentID.hasPrefix("local.inputmethod.capsflow") else { return }
        if !NSWorkspace.shared.open(script) { message("설치 파일을 열지 못했습니다", "GitHub 릴리스에서 직접 설치 ZIP을 받을 수 있습니다.") }
    }
    func showSettings() {
        let alert = NSAlert(); alert.messageText = "GitHub 자동 업데이트"
        alert.informativeText = "6시간마다 서명된 버전 정보를 확인합니다. 실패 시 30분부터 최대 하루까지 재시도 간격을 늘립니다. 입력 내용·앱 문맥·타속은 전송하지 않습니다.\n\n\(status)"
        let check = NSButton(checkboxWithTitle: "새 버전 자동 확인", target: nil, action: nil)
        let download = NSButton(checkboxWithTitle: "검증된 새 버전 자동 다운로드 (설치는 직접 확인)", target: nil, action: nil)
        check.state = automaticChecks ? .on : .off; download.state = automaticDownloads ? .on : .off
        let feed = NSTextField(wrappingLabelWithString: UpdatePolicy.feedURL.absoluteString)
        feed.font = .systemFont(ofSize: 10); feed.isSelectable = true
        let stack = NSStackView(views: [check, download, feed]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.frame = NSRect(x: 0, y: 0, width: 570, height: 105); alert.accessoryView = stack
        alert.addButton(withTitle: "지금 확인"); alert.addButton(withTitle: "닫기")
        let answer = alert.runModal()
        if automaticChecks != (check.state == .on) { setChecks(check.state == .on) }
        setDownloads(download.state == .on)
        if answer == .alertFirstButtonReturn { self.check(manual: true) }
    }
}
