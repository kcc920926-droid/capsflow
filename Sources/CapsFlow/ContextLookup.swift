import Foundation

struct ContextLookupResult {
    let snapshot: TextSnapshot?
    let issue: TextValidationIssue?
    let attempts: Int
}

/// Runs only on a worker. A stale AX frame is not a permanent failure, but
/// neither elapsed time nor retries ever relax the original safety checks.
enum ContextLookup {
    static func find(token: String, continuation: TextContinuation? = nil, budget: TimeInterval = 0.26,
                     maximumAttempts: Int = 12, read: () -> TextSnapshot?,
                     now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                     pause: () -> Void = { Thread.sleep(forTimeInterval: 0.016) }) -> ContextLookupResult {
        let deadline = now() + budget
        var attempts = 0
        var issue: TextValidationIssue = .unreadable
        while attempts < maximumAttempts {
            if attempts > 0 && now() >= deadline { break }
            attempts += 1
            if let snapshot = read() {
                if let failure = AccessibilityContext.validationIssue(snapshot, token: token, continuation: continuation) {
                    issue = failure
                } else { return ContextLookupResult(snapshot: snapshot, issue: nil, attempts: attempts) }
            } else { issue = .unreadable }
            if attempts < maximumAttempts && now() < deadline { pause() }
        }
        return ContextLookupResult(snapshot: nil, issue: issue, attempts: attempts)
    }
}
