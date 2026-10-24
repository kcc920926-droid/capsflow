import Cocoa
import Carbon
import Darwin

// No key events, accessibility access, input selection or TCC modifications.
let imeID = "local.inputmethod.capsflow"
let modeID = imeID + ".koreanfirst"
func sourceID(_ source: TISInputSource) -> String {
    guard let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}
func currentID() -> String { sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) }
func enabled() -> Bool {
    (TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]).contains { sourceID($0) == modeID }
}
func fail(_ message: String, _ code: Int32 = 1) -> Never {
    fputs(message + "\n", stderr); exit(code)
}
func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
// LSBackgroundOnly input methods are not always represented by NSRunningApplication.
// ps is filtered in memory by current UID AND the exact executable path; no other
// process paths/arguments are emitted or signalled.
func userProcesses() -> [(pid_t, String)] {
    let task = Process(), pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-ww", "-axo", "pid=,uid=,comm="]
    task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { fail("프로세스 상태를 확인할 수 없어 교체를 중단합니다.") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
    guard task.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
        fail("프로세스 상태를 확인할 수 없어 교체를 중단합니다.")
    }
    return text.split(separator: "\n").compactMap { line in
        let parts = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 3, let pid = Int32(parts[0]), let uid = UInt32(parts[1]), uid == getuid(), pid != getpid() else { return nil }
        return (pid, String(parts[2]))
    }
}
func pids(at executable: String) -> [pid_t] {
    userProcesses().filter { canonical($0.1) == canonical(executable) }.map { $0.0 }
}
func isMappingWatchdog(_ pid: pid_t) -> Bool {
    let task = Process(), pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-ww", "-p", String(pid), "-o", "args="]
    task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { fail("Caps 복구 감시 프로세스를 구분할 수 없어 종료를 중단합니다.") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "").contains(" --watch-parent ")
}
func executable(_ app: String, _ name: String) -> String { app + "/Contents/MacOS/" + name }
func ensureNotActive() {
    guard !currentID().hasPrefix(imeID) else {
        fail("지금 ‘자동’ 입력기를 사용 중입니다. 입력 내용을 저장하고 ABC 또는 두벌식으로 전환한 뒤 다시 실행하세요. 앱은 교체하지 않았습니다.", 3)
    }
}
func idle(_ app: String) {
    ensureNotActive()
    guard pids(at: executable(app, "CapsFlowInputMethod")).isEmpty else {
        fail("기존 입력기가 다시 실행되어 교체를 중단했습니다. ABC/두벌식 전환과 입력 중인 앱의 상태를 확인하세요.", 3)
    }
}
func stop(_ app: String, identifier: String, name: String) {
    if identifier == imeID { ensureNotActive() }
    let sameID = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter {
        $0.processIdentifier != getpid() && !(name == "CapsFlow" && isMappingWatchdog($0.processIdentifier))
    }
    guard sameID.allSatisfy({ canonical($0.bundleURL?.path ?? "") == canonical(app) }) else {
        fail("다른 폴더의 \(name)이 실행 중입니다. 그 앱을 직접 종료한 뒤 다시 실행하세요.", 3)
    }
    let exe = executable(app, name)
    guard !userProcesses().contains(where: {
        URL(fileURLWithPath: $0.1).lastPathComponent == name && canonical($0.1) != canonical(exe)
    }) else {
        fail("다른 폴더의 \(name)이 실행 중입니다. 그 앱을 직접 종료한 뒤 다시 실행하세요.", 3)
    }
    for running in sameID { _ = running.terminate() }
    for pid in pids(at: exe) {
        // The mapping watchdog must outlive the menu process and finish its own
        // restoration. Never signal it alongside its parent.
        if name == "CapsFlow" && isMappingWatchdog(pid) { continue }
        // Recheck immediately before SIGTERM; never force-kill or signal a reused PID.
        if pids(at: exe).contains(pid) { _ = kill(pid, SIGTERM) }
    }
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        if pids(at: exe).isEmpty { return }
        RunLoop.current.run(until: Date().addingTimeInterval(0.10))
    }
    fail("\(name)이 종료되지 않아 파일을 교체하지 않았습니다. 앱을 직접 종료하고 다시 실행하세요.", 3)
}
let args = CommandLine.arguments
guard args.count >= 2 else { fail("Usage: CapsFlowSetupHelper enabled | check | stop-ime PATH | idle-ime PATH | stop-menu PATH") }
switch args[1] {
case "enabled": exit(enabled() ? 0 : 1)
case "check":
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let report: [String: Any] = ["currentInputSource": currentID(), "inputMethodEnabled": enabled(),
        "inputMethodProcessCount": pids(at: executable(home + "/Library/Input Methods/CapsFlowInputMethod.app", "CapsFlowInputMethod")).count,
        "menuProcessCountIncludingWatchdog": pids(at: executable(home + "/Applications/CapsFlow.app", "CapsFlow")).count]
    print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
case "stop-ime", "idle-ime", "inactive-ime", "stop-menu":
    guard args.count == 3, args[2].hasPrefix("/"), args[2].hasSuffix(".app") else { fail("정확한 앱 경로가 필요합니다.") }
    if args[1] == "inactive-ime" { ensureNotActive() }
    else if args[1] == "stop-ime" { stop(args[2], identifier: imeID, name: "CapsFlowInputMethod") }
    else if args[1] == "idle-ime" { idle(args[2]) }
    else { stop(args[2], identifier: "local.capsflow.app", name: "CapsFlow") }
default: fail("알 수 없는 작업입니다.")
}
