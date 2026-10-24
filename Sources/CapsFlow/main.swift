import Cocoa
import ApplicationServices
import InputCore

let args = CommandLine.arguments
if args.contains("--verify-update-bundle") || args.contains("--verify-remote-update") {
    exit(runUpdateVerification(arguments: args))
}
if args.contains("--native-input-method-ready") {
    let ready = InputSources.enabledIDs.contains(InputSources.automaticID)
    print(ready ? "CapsFlow native input method ready." : "Native input method is not enabled; keep the current utility installed.")
    exit(ready ? 0 : 1)
}
if args.contains("--runtime-checks") { runRuntimeChecks(); exit(0) }
if args.contains("--headless-mapper-check") { exit(CapsKeyMapper.checkHeadlessStartup() ? 0 : 1) }
if args.count >= 4 && args[1] == "--watch-parent", let pid = Int32(args[2]) {
    CapsKeyMapper.watch(parent: pid, session: args[3]); exit(0)
}
if args.contains("--recover-caps") { CapsKeyMapper.recover(onlyIfDead: true); print("Caps Lock recovery checked."); exit(0) }
if args.contains("--quit-running") {
    for running in NSRunningApplication.runningApplications(withBundleIdentifier: "local.capsflow.app") where running.processIdentifier != getpid() {
        _ = running.terminate()
        let deadline = Date().addingTimeInterval(3)
        while !running.isTerminated && Date() < deadline {
            // NSRunningApplication termination state updates through the run loop.
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if !running.isTerminated { fputs("CapsFlow did not quit; close it before installing.\n", stderr); exit(1) }
    }
    exit(0)
}
if args.contains("--test-mapping") || args.contains("--hold-mapping") {
    let mapper = CapsKeyMapper()
    do {
        try mapper.start()
        print("Caps Lock mapped on \(mapper.mappedCount) keyboard service(s); pid=\(getpid())")
        fflush(stdout)
        if args.contains("--hold-mapping") { dispatchMain() }
        mapper.stop()
        print("Caps Lock mappings restored.")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    exit(0)
}
if args.contains("--diagnose") {
    let language = LanguageEngine()
    let report: [String: Any] = [
        "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
        "accessibility": AXIsProcessTrusted(), "inputMonitoring": CGPreflightListenEventAccess(),
        "postEvents": CGPreflightPostEventAccess(), "inputSources": InputSources.enabledIDs,
        "currentInputSource": InputSources.currentID,
        "capsLockBehavior": CapsLockBehavior.restored(UserDefaults.standard.string(forKey: CapsLockBehavior.preferenceKey)).rawValue,
        "longBackspaceEnabled": UserDefaults.standard.object(forKey: BackspaceHold.preferenceKey) as? Bool ?? true,
        "englishWords": language.lexiconCounts.english, "koreanWords": language.lexiconCounts.korean,
        "recoveryFilePresent": FileManager.default.fileExists(atPath: CapsKeyMapper.recoveryURL.path)
    ]
    print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    exit(0)
}
if let index = args.firstIndex(of: "--evaluate"), args.count > index + 1 {
    let context = args.firstIndex(of: "--context").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } ?? ""
    let result = LanguageEngine().decide(args[index + 1], precedingText: context)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(data: try encoder.encode(result), encoding: .utf8)!); exit(0)
}
let smokeTest = args.contains("--ui-smoke-test")
if !smokeTest, let other = NSRunningApplication.runningApplications(withBundleIdentifier: "local.capsflow.app").first(where: { $0.processIdentifier != getpid() }) {
    other.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]); exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(smokeTest: smokeTest)
app.delegate = delegate
// Catch normal termination signals so the IOKit remap is restored immediately.
signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { NSApp.terminate(nil) }; term.resume()
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { NSApp.terminate(nil) }; interrupt.resume()
app.run()
