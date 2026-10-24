import Foundation

/// One replace-in-place operational snapshot, never input text/key codes/ranges.
/// Written off the IMK thread so a stalled client call remains observable.
final class InputHealth {
    static let shared = InputHealth()
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CapsFlow/ime-health.json")
    private let lock = NSLock()
    private var state: [String: Any] = ["pid": getpid(), "phase": "starting", "client": "unknown"]
    private let queue = DispatchQueue(label: "local.capsflow.ime-health", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var dirty = false
    private init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in self?.flush() }
        self.timer = timer; timer.resume()
    }
    func phase(_ name: String, count counter: String? = nil) {
        lock.lock()
        state["phase"] = name
        if let counter { state[counter] = (state[counter] as? Int ?? 0) + 1 }
        dirty = true
        lock.unlock()
    }
    func client(_ identifier: String?) {
        lock.lock()
        state["client"] = identifier == "com.openai.codex" ? "codex" : (identifier == nil ? "unknown" : "other")
        dirty = true
        lock.unlock()
    }
    private func flush() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let snapshot = state; dirty = false
        lock.unlock()
        do {
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys, .prettyPrinted])
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: Self.url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
        } catch { /* Diagnostics must never block typing. */ }
    }
}
