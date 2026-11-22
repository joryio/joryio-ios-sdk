#if canImport(UIKit)
import UIKit
#if SWIFT_PACKAGE
// SwiftPM: JoryioUI is its own module. CocoaPods: Joryio/UI is a subspec
// compiled INTO the Joryio module, where this import is a warning that
// fails `pod lib lint` (and so `pod trunk push`).
import Joryio
#endif

/**
 The viewability rule of Joryio's inline views (PlacementView, the card feed):
 at least `Placements.PLACEMENT_VIEWABLE_FRACTION` of a view inside its window
 for `InAppDisplay.IN_APP_DISPLAY_DWELL_MS` while the app is active. One
 implementation, so a placement and a card count a view the same way.
 */
enum JoryioViewability {
    /// Share of `v` inside its window; a zero-size view (an empty spot) counts as 1 while it is on screen.
    static func visibleFraction(_ v: UIView) -> Double {
        guard let window = v.window, !v.isHidden, v.alpha > 0.01 else { return 0 }
        let frame = v.convert(v.bounds, to: window)
        if frame.width == 0 || frame.height == 0 {
            return window.bounds.contains(frame.origin) ? 1 : 0
        }
        let visible = frame.intersection(window.bounds)
        if visible.isNull { return 0 }
        return Double(visible.width * visible.height) / Double(frame.width * frame.height)
    }
}

/// Dwell timers: each target's callback runs once, after it has been viewable
/// without a break for the dwell. The owning view calls `tick()` from its timer.
final class ViewabilityTracker {
    private final class Tracker {
        weak var target: UIView?
        let onViewable: () -> Void
        var since: Date?
        var done = false
        init(_ target: UIView, _ onViewable: @escaping () -> Void) {
            self.target = target
            self.onViewable = onViewable
        }
    }

    private var trackers: [Tracker] = []

    func add(_ target: UIView, _ onViewable: @escaping () -> Void) {
        trackers.append(Tracker(target, onViewable))
    }

    func removeAll() { trackers.removeAll() }

    /// The view left the window: every dwell starts again.
    func resetDwell() { trackers.forEach { $0.since = nil } }

    func tick() {
        let active = UIApplication.shared.applicationState == .active
        let now = Date()
        for t in trackers where !t.done {
            guard let target = t.target, active, JoryioViewability.visibleFraction(target) >= Placements.PLACEMENT_VIEWABLE_FRACTION else {
                t.since = nil
                continue
            }
            if let since = t.since {
                if now.timeIntervalSince(since) * 1000 >= Double(InAppDisplay.IN_APP_DISPLAY_DWELL_MS) {
                    t.done = true
                    t.onViewable()
                }
            } else {
                t.since = now
            }
        }
    }
}
#endif
