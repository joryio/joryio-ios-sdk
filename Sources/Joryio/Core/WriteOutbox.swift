import Foundation

/// One durable write: where it goes and the exact JSON it sends. Persisted,
/// so the field names are a storage format - add fields, never rename.
struct OutboxEntry: Codable, Equatable {
    enum Kind: String, Codable {
        case identify
        case alias
        case subscription
        /// The `tracking_opted_out` profile record (SDK contract 33).
        case optOutMarker
        /// `POST /v1/push/unregister` (SDK contract 22, scan 3 S2).
        case pushUnregister
        /// Attribute writes a previous user left unsent when the app
        /// identified someone else without reset() - sent under THAT
        /// user's ids (SDK contract v5, 53).
        case attributes
    }

    let id: String
    let kind: Kind
    /// Relative to the API base, e.g. `/v1/identify`.
    let path: String
    var body: String
    /// The user the write was made for, so an SDK-authentication 401 for a
    /// user who has since logged out drops it instead of retrying forever.
    var userId: String?
    /// The value an opt-out record carries.
    let markerValue: Bool?
    /// Server answers that did not store it (offline never counts).
    var attempts: Int = 0
    /// 404 "no profile yet" answers (subscriptions).
    var notFoundAttempts: Int = 0
    /// The anonymous id the write was made under. A write made while
    /// anonymous and sent after identify() carries the user id - as long as
    /// this is still the device's anonymous id (contract v4, 38).
    var anonymousId: String?
    /// A withdrawal - an unsubscribe, a group leave: delivered whatever the
    /// opt-out, the consent or a wipeData() (contract v4, 36).
    var withdrawal: Bool?
    /// Writes with the same key are about the same thing (one channel, one
    /// group on a channel): a newer one replaces a queued older one, so an
    /// older retry can never land after it (contract v4, 37).
    var supersedeKey: String?

    init(
        kind: Kind,
        path: String,
        body: String,
        userId: String?,
        markerValue: Bool? = nil,
        anonymousId: String? = nil,
        withdrawal: Bool = false,
        supersedeKey: String? = nil
    ) {
        self.id = UUID().uuidString
        self.kind = kind
        self.path = path
        self.body = body
        self.userId = userId
        self.markerValue = markerValue
        self.anonymousId = anonymousId
        self.withdrawal = withdrawal ? true : nil
        self.supersedeKey = supersedeKey
    }

    /// The write with the ids it is SENT under (see `anonymousId`).
    func sendingAs(userId: String?, body: String) -> OutboxEntry {
        var copy = self
        copy.userId = userId
        copy.body = body
        return copy
    }

    /// Writes that COLLECT something about the person: dropped by opt-out,
    /// consent denied and wipeData(). The opt-out record, a push unregister
    /// and a withdrawal (unsubscribe, group leave) are not collection - they
    /// withdraw, and are always delivered (contract v4, 36).
    var isCollection: Bool {
        switch kind {
        case .identify, .alias, .attributes: return true
        case .subscription: return withdrawal != true
        case .optOutMarker, .pushUnregister: return false
        }
    }
}

/**
 Writes that are not events - identify, addAlias, subscription changes, the
 opt-out record, push unregister - kept until the server acknowledges them
 (SDK contract 28; the same model as Android's WriteOutbox).

 They used to live in an in-memory list that reset() emptied and a restart
 lost: an identify made offline and followed by an app kill never merged the
 anonymous profile, and an unsubscribe lost that way kept mailing someone who
 had said stop. Each write carries its own ids, so a reset() does NOT drop
 it - it is still about the person who made it.

 Sent strictly in order, one at a time: an identify reaches the server before
 the subscription change made after it, and a newer write for the same
 subject replaces a queued older one (contract v4, 37). Nothing blocks the
 rest forever (contract v4, 40 - one counting rule on every SDK):
 - a write the server refuses for good (400 / 403 / 409 / 413 / 422 ...) is
   dropped;
 - a 404 "no profile yet" on a subscription is retried after the queued
   events are flushed, at most `maxNotFoundAttempts` times, then dropped;
 - `success: false` and a current user's SDK-authentication 401 count one
   attempt each, and after `maxAnsweredAttempts` the write is dropped with a
   log line;
 - offline, timeouts, 402, 429 and 5xx never count - a device offline for a
   week, a server down for a day or an account paused for billing keeps the
   write;
 - a 402 (ingestion paused) on a write that is not a withdrawal parks the
   writes that are not withdrawals for a while, and the drain goes on to the
   withdrawals behind them: the server takes those from a paused account,
   so an identify waiting on the pause must not hold an unsubscribe back
   (SDK contract v5, 50).

 Full (`maxEntries`): the oldest write that is NOT a withdrawal goes first;
 a withdrawal goes only when nothing else is left (SDK contract v5, 51).
 */
final class WriteOutbox {
    static let maxEntries = 1000
    static let maxAnsweredAttempts = 10
    static let maxNotFoundAttempts = 5
    static let maxBackoffSeconds: TimeInterval = 300
    /// The longest server Retry-After honoured, the same cap as the event
    /// queue's (scan 4, M7). A misconfigured header must not park every
    /// durable write for days.
    static let maxRetryAfterSeconds: TimeInterval = 600

    /// What reading the persisted outbox gave.
    enum Load {
        /// The stored JSON, or nil when nothing is stored.
        case value(String?)
        /// The store could not be read (the database could not be opened).
        /// Asked again on the next use - and merged, never overwritten.
        case unavailable
    }

    private let logger: Logger
    private let maxEntries: Int
    private let load: () -> Load
    private let save: (String?) -> Void
    private let sender: (String, Data, String?) async -> NetworkClient.WriteOutcome

    /// May this entry leave the device right now? Entries that may not are
    /// skipped (they keep their place) - e.g. collection while consent is
    /// pending, while the opt-out record still goes.
    var permits: (OutboxEntry) -> Bool = { _ in true }
    var currentUserId: () -> String? = { nil }
    /// The entry as it is SENT: ids resolved now, not when it was made
    /// (contract v4, 38). Identity by default.
    var resolve: (OutboxEntry) -> OutboxEntry = { $0 }
    /// Called before a 404'd subscription is retried: the events that
    /// create the profile go first.
    var flushEvents: () async -> Void = {}
    /// Called once per entry when it leaves the outbox: `stored` true when
    /// the server took it, false when it was dropped.
    var onSettled: (OutboxEntry, Bool) -> Void = { _, _ in }
    /// Runs every drain this outbox starts by itself (a kick, a scheduled
    /// retry). Push registration wraps it in its own lock, so a pending
    /// unregister and a registration are never on the wire together.
    var drainGate: ((@escaping () async -> Void) async -> Void)?

    /// Test seams: seconds.
    var baseBackoff: TimeInterval = 2
    var notFoundDelay: TimeInterval = 1

    private let lock = NSLock()
    private var entries: [OutboxEntry] = []
    /// The persisted outbox has been read (or there was none).
    private var restored = false
    private var isDraining = false
    private var drainAgain = false
    private var drainAgainForced = false
    private var failures = 0
    /// The outbox's own backoff - a forced drain skips it.
    private var nextAttemptAt: Date?
    /// The SERVER's Retry-After - nothing skips it (SDK contract 35).
    private var retryAfterUntil: Date?
    private var retryTask: Task<Void, Never>?
    /// A 402 parked the writes that are not withdrawals until then; a forced
    /// drain lifts it (it is the outbox's own wait, not the server's).
    private var collectionParkedUntil: Date?
    /// The SERVER's Retry-After on that 402 - nothing lifts it, a forced
    /// drain included (SDK contract 35, v7 74). It used to be folded into
    /// the park above, which a forced drain clears (scan 7, N2).
    private var collectionRetryAfterUntil: Date?
    private var parkings = 0

    init(
        logger: Logger,
        maxEntries: Int = WriteOutbox.maxEntries,
        load: @escaping () -> Load,
        save: @escaping (String?) -> Void,
        sender: @escaping (String, Data, String?) async -> NetworkClient.WriteOutcome
    ) {
        self.logger = logger
        self.maxEntries = maxEntries
        self.load = load
        self.save = save
        self.sender = sender
        withLock { restoreLocked() }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /**
     Read the persisted outbox, once it can be read. Caller holds the lock.

     Merged, oldest first: entries added while the store could not be read
     (a database that failed to open) go AFTER the stored ones. It used to
     read such a store as empty, and the first new write then saved over
     every stored one (scan 4, M4).
     */
    private func restoreLocked() {
        guard !restored else { return }
        switch load() {
        case .unavailable:
            return
        case .value(let json):
            restored = true
            guard let json, !json.isEmpty else {
                if !entries.isEmpty { persistLocked() }
                return
            }
            guard let stored = try? JSONDecoder().decode([OutboxEntry].self, from: Data(json.utf8)) else {
                logger.warn("Discarding an unreadable write outbox")
                persistLocked()
                return
            }
            let known = Set(stored.map(\.id))
            entries = stored + entries.filter { !known.contains($0.id) }
            _ = evictOverflowLocked()
            persistLocked()
        }
    }

    /// Caller holds the lock. Nothing is saved before the stored outbox was
    /// read: that save would replace it.
    private func persistLocked() {
        guard restored else { return }
        guard !entries.isEmpty else { save(nil); return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        save(String(data: data, encoding: .utf8))
    }

    /**
     Queue a write. A queued write with the same `supersedeKey` is replaced:
     the newer intent is the one that must land (contract v4, 37).

     `alsoReplacing`: the key the same write had while the person was
     anonymous. A queued write under it that names no user is SENT as the
     current user (contract v4, 38), so it is the same person's older intent
     and is replaced too (SDK contract v6, 64). Without this an anonymous
     newsletter signup still held (consent pending, or a 402) landed AFTER
     the unsubscribe the same person made once logged in, and resubscribed
     them.
     */
    func add(_ entry: OutboxEntry, alsoReplacing anonymousKey: String? = nil) {
        let (dropped, superseded): ([OutboxEntry], Int) = withLock {
            restoreLocked()
            var superseded = 0
            if let key = entry.supersedeKey {
                let before = entries.count
                entries.removeAll { $0.supersedeKey == key }
                if let anonymousKey {
                    entries.removeAll { $0.supersedeKey == anonymousKey && $0.userId == nil }
                }
                superseded = before - entries.count
            }
            entries.append(entry)
            let dropped = evictOverflowLocked()
            persistLocked()
            return (dropped, superseded)
        }
        if superseded > 0 {
            logger.debug("A newer \(entry.kind.rawValue) write replaced \(superseded) queued older one(s)")
        }
        for entry in dropped {
            logger.warn("Write outbox full; dropped the oldest (\(entry.kind.rawValue))")
        }
    }

    /// Over the cap: drop the oldest write that is not a withdrawal; a
    /// withdrawal only when the outbox holds nothing else. It used to drop
    /// the oldest whatever it was - an unsubscribe queued while offline
    /// went first, under identify writes piling up on every launch. Caller
    /// holds the lock.
    private func evictOverflowLocked() -> [OutboxEntry] {
        var dropped: [OutboxEntry] = []
        while entries.count > maxEntries {
            if let index = entries.firstIndex(where: { $0.isCollection }) {
                dropped.append(entries.remove(at: index))
            } else {
                dropped.append(entries.removeFirst())
            }
        }
        return dropped
    }

    func removeAll(where predicate: (OutboxEntry) -> Bool) {
        withLock {
            restoreLocked()
            entries.removeAll(where: predicate)
            persistLocked()
        }
    }

    func snapshot() -> [OutboxEntry] { withLock { restoreLocked(); return entries } }

    var count: Int { withLock { restoreLocked(); return entries.count } }

    private func remove(_ id: String) {
        withLock {
            entries.removeAll { $0.id == id }
            persistLocked()
        }
    }

    private func update(_ id: String, _ change: (inout OutboxEntry) -> Void) -> OutboxEntry? {
        withLock {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
            change(&entries[index])
            persistLocked()
            return entries[index]
        }
    }

    /// Start a drain without waiting for it.
    func kick(force: Bool = false) {
        Task { [weak self] in await self?.gatedDrain(force: force) }
    }

    private func gatedDrain(force: Bool) async {
        if let gate = drainGate {
            await gate { [weak self] in await self?.drain(force: force) }
        } else {
            await drain(force: force)
        }
    }

    /**
     Send what is held, in order, while each entry is permitted.

     Single-flight: a call while a drain runs makes that drain run once more
     when it finishes (a write added meanwhile is never left waiting for the
     next trigger).
     */
    func drain(force: Bool = false) async {
        let claimed: Bool = withLock {
            if isDraining {
                drainAgain = true
                drainAgainForced = drainAgainForced || force
                return false
            }
            isDraining = true
            return true
        }
        guard claimed else { return }

        var forced = force
        while true {
            await drainOnce(force: forced)
            let again: Bool? = withLock {
                guard drainAgain else {
                    isDraining = false
                    return nil
                }
                drainAgain = false
                let f = drainAgainForced
                drainAgainForced = false
                return f
            }
            guard let again else { return }
            forced = again
        }
    }

    private func drainOnce(force: Bool) async {
        let now = Date()
        let blockedUntil: Date? = withLock {
            restoreLocked()
            if let until = retryAfterUntil, now < until { return until }
            if !force, let next = nextAttemptAt, now < next { return next }
            return nil
        }
        if let blockedUntil {
            logger.debug("Write outbox waiting until \(blockedUntil)")
            return
        }

        var collectionParked: Bool = withLock {
            if force { collectionParkedUntil = nil }
            if let until = collectionRetryAfterUntil, now < until { return true }
            guard let until = collectionParkedUntil else { return false }
            return now < until
        }

        while let queued = withLock({ entries.first(where: { permits($0) && !(collectionParked && $0.isCollection) }) }) {
            let entry = resolve(queued)
            let outcome = await sender(entry.path, Data(entry.body.utf8), entry.userId)
            switch outcome {
            case .done:
                remove(entry.id)
                withLock {
                    failures = 0
                    nextAttemptAt = nil
                    if entry.isCollection { parkings = 0; collectionParkedUntil = nil; collectionRetryAfterUntil = nil }
                }
                onSettled(entry, true)

            case .refused(let status):
                remove(entry.id)
                logger.error("The server refused a \(entry.kind.rawValue) write (HTTP \(status)); dropped")
                onSettled(entry, false)

            case .notFound:
                guard entry.kind == .subscription else {
                    remove(entry.id)
                    logger.error("The server answered 404 to a \(entry.kind.rawValue) write; dropped")
                    onSettled(entry, false)
                    continue
                }
                let tries = (update(entry.id) { $0.notFoundAttempts += 1 })?.notFoundAttempts ?? Self.maxNotFoundAttempts
                if tries >= Self.maxNotFoundAttempts {
                    remove(entry.id)
                    logger.error("Subscription change dropped: still no profile after \(tries) attempts (404)")
                    onSettled(entry, false)
                    continue
                }
                // No profile yet: the events that create it go first.
                logger.debug("Subscription change answered 404 (no profile yet); flushing events and retrying")
                await flushEvents()
                try? await Task.sleep(nanoseconds: UInt64(max(0, notFoundDelay * Double(tries)) * 1_000_000_000))

            case .authRejected(let reason):
                if reason != nil, let userId = entry.userId, userId != currentUserId() {
                    // Made for a user who has logged out: their token is gone
                    // and will never come back, whatever the reason - missing,
                    // sub_mismatch, expired, invalid (SDK contract 30, v4 39).
                    remove(entry.id)
                    logger.warn("Dropped a \(entry.kind.rawValue) write for a previous user refused by SDK authentication")
                    onSettled(entry, false)
                    continue
                }
                if !recordFailure(entry, retryAfter: nil, answered: true) { continue }
                return

            case .retry(let retryAfter, let answered):
                if !recordFailure(entry, retryAfter: retryAfter, answered: answered) { continue }
                return

            case .suspended(let retryAfter):
                guard entry.isCollection else {
                    // A withdrawal is accepted from a paused account; a 402
                    // for one is a server change, kept without counting.
                    if !recordFailure(entry, retryAfter: retryAfter, answered: false) { continue }
                    return
                }
                parkCollection(retryAfter: retryAfter)
                collectionParked = true
            }
        }

        // Nothing more may go now. Writes parked by a 402 still wait: make
        // sure a drain comes back for them. A withdrawal's retry replaces
        // the park's scheduled drain, and once that withdrawal went through
        // nothing was left to wake the parked writes but the next
        // foreground, write or consent change (scan 6, N1).
        let parkedWait: TimeInterval? = withLock {
            let until = [collectionParkedUntil, collectionRetryAfterUntil].compactMap { $0 }.max()
            guard let until, until > Date(),
                  entries.contains(where: { $0.isCollection && permits($0) })
            else { return nil }
            return until.timeIntervalSinceNow
        }
        if let parkedWait { scheduleRetry(after: parkedWait) }
    }

    /// Count the failure and schedule the retry. Returns false when the entry
    /// was dropped instead (attempt cap, or replaced by a newer write while
    /// it was in flight), so the drain goes on to the next.
    private func recordFailure(_ entry: OutboxEntry, retryAfter: TimeInterval?, answered: Bool) -> Bool {
        if answered {
            let tries = (update(entry.id) { $0.attempts += 1 })?.attempts ?? Self.maxAnsweredAttempts
            if tries >= Self.maxAnsweredAttempts {
                remove(entry.id)
                logger.error("A \(entry.kind.rawValue) write was not stored after \(tries) attempts; dropped so it cannot block later writes")
                onSettled(entry, false)
                return false
            }
        } else if withLock({ !entries.contains { $0.id == entry.id } }) {
            // Replaced while in flight; the newer write goes next.
            return false
        }
        let wait: TimeInterval = withLock {
            failures += 1
            let backoff = min(baseBackoff * pow(2.0, Double(min(failures, 7))), Self.maxBackoffSeconds)
            nextAttemptAt = Date().addingTimeInterval(backoff)
            var serverWait: TimeInterval = 0
            if let retryAfter, retryAfter > 0 {
                serverWait = min(retryAfter, Self.maxRetryAfterSeconds)
                retryAfterUntil = Date().addingTimeInterval(serverWait)
            }
            return max(backoff, serverWait)
        }
        logger.warn("A \(entry.kind.rawValue) write was not stored; kept, retrying in \(Int(wait))s")
        scheduleRetry(after: wait)
        return true
    }

    /// A 402 on a write that is not a withdrawal: park those, keep going
    /// with the withdrawals, and come back later. Never counted.
    private func parkCollection(retryAfter: TimeInterval?) {
        let wait: TimeInterval = withLock {
            parkings += 1
            var wait = min(baseBackoff * pow(2.0, Double(min(parkings, 7))), Self.maxBackoffSeconds)
            if let retryAfter, retryAfter > 0 {
                let serverWait = min(retryAfter, Self.maxRetryAfterSeconds)
                wait = max(wait, serverWait)
                collectionRetryAfterUntil = Date().addingTimeInterval(serverWait)
            }
            collectionParkedUntil = Date().addingTimeInterval(wait)
            return wait
        }
        logger.warn("Ingestion is paused for this workspace (HTTP 402): writes that are not withdrawals wait \(Int(wait))s; withdrawals still go")
        scheduleRetry(after: wait)
    }

    private func scheduleRetry(after seconds: TimeInterval) {
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.gatedDrain(force: false)
        }
        let previous: Task<Void, Never>? = withLock {
            let p = retryTask
            retryTask = task
            return p
        }
        previous?.cancel()
    }

    /// Lift the outbox's own backoff (not a server Retry-After).
    func resetBackoff() {
        withLock { failures = 0; nextAttemptAt = nil; collectionParkedUntil = nil }
    }

    /// Diagnostics for tests: when the server's Retry-After lets the outbox
    /// send again.
    var retryAfterUntilForTesting: Date? { withLock { retryAfterUntil } }
}
