import Foundation

/**
 How long the person has been on the current screen - the clock behind the
 `time_on_screen` in-app trigger (Joryio BACKLOG D444 follow-up; the app
 equivalent of the web SDK's `time_on_page`). Wire contract:
 packages/backend/src/common/in-app-screen-triggers.ts.

 - The screen is the one last reported with `trackScreen(name)` (a
   `Screen Viewed` event). A NEW name starts the clock over; the same name
   again (a view re-rendering) does not.
 - Only foreground time counts: `pause()` when the app leaves the
   foreground, `resume()` when it returns - resumed, not restarted.
 - Before the first `trackScreen` the screen is unnamed: a trigger without a
   `screenName` (any screen) still counts that time.
 - Each campaign fires once per screen visit (`markFired`), as the web fires
   once per page.

 Android mirrors this in ScreenClock.kt; `sdk-screen-triggers-parity.spec.ts`
 pins both to the same wire values.
 */
final class ScreenClock {
    /// The trigger type and the capability every app SDK sends on /sync.
    static let triggerType = "time_on_screen"
    static let capability = "screen_context"
    /// Seconds a trigger may ask for (the backend refuses more at save).
    static let maxSeconds: Double = 3600

    private let lock = NSLock()
    private let now: () -> Date
    private var _name: String?
    private var accumulated: TimeInterval = 0
    private var visibleSince: Date?
    private var fired = Set<String>()
    private var observers: [(Change) -> Void] = []

    /// What moved the clock - for the placements' "Show when" (PlacementManager).
    enum Change { case screen, paused, resumed }

    init(now: @escaping () -> Date = Date.init, visible: Bool = true) {
        self.now = now
        visibleSince = visible ? now() : nil
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// The current screen's name, nil before the first trackScreen.
    var name: String? { locked { _name } }

    var isVisible: Bool { locked { visibleSince != nil } }

    /// Foreground seconds on the current screen so far.
    var seconds: TimeInterval {
        locked { accumulated + (visibleSince.map { now().timeIntervalSince($0) } ?? 0) }
    }

    /// The app reported a screen. True when it is a different screen (the clock restarted).
    @discardableResult
    func enter(_ screenName: String) -> Bool {
        let next = screenName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return false }
        let changed: Bool = locked {
            if let current = _name, current.lowercased() == next.lowercased() { return false }
            _name = next
            accumulated = 0
            if visibleSince != nil { visibleSince = now() }
            fired.removeAll()
            return true
        }
        if changed { notify(.screen) }
        return changed
    }

    func pause() {
        let was: Bool = locked {
            guard let since = visibleSince else { return false }
            accumulated += now().timeIntervalSince(since)
            visibleSince = nil
            return true
        }
        if was { notify(.paused) }
    }

    func resume() {
        let started: Bool = locked {
            guard visibleSince == nil else { return false }
            visibleSince = now()
            return true
        }
        if started { notify(.resumed) }
    }

    /// Called after every new screen, pause and resume (outside the clock's lock).
    func observe(_ observer: @escaping (Change) -> Void) {
        locked { observers.append(observer) }
    }

    private func notify(_ change: Change) {
        let all = locked { observers }
        all.forEach { $0(change) }
    }

    func hasFired(_ campaignId: String) -> Bool { locked { fired.contains(campaignId) } }

    func markFired(_ campaignId: String) { _ = locked { fired.insert(campaignId) } }

    /**
     Does the screen the app is on satisfy a trigger's `screenName`? No name =
     any screen. Trimmed, case-insensitive equality - no patterns. Mirrors
     `screenNameMatches` in the backend's in-app-screen-triggers.ts.
     */
    static func screenNameMatches(_ expected: String?, _ current: String?) -> Bool {
        let want = (expected ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if want.isEmpty { return true }
        guard let current else { return false }
        return current.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == want.lowercased()
    }

    /// A `time_on_screen` trigger's seconds, or nil when it is not one or its value is unusable.
    static func thresholdSeconds(_ trigger: InAppTrigger) -> Double? {
        guard trigger.type == triggerType else { return nil }
        let raw = trigger.value?.value
        let n: Double?
        switch raw {
        case let d as Double: n = d
        case let i as Int: n = Double(i)
        case let s as String: n = Double(s)
        default: n = nil
        }
        guard let n, n.isFinite, n > 0, n <= maxSeconds else { return nil }
        return n
    }
}
