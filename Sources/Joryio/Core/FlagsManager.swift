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
   consent is withdrawn before it goes.
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
}

/// Returned by `onFlagsUpdated`; `cancel()` stops the callbacks.
public final class FlagsSubscription {
    private let onCancel: () -> Void
    private let lock = NSLock()
    private var cancelled = false

    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }

    public func cancel() {
        lock.lock()
        let first = !cancelled
        cancelled = true
        lock.unlock()
        if first { onCancel() }
    }
}

final class FlagsManager {
    /// The network: POST a JSON body, answer the decoded JSON object or nil.
    typealias Post = (_ path: String, _ body: Data) async -> [String: Any]?

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
    }

    private struct PendingBatch {
        let body: [String: Any]
        let generation: Int
        var exposures: [[String: String]]
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
    /// `<session>|<person>|<flag>|<variant>` already reported.
    private var exposed = Set<String>()
    private var pending: PendingBatch?
    private var flushScheduled = false

    /// The cached answer is per workspace: the key carries the SDK key, like
    /// every other key StorageManager keeps (`jry_<sdkKey>_...`), because the
    /// kv table is one database per app - an app that switches SDK keys (two
    /// workspaces) must never read the other's flags for the same external id.
    static func storageKey(sdkKey: String) -> String { "jry_\(sdkKey)_flags_cache" }
    /// The unscoped key of builds before 2026-11-21: never read, removed at start.
    static let legacyStorageKey = "flags_cache"

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
    func onIdentityChanged() {
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
            generation += 1
            pending = nil
            flags = [:]
            etag = ""
            fetchedAt = nil
            exposed.removeAll()
        }
        deps.save(nil)
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

    func onFlagsUpdated(_ callback: @escaping ([String]) -> Void) -> FlagsSubscription {
        let id = UUID()
        withLock { listeners[id] = callback }
        use()
        return FlagsSubscription { [weak self] in
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
        let mark = "\(deps.sessionId())|\(subjectKey())|\(key)|\(variant)"
        let body = requestBody()
        var previous: PendingBatch?
        var schedule = false
        withLock {
            guard !exposed.contains(mark) else { return }
            exposed.insert(mark)
            if pending == nil || pending?.generation != generation {
                // A batch from before an identity change goes first, as its own person.
                previous = pending
                pending = PendingBatch(body: body, generation: generation, exposures: [])
            }
            pending?.exposures.append(["key": key, "variant": variant])
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
        var body = batch.body
        body["exposures"] = Array(batch.exposures.prefix(JoryioFlags.FLAG_EXPOSURES_PER_CALL_MAX))
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let post = deps.post
        Task { _ = await post("/v1/flags/exposures", data) }
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
