import Cocoa
import Carbon
import InputMethodKit

let args = CommandLine.arguments
let sourceID = "local.inputmethod.capsflow.koreanfirst"
func sources(includeDisabled: Bool) -> [TISInputSource] {
    TISCreateInputSourceList(nil, includeDisabled).takeRetainedValue() as! [TISInputSource]
}
func id(_ source: TISInputSource) -> String {
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}
if args.contains("--self-test") { runInputMethodChecks(); exit(0) }
if args.contains("--health") {
    guard let data = try? Data(contentsOf: InputHealth.url), let value = String(data: data, encoding: .utf8) else {
        print("No native input health snapshot yet."); exit(1)
    }
    print(value); exit(0)
}
if args.contains("--is-enabled") {
    exit(sources(includeDisabled: false).contains { id($0) == sourceID } ? 0 : 1)
}
if let index = args.firstIndex(of: "--register"), args.count > index + 1 {
    let url = URL(fileURLWithPath: args[index + 1], isDirectory: true)
    let status = TISRegisterInputSource(url as CFURL)
    print("TISRegisterInputSource: \(status)")
    guard status == noErr else { exit(1) }
    let found = sources(includeDisabled: true).filter { id($0) == sourceID || id($0) == "local.inputmethod.capsflow" }
    guard !found.isEmpty else { print("Input method not visible yet; log out/in or add it in Keyboard settings."); exit(2) }
    for source in found {
        let enable = TISEnableInputSource(source)
        print("Enable \(id(source)): \(enable)")
        guard enable == noErr else { exit(3) }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    // TIS may expose a just-registered mode only in this process's cache.
    // Verify a fresh process, not only this registrar's apparently enabled ref.
    let verifier = Process()
    verifier.executableURL = Bundle.main.executableURL
    verifier.arguments = ["--is-enabled"]
    do { try verifier.run(); verifier.waitUntilExit() }
    catch { print("Could not verify independent source visibility."); exit(4) }
    guard verifier.terminationStatus == 0 else {
        print("Registration accepted, but not visible to a fresh process. Log out/in, then add the mode in Keyboard settings. No activation confirmed.")
        exit(4)
    }
    print("Selectable mode verified enabled in a fresh process.")
    exit(0)
}
if args.contains("--list-sources") {
    for source in sources(includeDisabled: true) where id(source).contains("capsflow") {
        print(id(source))
        for key in [kTISPropertyInputSourceType, kTISPropertyInputSourceCategory, kTISPropertyInputSourceIsEnabled,
                    kTISPropertyInputSourceIsEnableCapable, kTISPropertyInputSourceIsSelectCapable] {
            if let pointer = TISGetInputSourceProperty(source, key) {
                print("  \(key!): \(Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue())")
            }
        }
    }
    print("Current: \(id(TISCopyCurrentKeyboardInputSource().takeRetainedValue()))"); exit(0)
}
if args.contains("--activate") {
    guard let source = sources(includeDisabled: false).first(where: { id($0) == sourceID }) else { print("CapsFlow input method is not enabled."); exit(1) }
    let result = TISSelectInputSource(source)
    print("Select: \(result), current: \(id(TISCopyCurrentKeyboardInputSource().takeRetainedValue()))")
    exit(result == noErr ? 0 : 1)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // passive candidate panels, never a Dock app
guard NSClassFromString("CapsFlowInputController") != nil,
      let connection = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
      let identifier = Bundle.main.bundleIdentifier,
      let server = IMKServer(name: connection, bundleIdentifier: identifier) else {
    fputs("Invalid CapsFlow input method bundle or server connection.\n", stderr); exit(1)
}
withExtendedLifetime(server) { app.run() }
