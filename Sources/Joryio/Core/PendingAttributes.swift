import Foundation

/**
 Attributes written by the app that the server has not acknowledged yet.

 `setAttributes` used to POST fire-and-forget: on failure it logged and dropped
 the value. An attribute set while offline never reached the server at all, and
 because the in-app sync path ALSO carried attributes and let them override the
 stored profile, in-app targeting still looked right - so the loss was invisible
 everywhere it mattered (segments, journeys, email).

 Events have had a SQLite-backed at-least-once queue with retry-on-next-flush
 since the beginning. Attributes had nothing. This closes that gap.

 ## Persisted, and why that is not a reversal of the no-PII-at-rest rule

 `76037051` deliberately stopped persisting the attribute TRAIT BAG, and there
 is purge-on-init code that removes any bag an older build left behind. This
 queue is a different thing and is stored separately:

 | | the trait bag | this queue |
 |---|---|---|
 | what it is | a cache of who the user is | undelivered work |
 | lifetime | indefinite | until the server acks |
 | contents | everything | only un-acked keys |
 | if lost | re-read from the server | **the write never happens** |

 That last row is why it must survive process death: nothing else holds the
 value. The trait bag can be lost safely because the server already has it.

 Stored in the Keychain (device-only, after-first-unlock) rather than
 UserDefaults, matching where the identity-linking secrets were moved, and
 cleared the moment the server acks - so it holds PII only between a failed
 send and the next successful one, and only when a send has actually failed.
 Purged on reset() and optOut() alongside everything else.

 ## Second job: the un-acked set IS the dirty set

 `pending()` is what the in-app sync request sends. Only attributes the server
 has not confirmed need to ride that request; everything else is already in the
 profile and the server should read its own copy. That turns the sync payload
 from "everything the device believes" into "the little the server might not
 know yet", which is what makes server-authoritative targeting safe.
 */
/// What one flush sends: the three atomic sections of `/v1/attributes`.
/// Keys are disjoint across the sections by construction (see the folding
/// rules on `PendingAttributes`), so one request never asks the server to
/// `$set` and `$inc` the same path.
struct PendingAttributeSnapshot {
    let sets: [String: Any]
    let increments: [String: Double]
    let unsets: [String]
    /// The queue's generation when this was taken. reset() / opt-out start a
    /// new one, so the acknowledgement of a request sent for the PREVIOUS
    /// person can never clear the same value written for the next one
    /// (scan 3, M1; SDK contract 31).
    var generation: Int = 0

    var isEmpty: Bool { sets.isEmpty && increments.isEmpty && unsets.isEmpty }

    /// How many separate operations this snapshot carries.
    var operationCount: Int { sets.count + increments.count + unsets.count }

    /**
     Two halves of this snapshot, or nil when it is a single operation.

     Used when the server refuses a write as invalid (400 / 413 / 422): the
     same rule as an event batch (SDK contract 3). One bad key used to keep the
     WHOLE pending set refused on every flush, forever, so every later
     attribute write was stuck behind it.
     */
    func split() -> (PendingAttributeSnapshot, PendingAttributeSnapshot)? {
        guard operationCount > 1 else { return nil }
        enum Op { case set(String, Any), inc(String, Double), unset(String) }
        var ops: [Op] = []
        ops += sets.keys.sorted().map { .set($0, sets[$0]!) }
        ops += increments.keys.sorted().map { .inc($0, increments[$0]!) }
        ops += unsets.sorted().map { .unset($0) }
        func build(_ slice: ArraySlice<Op>) -> PendingAttributeSnapshot {
            var s: [String: Any] = [:], i: [String: Double] = [:], u: [String] = []
            for op in slice {
                switch op {
                case let .set(k, v): s[k] = v
                case let .inc(k, d): i[k] = d
                case let .unset(k): u.append(k)
                }
            }
            return PendingAttributeSnapshot(sets: s, increments: i, unsets: u, generation: generation)
        }
        let mid = ops.count / 2
        return (build(ops[..<mid]), build(ops[mid...]))
    }
}

final class PendingAttributes {
    private var pending: [String: Any] = [:]
    /// Un-acknowledged `incrementAttribute` deltas, summed per key.
    ///
    /// `incrementAttribute` and `unsetAttribute` used to POST fire-and-forget,
    /// so a counter bumped while offline was simply lost - the same gap this
    /// queue closed for `setAttributes`. They now ride the same queue, folded
    /// so the request stays one coherent set of operations:
    ///   set(k)    -> replaces any pending increment or unset of k
    ///   inc(k, d) -> adds to a pending NUMERIC set of k; turns a pending unset
    ///                into set(k, d) (unset-then-increment IS d); otherwise sums
    ///   unset(k)  -> drops any pending set or increment of k
    private var increments: [String: Double] = [:]
    private var unsets: Set<String> = []
    /// Bumped by clear(); see PendingAttributeSnapshot.generation.
    private var generation = 0
    private let lock = NSLock()

    /// Marks the v2 persisted shape (sets + increments + unsets). The v1 shape
    /// was the bare `sets` object, which `restore()` still reads.
    private static let formatKey = "__joryio_pending_v2"

    /**
     Encrypted durable backing, or nil to stay in-memory only.

     Persisted because an un-acked write is UNDELIVERED WORK, not a cache: if
     the process dies before the flush, the value never reaches the server and
     nothing else holds it. That is the one case in-memory retry cannot cover.
     Keychain-backed, cleared on ack, purged on reset/opt-out.
     */
    private weak var storage: StorageManager?

    /// Cap so a pathological app setting unique keys in a loop while offline
    /// cannot grow this without bound. Oldest keys are dropped first; they are
    /// also the ones most likely to have been superseded.
    private let maxKeys: Int

    init(maxKeys: Int = 500, storage: StorageManager? = nil) {
        self.maxKeys = maxKeys
        self.storage = storage
        restore()
    }

    private func restore() {
        guard let json = storage?.getPendingAttributes(), !json.isEmpty,
              let data = json.data(using: .utf8) else { return }
        guard let restored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Corrupt blob: drop it rather than fail SDK init.
            storage?.clearPendingAttributes()
            return
        }
        lock.lock()
        defer { lock.unlock() }
        if restored[Self.formatKey] != nil {
            pending.merge((restored["sets"] as? [String: Any]) ?? [:]) { _, new in new }
            for (key, value) in (restored["increments"] as? [String: Any]) ?? [:] {
                if let n = value as? NSNumber { increments[key] = n.doubleValue }
            }
            unsets.formUnion((restored["unsets"] as? [String]) ?? [])
        } else {
            pending.merge(restored) { _, new in new }
        }
    }

    /// Caller must hold the lock.
    private func persistLocked() {
        guard let storage else { return }
        guard !pending.isEmpty || !increments.isEmpty || !unsets.isEmpty else {
            storage.clearPendingAttributes()
            return
        }
        let blob: [String: Any] = [
            Self.formatKey: true,
            "sets": Self.jsonSafe(pending),
            "increments": increments,
            "unsets": Array(unsets),
        ]
        guard JSONSerialization.isValidJSONObject(blob),
              let data = try? JSONSerialization.data(withJSONObject: blob),
              let json = String(data: data, encoding: .utf8) else { return }
        storage.setPendingAttributes(json)
    }

    /// A value JSONSerialization accepts. A `Date` attribute
    /// (`setAttribute("last_purchase", value: Date())`, as the docs show) is not
    /// valid JSON, and one such value made the WHOLE pending set unpersistable -
    /// every queued write was then lost on a process kill. Dates become the
    /// ISO-8601 UTC string they are sent as anyway.
    static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let date as Date:
            return WireJSON.timestamp(date)
        case let dict as [String: Any]:
            return dict.mapValues { jsonSafe($0) }
        case let array as [Any]:
            return array.map { jsonSafe($0) }
        case is String, is NSNumber, is NSNull:
            return value
        default:
            return String(describing: value)
        }
    }

    /// Mark attributes as written locally and not yet acknowledged.
    func mark(_ attributes: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        for (key, value) in attributes {
            pending[key] = value
            increments.removeValue(forKey: key)
            unsets.remove(key)
        }
        if pending.count > maxKeys {
            // Dictionaries are unordered, so "oldest" is approximate. The cap
            // exists to bound memory, not to be fair.
            let overflow = pending.count - maxKeys
            for key in pending.keys.prefix(overflow) {
                pending.removeValue(forKey: key)
            }
        }
        persistLocked()
    }

    /// Queue an atomic increment. See the folding rules on `increments`.
    func markIncrement(_ key: String, by delta: Double) {
        lock.lock()
        defer { lock.unlock() }
        if let current = pending[key] {
            if let number = current as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                pending[key] = number.doubleValue + delta
            } else {
                // Incrementing a non-number is a server error either way; the
                // last write wins rather than sending a self-conflicting request.
                pending[key] = delta
            }
        } else if unsets.contains(key) {
            unsets.remove(key)
            pending[key] = delta
        } else {
            increments[key, default: 0] += delta
        }
        persistLocked()
    }

    /// Queue an atomic unset. See the folding rules on `increments`.
    func markUnset(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        pending.removeValue(forKey: key)
        increments.removeValue(forKey: key)
        unsets.insert(key)
        // Bounded like the sets: unsets had no cap at all.
        if unsets.count > maxKeys {
            for extra in unsets.prefix(unsets.count - maxKeys) { unsets.remove(extra) }
        }
        persistLocked()
    }

    /// The backend's `@ArrayMaxSize(200)` on `unset`. A flush carrying more
    /// was refused with 400 every time, so the queue never drained.
    static let maxUnsetsPerRequest = 200

    /// Everything the server has not confirmed (the `$set` section only - what
    /// the in-app sync request carries as `pendingAttributes`).
    func pendingAttributes() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    /// What ONE flush request sends: everything pending, except that unsets
    /// are limited to what the server takes per request. The rest goes out in
    /// the next request once this one is acknowledged.
    func snapshot() -> PendingAttributeSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return PendingAttributeSnapshot(
            sets: pending,
            increments: increments,
            unsets: Array(unsets.sorted().prefix(Self.maxUnsetsPerRequest)),
            generation: generation
        )
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending.isEmpty && increments.isEmpty && unsets.isEmpty
    }

    /**
     Clear the keys the server confirmed - but ONLY where the value is still the
     one that was sent.

     If the app called `setAttributes(["plan": "pro"])` while a flush carrying
     `plan: "free"` was in flight, acking the flush must not clear `plan`, or
     the newer value is silently lost. Comparing values, not just keys, is what
     makes a concurrent write safe.
     */
    func acknowledge(_ sent: [String: Any]) {
        lock.lock()
        let current = generation
        lock.unlock()
        acknowledge(PendingAttributeSnapshot(sets: sent, increments: [:], unsets: [], generation: current))
    }

    func acknowledge(_ sent: PendingAttributeSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        // Sent before a reset(): what it carried belonged to the previous
        // person, and nothing pending now is theirs.
        guard sent.generation == generation else { return }
        for (key, sentValue) in sent.sets {
            guard let current = pending[key] else { continue }
            if Self.isSameValue(current, sentValue) {
                pending.removeValue(forKey: key)
            }
        }
        // An increment that arrived mid-flight is still owed: subtract only
        // what was sent.
        for (key, delta) in sent.increments {
            guard let current = increments[key] else { continue }
            let remaining = current - delta
            if abs(remaining) < 1e-9 {
                increments.removeValue(forKey: key)
            } else {
                increments[key] = remaining
            }
        }
        // Unset is idempotent; a set that replaced it mid-flight already
        // removed it from the set.
        for key in sent.unsets {
            unsets.remove(key)
        }
        persistLocked()
    }

    /// Bumped by `clear()` and `takeForHandOff`: a snapshot of an older
    /// generation belonged to a previous identity.
    var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /**
     Everything still owed, minus what a request already in flight carries -
     and the set emptied (a new generation). For identify() of a DIFFERENT
     user without reset() (SDK contract v5, 53): what the previous user set
     and the server has not got yet is sent under THAT user's ids, never
     the next one's. The in-flight request was built with the previous
     user's ids already; it is subtracted so an increment is not sent twice.
     All unsets, not the per-request prefix `snapshot()` gives.
     */
    func takeForHandOff(excluding inFlight: PendingAttributeSnapshot?) -> PendingAttributeSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var sets = pending
        var incs = increments
        var unsetKeys = unsets
        if let inFlight {
            for (key, sent) in inFlight.sets {
                if let current = sets[key], Self.isSameValue(current, sent) { sets.removeValue(forKey: key) }
            }
            for (key, delta) in inFlight.increments {
                guard let current = incs[key] else { continue }
                let remaining = current - delta
                if abs(remaining) < 1e-9 { incs.removeValue(forKey: key) } else { incs[key] = remaining }
            }
            unsetKeys.subtract(inFlight.unsets)
        }
        generation += 1
        pending.removeAll()
        increments.removeAll()
        unsets.removeAll()
        storage?.clearPendingAttributes()
        return PendingAttributeSnapshot(sets: sets, increments: incs, unsets: unsetKeys.sorted(), generation: generation - 1)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        pending.removeAll()
        increments.removeAll()
        unsets.removeAll()
        storage?.clearPendingAttributes()
    }

    /// Equality across the JSON-ish types attributes can hold. Anything we
    /// cannot compare is treated as CHANGED, so the attribute stays pending
    /// and is retried - re-sending is harmless, dropping is not.
    ///
    /// Arrays and dictionaries used to fall through to "changed", so an array
    /// or object attribute was never acknowledged: it stayed in the queue
    /// forever and rode every flush and every in-app sync. They now compare
    /// structurally through Foundation's collection equality, which compares
    /// elements with the same NSNumber/NSString rules as the scalars.
    static func isSameValue(_ a: Any, _ b: Any) -> Bool {
        if let a = a as? String, let b = b as? String { return a == b }
        // A Date attribute was never acknowledged (it fell through to
        // "changed"), so it rode every flush and every in-app sync forever.
        if let a = a as? Date, let b = b as? Date { return a == b }
        if let a = a as? NSNumber, let b = b as? NSNumber {
            // A boolean and the number 1 are different values on the wire.
            let aBool = CFGetTypeID(a) == CFBooleanGetTypeID()
            let bBool = CFGetTypeID(b) == CFBooleanGetTypeID()
            guard aBool == bBool else { return false }
            return a == b
        }
        if let a = a as? [Any], let b = b as? [Any] {
            return NSArray(array: a).isEqual(to: b)
        }
        if let a = a as? [String: Any], let b = b as? [String: Any] {
            return NSDictionary(dictionary: a).isEqual(to: b)
        }
        if a is NSNull, b is NSNull { return true }
        return false
    }
}
