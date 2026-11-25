import Foundation

/**
 Feature flags + remote config (Joryio BACKLOG D446). The iOS twin of the web
 SDK's `core/flags.ts` - the same names, the same wire values.

 - `getFlag(_:default:)` and the typed getters read the answer held on the
   device; they never wait for the network. Before the first answer, for a
   flag the server did not send, or for a value of another type, they return
   the in-code default.
 - Nothing is fetched until the app uses flags (a getter, `getAllFlags`,
   `refreshFlags` or `onFlagsUpdated` on this device), so an app that never
   reads a flag costs no request. From then on the answer
   (`POST /v1/flags/evaluate`, every active flag in one call) is kept on disk
   for the same person only, and refreshed at start, on foreground (at most
   once per `JoryioFlags.FLAGS_MIN_REFRESH_SECONDS`), on identify / reset and
   on a consent change, on the silent push `jry_sync: "flags"`, and on
   `refreshFlags()`. The `etag` is sent back, so an unchanged answer is not
   sent again (`notModified`).
 - An exposure (`flag.exposure`) is logged the first time a value is read in
   a session: once per person, flag and variant per session, unless the
   answer said `logExposure: false`. `getAllFlags()` logs none. Exposures go
   in one `POST /v1/flags/exposures` a second after the first read; each
   batch carries the identity it was read under, so an identify / reset never
   sends one person's exposures as the next, and a batch is dropped when
   consent is withdrawn before it goes. Each batch carries an `idempotencyKey`
   (a UUID): a copy sent again is recorded once by the server.
 - The "already sent" marks of the current session are kept on disk
   (`jry_<sdkKey>_flag_exposures`, at most `FLAG_EXPOSURE_MARKS_MAX`), so a
   relaunch that resumes the same session sends no exposure again (BACKLOG
   D479). A mark is stored when its batch is SENT, not when it is read: an
   app killed before the batch goes sends that exposure after the relaunch. A new session starts with none; reset(), identify() of a different
   user and wipeData() clear them. The server counts an exposure once per
   person, flag, variant and session either way.
- A mark is stored only once the server took its batch
  (`exposureBatchSettled`: a 2xx, or a 4xx other than 408 / 429). A batch that
  got no answer, a 5xx, a 408 or a 429 is handed, with the SAME body and
  `idempotencyKey`, to the SDK's persisted exposures outbox - the write
  outbox's sibling under its own key `flag_exposures_outbox` (kind
  `flagExposures`), so an earlier SDK after a rollback still decodes its
  write outbox - which retries it on its backoff, across relaunches, and
  discards it on wipeData(), an opt-out or a denied consent; its marks are
  stored when the outbox settles it. While it waits there it counts as
  already exposed (its marks are read from the outbox), so a read does not
  queue it twice.
 - Without tracking consent nothing is sent and the getters return the
   in-code default.
 */
public enum JoryioFlags {
    /// A refresh asked for within this many seconds of the last one is skipped (start, identify, push and refreshFlags() always go).
    public static let FLAGS_MIN_REFRESH_SECONDS: TimeInterval = 60
    /// Exposures are sent in one request this long after the first read.
    public static let FLAG_EXPOSURE_FLUSH_SECONDS: TimeInterval = 1
    /// The silent-push `jry_sync` value that refreshes flags now.
    public static let FLAG_SYNC_PUSH_VALUE = "flags"
    /// Exposures per request (the server's limit).
    static let FLAG_EXPOSURES_PER_CALL_MAX = 100
    /// "Already sent" exposure marks kept for the current session; the oldest goes first past this.
    public static let FLAG_EXPOSURE_MARKS_MAX = 500
}

/// One exposures request's answer: the HTTP status (0 = no answer) and the server's Retry-After.
struct FlagsPostStatus: Equatable {
    let status: Int
    var retryAfter: TimeInterval?
}

/// Whether an exposures batch is finished with after an answer of `status`
/// (0 = no answer): a 2xx, or a 4xx other than 408 / 429 - a refusal a retry
/// would not change, as the write outbox drops one. A network failure, a 5xx,
/// a 408 or a 429 keeps the batch for a retry. The same rule, under the same
/// name, on Android and the web.
func exposureBatchSettled(_ status: Int) -> Bool {
    switch status {
    case 200...299: return true
    case 408, 429: return false
    case 400...499: return true
    default: return false
    }
}

/// The marks of an exposures request body: `<session>|<user>|<anonymous>|<flag>|<variant>`,
/// from the identity the batch carries. The same on Android and the web.
func exposureMarks(_ body: String) -> [String] {
    guard let data = body.data(using: .utf8),
          let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let list = o["exposures"] as? [[String: Any]] else { return [] }
    let head = "\(o["sessionId"] as? String ?? "")|\(o["userId"] as? String ?? "")|\(o["anonymousId"] as? String ?? "")"
    return list.compactMap { e in
        guard let key = e["key"] as? String else { return nil }
        return "\(head)|\(key)|\(e["variant"] as? String ?? "")"
    }
}

final class FlagsManager {
    /// The network: POST a JSON body, answer the decoded JSON object or nil.
    typealias Post = (_ path: String, _ body: Data) async -> [String: Any]?
    /// POST an exposures batch: the HTTP status (0 = no answer) and Retry-After.
    typealias PostExposures = (_ body: Data) async -> FlagsPostStatus

    struct Dependencies {
        var post: Post
        /// true when the SDK may send (initialized, consent granted, not opted out).
        var canSend: () -> Bool
        var userId: () -> String?
        var anonymousId: () -> String
        var sessionId: () -> String
        var attributes: () -> [String: Any]
        var context: () -> [String: Any]
        var load: () -> String?
        var save: (String?) -> Void
        /// Where onFlagsUpdated callbacks run (the main queue in the SDK).
        var callbackQueue: DispatchQueue = .main
        var now: () -> Date = Date.init
        var exposureFlushDelay: TimeInterval = JoryioFlags.FLAG_EXPOSURE_FLUSH_SECONDS
        /// The current session's exposure marks on disk (JSON `{"sessionId", "marks"}`).
        var loadExposures: () -> String? = { nil }
        var saveExposures: (String?) -> Void = { _ in }
        /// Nil: `post`, a 200 when it answered and 0 when it did not.
        var postExposures: PostExposures?
        /// Hand a batch the server did not take to the persisted write outbox
        /// (same body, same key), with that answer's Retry-After: its first
        /// outbox attempt waits the first backoff step, or the Retry-After
        /// when longer.
        var enqueueExposures: (String, TimeInterval?) -> Void = { _, _ in }
        /// The bodies of the exposure batches waiting in the write outbox.
        var pendingExposures: () -> [String] = { [] }
    }

    private struct PendingBatch {
        let body: [String: Any]
        let generation: Int
        /// `wipes` when the batch was made: one read before wipeData() is never handed to the outbox.
        let wipe: Int
        var exposures: [[String: String]]
        /// The exposure marks of this batch, stored once it is sent (D479).
        var marks: [String] = []
        /// The batch's `idempotencyKey` (1.4.0-beta.12): one UUID per request, so a
        /// copy of the request sent again is recorded once by the server.
        var idempotencyKey = UUID().uuidString.lowercased()
    }

    /// `batch` as requests of at most FLAG_EXPOSURES_PER_CALL_MAX exposures,
    /// each with its own idempotencyKey (the first keeps the batch's) and its
    /// own marks: each is settled, kept and retried on its own. The same on
    /// Android and the web.
    private static func splitExposureBatch(_ batch: PendingBatch) -> [PendingBatch] {
        let max = JoryioFlags.FLAG_EXPOSURES_PER_CALL_MAX
        return stride(from: 0, to: batch.exposures.count, by: max).map { i in
            let end = min(i + max, batch.exposures.count)
            var chunk = batch
            chunk.exposures = Array(batch.exposures[i..<end])
            chunk.marks = Array(batch.marks[i..<end])
            if i > 0 { chunk.idempotencyKey = UUID().uuidString.lowercased() }
            return chunk
        }
    }

    private let deps: Dependencies
    private let lock = NSLock()
    /// key -> the flag as the server sent it (`value`, `variant`, `valueType`, `reason`, `version`, `logExposure`).
    private var flags: [String: [String: Any]] = [:]
    private var etag = ""
    private var fetchedAt: Date?
    private var generation = 0
    private var used = false
    private var inflight: Task<Void, Never>?
    private var inflightGeneration = 0
    private var listeners: [UUID: ([String]) -> Void] = [:]
    /// `<session>|<person>|<flag>|<variant>` already reported in `exposedSession`,
    /// kept on disk (D479) so a relaunch in the same session does not report it again.
    private var exposed = Set<String>()
    /// The same marks, oldest first (the cap drops from the front).
    private var exposedOrder: [String] = []
    /// The session the marks belong to; nil until the stored marks are read.
    private var exposedSession: String?
    /// The marks of batches already SENT this session - what is kept on disk, oldest first.
    private var storedMarks: [String] = []
    private var pending: PendingBatch?
    private var flushScheduled = false
    /// Bumped by wipe(): a batch read before it is never handed to the outbox.
    private var wipes = 0

    /// The cached answer is per workspace: the key carries the SDK key, like
    /// every other key StorageManager keeps (`jry_<sdkKey>_...`), because the
    /// kv table is one database per app - an app that switches SDK keys (two
    /// workspaces) must never read the other's flags for the same external id.
    static func storageKey(sdkKey: String) -> String { "jry_\(sdkKey)_flags_cache" }
    /// The unscoped key of builds before 2026-11-21: never read, removed at start.
    static let legacyStorageKey = "flags_cache"
    /// The current session's "already sent" exposure marks, per workspace like the answer.
    static func exposuresStorageKey(sdkKey: String) -> String { "jry_\(sdkKey)_flag_exposures" }

    init(_ deps: Dependencies) {
        self.deps = deps
        load()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Lifecycle

    /// Start: the stored answer is readable at once; refresh it now.
    func start() {
        if withLock({ used }) { Task { await refresh(force: true) } }
    }

    /// Foreground: refresh, at most once per FLAGS_MIN_REFRESH_SECONDS.
    func onForeground() {
        Task { await refresh(force: false) }
    }

    /// The person or the consent changed: the held answer belongs to someone else.
    /// `clearExposureMarks`: reset() or identify() of a different user - the
    /// exposure marks go too (the beta.11 rule for attributes).
    func onIdentityChanged(clearExposureMarks: Bool = false) {
        if clearExposureMarks { self.clearExposureMarks() }
        let before: [String] = withLock {
            generation += 1
            return Array(flags.keys)
        }
        // The batch carries its own snapshot, so it still goes as the previous
        // person - or is dropped when consent was withdrawn.
        flush()
        withLock {
            flags = [:]
            etag = ""
            fetchedAt = nil
        }
        save()
        if !before.isEmpty { emit(before) }
        if withLock({ used }) { Task { await refresh(force: true) } }
    }

    /// wipeData(): forget the answer and the reports, keep the listeners.
    func wipe() {
        withLock {
            // No exposure read before the wipe is sent: the queued batch goes,
            // and one on the wire is not handed to the outbox (whose own
            // entries the wipe discards with its other writes).
            wipes += 1
            generation += 1
            pending = nil
            flags = [:]
            etag = ""
            fetchedAt = nil
        }
        deps.save(nil)
        clearExposureMarks()
    }

    /// Forget the exposure marks, in memory and on disk.
    private func clearExposureMarks() {
        withLock {
            // Batches already made still go, as the person who read them;
            // their marks are not stored (storeMarks keeps the current person's only).
            exposed.removeAll()
            exposedOrder.removeAll()
            storedMarks.removeAll()
            exposedSession = ""
        }
        deps.saveExposures(nil)
    }

    /// Under the lock: the marks belong to `session`. The stored marks are read
    /// once (kept only when they are this session's); another session's are dropped.
    private func adoptExposureSession(_ session: String) {
        if exposedSession == nil {
            exposedSession = ""
            if let raw = deps.loadExposures(), let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (obj["sessionId"] as? String) == session, let marks = obj["marks"] as? [String] {
                exposedOrder = Array(marks.suffix(JoryioFlags.FLAG_EXPOSURE_MARKS_MAX))
                storedMarks = exposedOrder
                exposed = Set(exposedOrder)
                exposedSession = session
            }
        }
        if exposedSession != session {
            exposed.removeAll()
            exposedOrder.removeAll()
            storedMarks.removeAll()
            exposedSession = session
        }
    }

    // MARK: - Reading

    func getFlag(_ key: String, default defaultValue: Any?) -> Any? {
        guard let f = read(key, type: nil) else { return defaultValue }
        return Self.plain(f["value"])
    }

    func getBoolFlag(_ key: String, default defaultValue: Bool) -> Bool {
        guard let f = read(key, type: "boolean"), let n = f["value"] as? NSNumber, Self.isBool(n) else { return defaultValue }
        return n.boolValue
    }

    func getStringFlag(_ key: String, default defaultValue: String) -> String {
        guard let f = read(key, type: "string"), let s = f["value"] as? String else { return defaultValue }
        return s
    }

    func getNumberFlag(_ key: String, default defaultValue: Double) -> Double {
        guard let f = read(key, type: "number"), let n = f["value"] as? NSNumber, !Self.isBool(n) else { return defaultValue }
        return n.doubleValue
    }

    func getJsonFlag(_ key: String, default defaultValue: Any?) -> Any? {
        guard let f = read(key, type: "json") else { return defaultValue }
        return Self.plain(f["value"])
    }

    /// A JSON flag decoded into `T`; the default when it does not decode.
    func getJsonFlag<T: Decodable>(_ key: String, as type: T.Type, default defaultValue: T) -> T {
        guard let f = read(key, type: "json"), let value = f["value"],
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else { return defaultValue }
        return decoded
    }

    /// Every flag held, key -> value. Reading them all logs no exposure.
    func getAllFlags() -> [String: Any] {
        guard deps.canSend() else { return [:] }
        use()
        return withLock { flags.compactMapValues { Self.plain($0["value"]) ?? NSNull() } }
    }

    /// Ask the server now (always goes, unlike the automatic refreshes).
    func refreshFlags() async {
        withLock { used = true }
        await refresh(force: true)
    }

    func onFlagsUpdated(_ callback: @escaping ([String]) -> Void) -> JoryioSubscription {
        let id = UUID()
        withLock { listeners[id] = callback }
        use()
        return JoryioSubscription { [weak self] in
            guard let self else { return }
            self.withLock { _ = self.listeners.removeValue(forKey: id) }
        }
    }

    // MARK: - Internals

    /// The first use on a device that had no stored answer fetches one (the getter itself returns at once).
    private func use() {
        let first: Bool = withLock {
            if used { return false }
            used = true
            return true
        }
        if first { Task { await refresh(force: true) } }
    }

    private func read(_ key: String, type: String?) -> [String: Any]? {
        guard deps.canSend() else { return nil }
        use()
        guard let f = withLock({ flags[key] }) else { return nil }
        if let type, (f["valueType"] as? String) != type { return nil }
        noteExposure(key, f)
        return f
    }

    private func noteExposure(_ key: String, _ f: [String: Any]) {
        // `logExposure: false` = sampled out on the server; absent = log.
        if let log = f["logExposure"] as? Bool, !log { return }
        let variant = (f["variant"] as? String) ?? ""
        let session = deps.sessionId()
        let mark = "\(session)|\(subjectKey())|\(key)|\(variant)"
        let body = requestBody()
        // Waiting in the write outbox counts as exposed: looked up on a miss
        // (once per flag and variant per session), outside the lock.
        let known = withLock { exposedSession == session && exposed.contains(mark) }
        let waiting = !known && deps.pendingExposures().contains { exposureMarks($0).contains(mark) }
        var previous: PendingBatch?
        var schedule = false
        withLock {
            adoptExposureSession(session)
            if waiting, !exposed.contains(mark) {
                exposed.insert(mark)
                exposedOrder.append(mark)
            }
            guard !exposed.contains(mark) else { return }
            exposed.insert(mark)
            exposedOrder.append(mark)
            while exposedOrder.count > JoryioFlags.FLAG_EXPOSURE_MARKS_MAX {
                exposed.remove(exposedOrder.removeFirst())
            }
            if pending == nil || pending?.generation != generation {
                // A batch from before an identity change goes first, as its own person.
                previous = pending
                pending = PendingBatch(body: body, generation: generation, wipe: wipes, exposures: [])
            }
            pending?.exposures.append(["key": key, "variant": variant])
            pending?.marks.append(mark)
            if !flushScheduled {
                flushScheduled = true
                schedule = true
            }
        }
        if let previous { send(previous) }
        if schedule {
            DispatchQueue.global().asyncAfter(deadline: .now() + deps.exposureFlushDelay) { [weak self] in
                self?.flush()
            }
        }
    }

    /// Send the queued exposures (one request, the identity they were read under).
    func flush() {
        let batch: PendingBatch? = withLock {
            flushScheduled = false
            let b = pending
            pending = nil
            return b
        }
        if let batch { send(batch) }
    }

    private func send(_ batch: PendingBatch) {
        // Consent withdrawn since the reads: nothing is sent.
        guard !batch.exposures.isEmpty, deps.canSend() else { return }
        // One request after the other, in reading order.
        Task { for chunk in Self.splitExposureBatch(batch) { await self.post(chunk) } }
    }

    /// The batch's request body: the same bytes, the same idempotencyKey, on every retry.
    private static func requestData(_ batch: PendingBatch) -> Data? {
        var body = batch.body
        body["exposures"] = batch.exposures
        body["idempotencyKey"] = batch.idempotencyKey
        return try? JSONSerialization.data(withJSONObject: body)
    }

    /// One POST of `batch`. Its marks are stored only once the server took it
    /// (`exposureBatchSettled`); otherwise the write outbox gets it, with the
    /// same idempotencyKey.
    private func post(_ batch: PendingBatch) async {
        guard let data = Self.requestData(batch) else { return }
        let answer: FlagsPostStatus
        if let postExposures = deps.postExposures {
            answer = await postExposures(data)
        } else {
            answer = FlagsPostStatus(status: await deps.post("/v1/flags/exposures", data) != nil ? 200 : 0)
        }
        // Taken - or refused for good (a 4xx other than 408 / 429): never sent again.
        if exposureBatchSettled(answer.status) {
            storeMarks(batch.marks)
            return
        }
        // Not taken: the persisted outbox retries it, same body and key - unless
        // the data was wiped or sending stopped (opt-out, consent) meanwhile.
        if withLock({ batch.wipe == wipes }), deps.canSend(), let body = String(data: data, encoding: .utf8) {
            // Its first outbox attempt waits (it failed once, and the server
            // may have said when to come back): never an immediate second send.
            deps.enqueueExposures(body, answer.retryAfter)
        }
    }

    /// The write outbox settled an exposures batch (taken, or refused for good): its marks are stored.
    func exposuresSettled(_ body: String) {
        storeMarks(exposureMarks(body))
    }

    /// The server took a batch (directly or through the outbox): its marks are
    /// kept on disk. Only the current session's and person's: a batch of the
    /// previous person (reset, another user) stores none.
    private func storeMarks(_ marks: [String]) {
        let subject = subjectKey()
        let current = deps.sessionId()
        let stored: String? = withLock {
            // Settled by the outbox before this launch read a flag: the session's stored marks first.
            adoptExposureSession(current)
            guard let session = exposedSession, !session.isEmpty else { return nil }
            let mine = marks.filter { $0.hasPrefix("\(session)|\(subject)|") && !storedMarks.contains($0) }
            guard !mine.isEmpty else { return nil }
            storedMarks.append(contentsOf: mine)
            // Known as sent in this process too (an outbox settle can come before any read).
            for m in mine where !exposed.contains(m) {
                exposed.insert(m)
                exposedOrder.append(m)
            }
            if storedMarks.count > JoryioFlags.FLAG_EXPOSURE_MARKS_MAX {
                storedMarks.removeFirst(storedMarks.count - JoryioFlags.FLAG_EXPOSURE_MARKS_MAX)
            }
            guard let data = try? JSONSerialization.data(withJSONObject: ["sessionId": session, "marks": storedMarks]) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        if let stored { deps.saveExposures(stored) }
    }

    private func subjectKey() -> String {
        "\(deps.userId() ?? "")|\(deps.anonymousId())"
    }

    /// The identity, attributes and context of one request - the same on /evaluate and /exposures.
    private func requestBody() -> [String: Any] {
        var body: [String: Any] = [
            "anonymousId": deps.anonymousId(),
            "sessionId": deps.sessionId(),
            "attributes": Self.jsonSafe(deps.attributes()),
            "context": Self.jsonSafe(deps.context()),
        ]
        if let userId = deps.userId(), !userId.isEmpty { body["userId"] = userId }
        return body
    }

    func refresh(force: Bool) async {
        guard deps.canSend() else { return }
        let claim: (task: Task<Void, Never>, stale: Bool)? = withLock {
            guard used else { return nil }
            if let inflight {
                // A request in flight for a previous person: wait for it, then ask for this one.
                return (inflight, inflightGeneration != generation)
            }
            if !force, let at = fetchedAt, deps.now().timeIntervalSince(at) < JoryioFlags.FLAGS_MIN_REFRESH_SECONDS { return nil }
            let gen = generation
            let t = Task { [weak self] () -> Void in
                guard let self else { return }
                await self.performRefresh(generation: gen)
            }
            inflight = t
            inflightGeneration = gen
            return (t, false)
        }
        guard let claim else { return }
        await claim.task.value
        if claim.stale { await refresh(force: true) }
    }

    private func performRefresh(generation gen: Int) async {
        defer { withLock { inflight = nil } }
        var body = requestBody()
        let heldEtag = withLock { etag }
        if !heldEtag.isEmpty { body["etag"] = heldEtag }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        guard let res = await deps.post("/v1/flags/evaluate", data) else { return }
        let changed: [String]? = withLock {
            guard gen == generation else { return nil } // an answer for a previous person
            fetchedAt = deps.now()
            if (res["notModified"] as? Bool) == true { return [] }
            guard let next = res["flags"] as? [String: [String: Any]] else { return nil }
            let keys = Set(flags.keys).union(next.keys)
            let diff = keys.filter { k in
                Self.canonical(flags[k]?["value"]) != Self.canonical(next[k]?["value"])
                    || (flags[k]?["variant"] as? String) != (next[k]?["variant"] as? String)
            }
            flags = next
            etag = (res["etag"] as? String) ?? ""
            return diff.sorted()
        }
        guard let changed else { return }
        save()
        if !changed.isEmpty { emit(changed) }
    }

    private func emit(_ keys: [String]) {
        let callbacks = withLock { Array(listeners.values) }
        guard !callbacks.isEmpty else { return }
        deps.callbackQueue.async {
            for cb in callbacks { cb(keys) }
        }
    }

    // MARK: - Storage (one answer, for one person)

    private func load() {
        guard let raw = deps.load(), let data = raw.data(using: .utf8),
              let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        // Another person's answer is never used.
        guard (s["subject"] as? String) == subjectKey(), let stored = s["flags"] as? [String: [String: Any]] else { return }
        flags = stored
        etag = (s["etag"] as? String) ?? ""
        used = true
        // The stored answer is used at once, but the start refresh always goes.
        fetchedAt = nil
    }

    private func save() {
        let s: [String: Any] = withLock {
            [
                "subject": subjectKey(),
                "etag": etag,
                "fetchedAt": (fetchedAt?.timeIntervalSince1970 ?? 0) * 1000,
                "flags": flags,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: s), let raw = String(data: data, encoding: .utf8) else { return }
        deps.save(raw)
    }

    // MARK: - JSON helpers

    /// NSNull -> nil, everything else as decoded.
    private static func plain(_ v: Any?) -> Any? {
        if v == nil || v is NSNull { return nil }
        return v
    }

    /// A JSON boolean (CFBoolean), not a number that happens to be 0 or 1.
    static func isBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func canonical(_ v: Any?) -> String {
        guard let v, !(v is NSNull) else { return "null" }
        guard let data = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .sortedKeys]) else { return "\(v)" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Only values JSON can carry (a Date or a custom type in the attributes is left out).
    private static func jsonSafe(_ dict: [String: Any]) -> [String: Any] {
        dict.filter { JSONSerialization.isValidJSONObject(["v": $0.value]) }
    }
}
