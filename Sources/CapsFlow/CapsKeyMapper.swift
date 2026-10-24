import Cocoa
import IOKit.hidsystem

/// Uses the public IOKit remapping API. Only Caps Lock is changed; all other
/// mappings are preserved. A separate process restores the mapping on crashes.
final class CapsKeyMapper {
    static let caps: UInt64 = 0x700000039
    static let f18: UInt64 = 0x70000006D
    static let src = "HIDKeyboardModifierMappingSrc"
    static let dst = "HIDKeyboardModifierMappingDst"
    static let property = "UserKeyMapping" as CFString
    struct Saved: Codable {
        var session: String
        var pid: Int32
        var services: [String: [[String: UInt64]]]
    }
    static let recoveryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CapsFlow/caps-recovery.json")
    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private var saved: Saved?
    private var watchdog: Process?
    private var timer: Timer?
    private(set) var mappedCount = 0

    static func services(_ client: IOHIDEventSystemClient) -> [IOHIDServiceClient] {
        (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? [])
            .filter { IOHIDServiceClientConformsTo($0, 1, 6) != 0 }
    }
    static func registryID(_ service: IOHIDServiceClient) -> String {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.stringValue ?? "unknown"
    }
    static func mappings(_ service: IOHIDServiceClient) -> [[String: UInt64]] {
        IOHIDServiceClientCopyProperty(service, property) as? [[String: UInt64]] ?? []
    }
    private func persist() throws {
        guard let saved else { return }
        try FileManager.default.createDirectory(at: Self.recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: Self.recoveryURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.recoveryURL.path)
    }
    func start() throws {
        Self.recover(onlyIfDead: true)
        saved = Saved(session: UUID().uuidString, pid: getpid(), services: [:])
        try persist()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--watch-parent", String(getpid()), saved!.session]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        watchdog = child
        refresh()
        if mappedCount == 0 {
            stop()
            throw NSError(domain: "CapsFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Caps Lock 매핑을 적용할 키보드를 찾지 못했습니다."])
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }
    private func refresh() {
        guard saved != nil else { return }
        var count = 0
        for service in Self.services(client) {
            let key = Self.registryID(service)
            let current = Self.mappings(service)
            if saved!.services[key] == nil {
                saved!.services[key] = current.filter { $0[Self.src] == Self.caps }
                do { try persist() } catch { continue }
                var next = current.filter { $0[Self.src] != Self.caps }
                next.append([Self.src: Self.caps, Self.dst: Self.f18])
                guard IOHIDServiceClientSetProperty(service, Self.property, next as CFArray) else { continue }
            }
            if Self.mappings(service).contains(where: { $0[Self.src] == Self.caps && $0[Self.dst] == Self.f18 }) { count += 1 }
        }
        mappedCount = count
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if let saved { Self.recover(session: saved.session) }
        self.saved = nil; mappedCount = 0
        if watchdog?.isRunning == true { watchdog?.terminate() }
        watchdog = nil
    }
    static func recover(session: String? = nil, onlyIfDead: Bool = false) {
        guard let data = try? Data(contentsOf: recoveryURL), let saved = try? JSONDecoder().decode(Saved.self, from: data),
              session == nil || saved.session == session else { return }
        if onlyIfDead && kill(saved.pid, 0) == 0 { return }
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        for service in services(client) {
            guard let old = saved.services[registryID(service)] else { continue }
            let current = mappings(service)
            // Respect another utility/user changing Caps Lock after us.
            guard current.contains(where: { $0[src] == caps && $0[dst] == f18 }) else { continue }
            let next = current.filter { $0[src] != caps } + old
            _ = IOHIDServiceClientSetProperty(service, property, next as CFArray)
        }
        try? FileManager.default.removeItem(at: recoveryURL)
    }
    static func watch(parent: Int32, session: String) {
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        source.setEventHandler { recover(session: session); exit(0) }
        source.resume()
        if kill(parent, 0) != 0 { recover(session: session); return }
        withExtendedLifetime(source) { dispatchMain() }
    }
}
