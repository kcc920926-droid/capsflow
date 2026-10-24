// Read-only OS connection check. Does not create an event tap, read input,
// synthesize keys, inspect UI contents, or request permissions.
import Cocoa
import CoreGraphics

let processes = NSRunningApplication.runningApplications(withBundleIdentifier: "local.capsflow.app")
let pids = Set(processes.map(\.processIdentifier))
var entries = [CGEventTapInformation](repeating: CGEventTapInformation(), count: 128)
var count: UInt32 = 0
let result = CGGetEventTapList(UInt32(entries.count), &entries, &count)
let keyboard = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
let taps = entries.prefix(min(Int(count), entries.count)).filter { pids.contains($0.tappingProcess) && $0.tapPoint == .cgSessionEventTap }
let ready = result == .success && taps.contains { $0.enabled && $0.eventsOfInterest & keyboard == keyboard }
let report: [String: Any] = [
    "keyboardReady": ready,
    "processIDs": pids.sorted(),
    "taps": taps.map { ["pid": Int($0.tappingProcess), "enabled": $0.enabled, "eventMask": $0.eventsOfInterest] as [String: Any] }
]
print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
exit(ready ? 0 : 1)
