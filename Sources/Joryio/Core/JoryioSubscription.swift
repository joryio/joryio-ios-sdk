import Foundation

/**
 Returned by every `on...Updated` listener - `onCardsUpdated`,
 `onPlacementsUpdated` and `onFlagsUpdated`: `cancel()` stops the updates.
 Cancelling twice is harmless.

 One type with the same name and the same `cancel()` on every Joryio SDK
 (web, Android, React Native; Unity `JoryioSubscription.Cancel()`), pinned by
 the backend's SDK parity spec.
 */
public final class JoryioSubscription {
    private let onCancel: () -> Void
    private let lock = NSLock()
    private var cancelled = false

    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }

    /// Stop the updates to this listener.
    public func cancel() {
        lock.lock()
        let first = !cancelled
        cancelled = true
        lock.unlock()
        if first { onCancel() }
    }
}
