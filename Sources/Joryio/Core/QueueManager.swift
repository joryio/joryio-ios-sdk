import Foundation
import UIKit

/// Holds a background-task identifier by reference so it can be safely mutated
/// from both the expiration handler and the flush completion without triggering
/// exclusive-access issues on a captured `var`.
private final class BackgroundTaskToken {
    var id: UIBackgroundTaskIdentifier = .invalid
}

/// Sends one batch of pre-encoded events. NetworkClient in production; a fake
/// in tests, so the queue's handling of every server answer can be exercised
/// without a server.
protocol EventBatchSender: AnyObject {
    /// `userId`: the one user every event of the batch belongs to (a batch
    /// never mixes users), nil when anonymous.
    func sendEventBatch(_ eventsJSON: [String], userId: String?) async -> NetworkClient.BatchOutcome
}

extension NetworkClient: EventBatchSender {}

/// Manages event queue, batching, and flushing.
///
/// SQLite I/O runs off the main thread: `flush()` is non-isolated (so awaiting
/// it from the @MainActor timer hops onto the cooperative pool), and
/// StorageManager serializes every DB op on its own queue. The single-flight
/// guard is protected by `flushLock` since flush() can be entered from
/// multiple threads (timer, enqueue-triggered, background/terminate).
///
/// ## What happens to a batch (SDK contract 3, identical on every platform)
///
/// - 2xx `success: true`: delete it.
/// - 2xx `success: false`: keep the events in `failedIndices` (all of them when
///   the list is absent), delete the rest, back off.
/// - 400 / 413 / 422: the server will never accept it as it is. Split it in
///   half and send the halves; a single event still refused is dropped, with a
///   log line. It used to stay at the head of the queue and be re-sent forever,
///   so ONE malformed event stopped every later event from being delivered.
/// - 401 with SDK authentication: the refresh flow ran; keep the events.
/// - 402 / 403: stop sending for this session, keep the events, say so once.
/// - 429 / 5xx / offline / timeout: keep everything, exponential backoff that
///   honours Retry-After.
///
/// A failure never deletes events, however many times it repeats. The only
/// thing that drops undelivered events is the `maxQueueSize` cap, oldest first.
class QueueManager {
    /// The backend's `@ArrayMaxSize(500)` on /v1/track/batch. A configured
    /// batch size above it produced requests the server refused outright.
    static let serverMaxBatchSize = 500
    /// Keep one request under the server's body limit with headroom.
    static let maxRequestBytes = 900_000
    /// Longest wait between attempts while the server is failing.
    static let maxBackoffSeconds: TimeInterval = 300
    /// The shortest periodic flush. A `flushInterval` of 0 or less made the
    /// timer fire continuously (SDK contract 35). Same floor on every SDK
    /// (1 second / 1000 ms).
    static let minFlushInterval: TimeInterval = 1

    private let storage: StorageManager
    private let sender: EventBatchSender
    private let logger: Logger
    private let batchSize: Int
    private let flushInterval: TimeInterval
    private let maxQueueSize: Int
    private let sendImmediately: Bool

    /// Whether events may LEAVE the device right now. Set by the SDK: false
    /// while tracking consent is pending (events wait locally) and while opted
    /// out. Collecting is decided before an event ever reaches the queue.
    var canSend: () -> Bool = { true }

    /// The user currently identified on this device. A batch never mixes
    /// users, and the events of a user who has logged out are dropped when
    /// SDK authentication refuses them, whatever the reason - `missing`,
    /// `sub_mismatch`, `expired`, `invalid`: their token is gone and will not
    /// come back (SDK contract 30, v4 39).
    var currentUserId: () -> String? = { nil }

    /// After every flush that ran: the SDK forgets retired tokens whose
    /// user has nothing queued any more (owner decision D-a).
    var afterFlush: () -> Void = {}

    private var flushTimer: Timer?
    private let flushLock = NSLock()
    private var isFlushingQueue = false

    // Backoff + suspension state, under `flushLock`.
    private var consecutiveFailures = 0
    /// The SDK's OWN backoff. A forced flush skips it.
    private var nextAttemptAt: Date?
    /// The SERVER's Retry-After. Nothing skips it - a forced flush included
    /// (SDK contract 35); it used to be folded into the SDK's own backoff,
    /// which consent being granted or a manual flush then cleared.
    private var retryAfterUntil: Date?
    private var suspendedStatus: Int?

    init(
        storage: StorageManager,
        sender: EventBatchSender,
        logger: Logger,
        batchSize: Int,
        flushInterval: TimeInterval,
        maxQueueSize: Int,
        sendImmediately: Bool,
        startTimer: Bool = true
    ) {
        self.storage = storage
        self.sender = sender
        self.logger = logger
        self.batchSize = min(max(1, batchSize), Self.serverMaxBatchSize)
        self.flushInterval = flushInterval.isFinite
            ? max(flushInterval, Self.minFlushInterval)
            : ConfigDefaults.flushInterval
        self.maxQueueSize = max(1, maxQueueSize)
        self.sendImmediately = sendImmediately

        if !(flushInterval >= Self.minFlushInterval) {
            logger.warn("flushInterval \(flushInterval)s is below the minimum; using \(self.flushInterval)s")
        }
        if batchSize > Self.serverMaxBatchSize {
            logger.warn("batchSize \(batchSize) exceeds the server's limit; sending at most \(Self.serverMaxBatchSize) events per request")
        }

        if startTimer {
            startFlushTimer()
        }
    }

    deinit {
        stopFlushTimer()
    }

    // MARK: - Queue Management

    func enqueue(_ event: Event) {
        do {
            try storage.enqueueEvent(event)
            logger.debug("Event queued: \(event.type)")

            // The cap, oldest first. Exactly the overflow - this used to drop a
            // whole batchSize of events to make room for one.
            let dropped = try storage.trimQueue(toMax: maxQueueSize)
            if dropped > 0 {
                logger.warn("Queue exceeded maxQueueSize (\(maxQueueSize)); dropped the \(dropped) oldest event(s)")
            }

            if sendImmediately {
                Task { await flush() }
            } else if storage.getQueueSize() >= batchSize {
                logger.debug("Queue reached the batch threshold (\(batchSize)), flushing")
                Task { await flush() }
            }
        } catch {
            logger.error("Failed to enqueue event: \(error.localizedDescription)")
        }
    }

    // MARK: - Flushing

    /// Non-isolated: DB work + network run off the main thread.
    /// Run `body` holding `flushLock`. A plain function so async callers never
    /// lock an NSLock across a suspension point.
    private func withFlushLock<T>(_ body: () -> T) -> T {
        flushLock.lock()
        defer { flushLock.unlock() }
        return body()
    }

    /// - Parameter force: skip the SDK's own backoff (a manual flush, consent
    ///   just granted). A server `Retry-After` is honoured either way.
    func flush(force: Bool = false) async {
        // Single-flight, and every reason not to send, decided in one place.
        let skipReason: String? = withFlushLock {
            if isFlushingQueue { return "a flush is already in progress" }
            if suspendedStatus != nil { return "sending is suspended for this session" }
            if let until = retryAfterUntil, Date() < until { return "the server asked to wait until \(until)" }
            if !force, let next = nextAttemptAt, Date() < next { return "backing off until \(next)" }
            isFlushingQueue = true
            return nil
        }
        if let skipReason {
            logger.debug("Not flushing: \(skipReason)")
            return
        }

        defer {
            withFlushLock { isFlushingQueue = false }
            afterFlush()
        }

        guard canSend() else {
            logger.debug("Sending is not permitted right now (consent pending or opted out); events stay queued")
            return
        }

        do {
            while true {
                let rows = Self.oneUserOnly(Self.limitByBytes(try storage.dequeueQueuedEvents(limit: batchSize)))
                if rows.isEmpty { break }
                guard canSend() else { break }
                guard await send(rows) else { break }
            }
        } catch {
            logger.error("Failed to flush queue: \(error.localizedDescription)")
        }
    }

    /// Keep a request under `maxRequestBytes`. Always at least one event, so an
    /// oversized single event is still attempted (and refused by the server,
    /// which drops it) instead of being stuck at the head of the queue.
    static func limitByBytes(_ rows: [StorageManager.QueuedEvent]) -> [StorageManager.QueuedEvent] {
        var total = 16 // {"events":[]}
        var result: [StorageManager.QueuedEvent] = []
        for row in rows {
            let size = row.json.utf8.count + 1
            if !result.isEmpty && total + size > maxRequestBytes { break }
            result.append(row)
            total += size
        }
        return result
    }

    /// The `userId` an encoded event carries (nil when anonymous).
    static func userId(of row: StorageManager.QueuedEvent) -> String? {
        ((try? JSONSerialization.jsonObject(with: Data(row.json.utf8))) as? [String: Any])?["userId"] as? String
    }

    /// Cut a batch where the user changes: with SDK authentication every
    /// request is bound to one user's token, so a batch mixing the user who
    /// logged out with the one who logged in could never be accepted.
    static func oneUserOnly(_ rows: [StorageManager.QueuedEvent]) -> [StorageManager.QueuedEvent] {
        guard let first = rows.first else { return rows }
        let user = userId(of: first)
        var result: [StorageManager.QueuedEvent] = [first]
        for row in rows.dropFirst() {
            guard userId(of: row) == user else { break }
            result.append(row)
        }
        return result
    }

    /// Send `rows`, act on the answer. Returns whether the flush may go on to
    /// the next batch.
    private func send(_ rows: [StorageManager.QueuedEvent]) async -> Bool {
        let outcome = await sender.sendEventBatch(rows.map(\.json), userId: rows.first.flatMap(Self.userId(of:)))

        switch outcome {
        case .accepted:
            // A delete that fails would otherwise send the same rows again at
            // once, in a loop (scan 3, M5): stop and back off instead.
            guard delete(rows.map(\.id)) else { return false }
            recordSuccess()
            logger.info("Flushed \(rows.count) events")
            return true

        case .partial(let failedIndices):
            let keep = Set(failedIndices)
            let delivered = rows.enumerated().filter { !keep.contains($0.offset) }.map(\.element.id)
            guard delete(delivered) else { return false }
            if keep.isEmpty {
                // Everything was stored or refused for good (rejectedIndices).
                recordSuccess()
                logger.warn("The server refused some of \(rows.count) events for good (rejectedIndices); those were dropped, the rest stored")
                return true
            }
            // The kept events are first in the queue again; going straight on
            // would re-send them in a tight loop. Back off instead.
            recordFailure(retryAfter: nil)
            logger.warn("Server stored \(delivered.count) of \(rows.count) events; keeping \(keep.count) for retry")
            return false

        case .rejected(let status):
            if rows.count == 1 {
                guard delete([rows[0].id]) else { return false }
                logger.error("Dropping 1 event the server refused (HTTP \(status)); it can never be accepted as it is")
                return true
            }
            // Bisect, so the events that ARE valid still get through.
            let mid = rows.count / 2
            guard await send(Array(rows[..<mid])) else { return false }
            return await send(Array(rows[mid...]))

        case .authFailed(let reason):
            // ANY SDK-authentication reason (v4 39): an `expired` or `invalid`
            // token of a user who has logged out will not be refreshed either.
            if reason != nil,
               let user = rows.first.flatMap(Self.userId(of:)), user != currentUserId() {
                // Events of a user who has logged out: their token is gone.
                // Kept, they would sit at the head of the queue for good and
                // block the next user's events.
                guard delete(rows.map(\.id)) else { return false }
                logger.warn("Dropped \(rows.count) events of a previous user that SDK authentication refused (\(reason?.rawValue ?? "unknown"))")
                return true
            }
            recordFailure(retryAfter: nil)
            logger.warn("Batch rejected by SDK authentication; events kept until a valid token is set")
            return false

        case .suspended(let status):
            let first: Bool = withFlushLock {
                let first = suspendedStatus == nil
                suspendedStatus = status
                return first
            }
            if first {
                logger.error(
                    "The server refused events with HTTP \(status) "
                        + (status == 402 ? "(ingestion suspended for this workspace)" : "(forbidden)")
                        + ". Sending stops for this session; up to \(maxQueueSize) events are kept on the device."
                )
            }
            return false

        case .retryLater(let retryAfter):
            recordFailure(retryAfter: retryAfter)
            return false
        }
    }

    /// True when the rows are gone. On failure the flush stops and backs
    /// off - the rows are still at the head of the queue.
    @discardableResult
    private func delete(_ ids: [Int64]) -> Bool {
        do {
            try storage.deleteEvents(ids: ids)
            return true
        } catch {
            logger.error("Failed to delete sent events: \(error.localizedDescription)")
            recordFailure(retryAfter: nil)
            return false
        }
    }

    private func recordSuccess() {
        withFlushLock {
            consecutiveFailures = 0
            nextAttemptAt = nil
        }
    }

    private func recordFailure(retryAfter: TimeInterval?) {
        let delay: TimeInterval = withFlushLock {
            consecutiveFailures += 1
            let delay = Self.backoffDelay(failures: consecutiveFailures, retryAfter: retryAfter)
            nextAttemptAt = Date().addingTimeInterval(delay)
            if let retryAfter, retryAfter > 0 {
                retryAfterUntil = Date().addingTimeInterval(min(retryAfter, Self.maxBackoffSeconds * 2))
            }
            return delay
        }
        logger.debug("Event delivery failed; next attempt in \(Int(delay))s")
    }

    /// 2, 4, 8 ... seconds, capped, never below what Retry-After asked for.
    static func backoffDelay(failures: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let exponent = Double(min(max(failures, 1), 16))
        let base = min(pow(2.0, exponent), maxBackoffSeconds)
        return min(max(base, retryAfter ?? 0), maxBackoffSeconds * 2)
    }

    /// For diagnostics and tests.
    var isSuspended: Bool {
        withFlushLock { suspendedStatus != nil }
    }

    /// Lift the SDK's own backoff so the next flush goes straight out - used
    /// when the reason sending was held back has just gone away (consent
    /// granted, opt-in). A server Retry-After still stands.
    func resetBackoff() {
        recordSuccess()
    }

    /// For tests.
    var isWaitingForRetryAfter: Bool {
        withFlushLock { retryAfterUntil.map { Date() < $0 } ?? false }
    }

    /// False only in tests, which run without a UIApplication.
    var usesBackgroundTask = true

    func flushSync(force: Bool = false) {
        guard usesBackgroundTask else {
            Task { await self.flush(force: force) }
            return
        }
        // Wrap the flush in a background task so a flush triggered by the app
        // entering background / terminating gets time to finish the network
        // send AND the delete-after-send, instead of being suspended midway.
        Task { @MainActor in
            let application = UIApplication.shared
            let token = BackgroundTaskToken()
            token.id = application.beginBackgroundTask(withName: "JoryioQueueFlush") {
                if token.id != .invalid {
                    application.endBackgroundTask(token.id)
                    token.id = .invalid
                }
            }

            await self.flush(force: force)

            if token.id != .invalid {
                application.endBackgroundTask(token.id)
                token.id = .invalid
            }
        }
    }

    // MARK: - Timer Management

    /// Resume periodic flushing. Safe to call repeatedly - it stops any existing
    /// timer first, so a duplicate foreground notification cannot leave two.
    func resumePeriodicFlush() {
        startFlushTimer()
    }

    /// Stop periodic flushing while the app is backgrounded.
    ///
    /// iOS usually suspends a backgrounded process, which stops the timer for
    /// us - but NOT for apps that declare a background mode (audio, navigation,
    /// VoIP). Those keep running, and there the timer would wake every 5 seconds
    /// indefinitely to look at an empty queue.
    func suspendPeriodicFlush() {
        stopFlushTimer()
    }

    private func startFlushTimer() {
        stopFlushTimer()

        logger.debug("Starting flush timer with interval: \(flushInterval)s")

        let timer = Timer(timeInterval: flushInterval, repeats: true) { [weak self] _ in
            self?.flushSync()
        }
        flushTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = nil
    }

    // MARK: - Queue Info

    func getQueueSize() -> Int {
        return storage.getQueueSize()
    }

    func clearQueue() {
        do {
            try storage.clearQueue()
            logger.info("Event queue cleared")
        } catch {
            logger.error("Failed to clear queue: \(error.localizedDescription)")
        }
    }
}
