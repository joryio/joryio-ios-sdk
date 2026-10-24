import Foundation

/**
 One-at-a-time for async work: `run` waits for the previous holder, in
 arrival order. Not reentrant - a body must never `run` on the same lock.

 Used to keep push registration and a pending server unregister apart: the
 two used to race, and an unregister sent while (or after) a registration
 was in flight switched push off for good (scan 4, finding 2). The same
 serial rule as Android's `opMutex`.
 */
final class AsyncSerialLock {
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ body: () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await body()
    }

    private func acquire() async {
        if tryAcquire() { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enqueueOrResume(continuation)
        }
    }

    private func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !held else { return false }
        held = true
        return true
    }

    /// The holder may have released between `tryAcquire` and here.
    private func enqueueOrResume(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if !held {
            held = true
            lock.unlock()
            continuation.resume()
            return
        }
        waiters.append(continuation)
        lock.unlock()
    }

    private func release() {
        lock.lock()
        guard !waiters.isEmpty else {
            held = false
            lock.unlock()
            return
        }
        // Handed straight to the next waiter: `held` stays true.
        let next = waiters.removeFirst()
        lock.unlock()
        next.resume()
    }
}
