import Foundation

/// One item as the server sends it.
final class PlacementItemWire {
    let id: String
    let variantId: String?
    let deliveryToken: String?
    let deliveryId: String?
    let priority: Int?
    let kind: String
    let data: [String: Any]
    let content: PlacementContent?
    /// Products picked for the person by a recommendation model (D444 Phase 2b).
    let products: [PlacementProduct]
    /// Event triggers: `{ type, event, attribute?, operator?, value? }`.
    let triggers: [[String: Any]]
    let triggerWindowSeconds: Int?
    let expiresAt: String?
    /// "Show when" (D465): the moment it is revealed on a screen; absent = load.
    let showWhen: ShowWhenMoment

    init?(_ o: [String: Any]) {
        guard let id = o["id"] as? String else { return nil }
        self.id = id
        variantId = o["variantId"] as? String
        deliveryToken = o["deliveryToken"] as? String
        deliveryId = o["deliveryId"] as? String
        priority = (o["priority"] as? NSNumber)?.intValue
        data = (o["data"] as? [String: Any]) ?? [:]
        if let c = o["content"] as? [String: Any] {
            content = PlacementContent(
                kind: (c["kind"] as? String) ?? "native",
                title: c["title"] as? String,
                body: c["body"] as? String,
                imageUrl: c["imageUrl"] as? String,
                buttons: ((c["buttons"] as? [[String: Any]]) ?? []).map {
                    PlacementButton(id: ($0["id"] as? String) ?? "", text: ($0["text"] as? String) ?? "", action: ($0["action"] as? String) ?? "", url: $0["url"] as? String)
                },
                closeButton: (c["closeButton"] as? Bool) ?? false,
                html: c["html"] as? String,
                css: c["css"] as? String
            )
        } else {
            content = nil
        }
        kind = (o["kind"] as? String) ?? content?.kind ?? "data"
        products = ((o["products"] as? [[String: Any]]) ?? []).compactMap(PlacementProduct.init)
        triggers = (o["triggers"] as? [[String: Any]]) ?? []
        triggerWindowSeconds = (o["placementTriggerWindowSeconds"] as? NSNumber)?.intValue
        expiresAt = o["expiresAt"] as? String
        showWhen = ShowWhenMoment.parse(o["showWhen"])
    }
}

/// One placement as the server sends it.
final class PlacementWire {
    let placementKey: String
    let emptyBehavior: String
    let maxItems: Int
    let ttlSeconds: Int
    let isControl: Bool
    let controlToken: String?
    let items: [PlacementItemWire]
    /// A control answer's "Show when" (D465): the moment the held-out treatment
    /// would have been revealed - `control_viewed` waits for it.
    let showWhen: ShowWhenMoment
    /// Control exposures of A/B-control campaigns that fell through to the drawn
    /// item at a different moment: each reported once at ITS moment, once the spot was viewable.
    let deferredControls: [(controlToken: String, showWhen: ShowWhenMoment)]
    /// Event names that, when tracked, make the SDK re-fetch this key at once.
    let recheckOn: [String]
    /// The JSON as received: the disk cache and change detection.
    let json: [String: Any]

    init(key: String, _ o: [String: Any]) {
        placementKey = key
        emptyBehavior = (o["emptyBehavior"] as? String) == Placements.keepSpace ? Placements.keepSpace : Placements.collapse
        let max = (o["maxItems"] as? NSNumber)?.intValue ?? 1
        maxItems = max > 0 ? max : 1
        let ttl = (o["ttlSeconds"] as? NSNumber)?.intValue ?? 300
        ttlSeconds = ttl > 0 ? ttl : 300
        isControl = (o["isControl"] as? Bool) ?? false
        controlToken = o["controlToken"] as? String
        items = ((o["items"] as? [[String: Any]]) ?? []).compactMap { PlacementItemWire($0) }
        showWhen = isControl ? ShowWhenMoment.parse(o["showWhen"]) : .load
        deferredControls = ((o["deferredControls"] as? [[String: Any]]) ?? []).compactMap { d in
            guard let token = d["controlToken"] as? String, !token.isEmpty else { return nil }
            return (token, ShowWhenMoment.parse(d["showWhen"]))
        }
        recheckOn = ((o["recheckOn"] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        json = o
    }
}

/// The HTTP the manager needs; NetworkClient in the app, a fake in tests.
protocol PlacementTransport: AnyObject {
    /// POST /v1/in-app/placements once (no retries): HTTP status (0 = no answer) and body.
    func fetchPlacements(_ body: Data) async -> (Int, Data?)
    /// POST /v1/in-app/track.
    func trackPlacement(_ body: Data) async
}

/**
 Fetches, caches and refreshes placements, and reports what the person did
 with them (docs/PLACEMENTS_PLAN.md 3.5-3.9), by the rules every Joryio SDK
 shares:

 - keys asked for within PLACEMENT_BATCH_WINDOW_MS go in one request, at most
   PLACEMENT_MAX_KEYS_PER_REQUEST keys each;
 - an answer is served from the cache for its ttlSeconds (memory + disk,
   scoped to the person);
 - a key goes to the network at most once per PLACEMENT_MIN_REFRESH_SECONDS; a
   forced refresh inside that window is deferred and coalesced; a 429 or a
   failure keeps the cache;
 - an identity or consent change bumps a generation: older answers are dropped;
 - without consent the request names nobody and nothing is reported;
 - "Show when" (BACKLOG D465, packages/backend/src/common/show-when.ts): an
   item, a control answer and each deferred control carry the moment they are
   revealed on a screen. The content is fetched as before and HELD - left out
   of every Placement - until its moment: `seconds` = foreground seconds on
   the current screen (the time_on_screen ScreenClock), `event` = the event
   was tracked in this visit (SDK session). `scroll` / `exit` / unknown are
   never shown. Revealed content stays for the screen; a new screen starts the
   moment again. An event that something waits on (or that the answer lists in
   `recheckOn`) re-checks the key at once, past PLACEMENT_MIN_REFRESH_SECONDS,
   at most once per (key, event) per screen: only after the event has left the
   queue (sent by the flush in flight or one more; after a failure, once after
   the next successful flush), in a request of its own that carries the event
   as `recheckEvent: { name, eventId, properties }`.
 */
final class PlacementManager: PlacementReporter {
    private struct Entry {
        let placement: PlacementWire
        let fetchedAt: TimeInterval
    }

    private let transport: PlacementTransport
    private let load: () -> String?
    private let save: (String?) -> Void
    /// nil = nothing may be sent; "granted" | "pending" | "denied" otherwise.
    private let consent: () -> String?
    private let userId: () -> String?
    private let anonymousId: () -> String
    private let sessionId: () -> String?
    private let capabilities: () -> [String]
    private let now: () -> TimeInterval
    private let onMain: (@escaping () -> Void) -> Void

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var lastNetworkAt: [String: TimeInterval] = [:]
    private var inflight: [String: [() -> Void]] = [:]
    private var batchKeys: [String] = []
    private var batchScheduled = false
    private var deferredKeys: [String] = []
    private var deferredScheduled = false
    private var listeners: [UUID: ([String: Placement]) -> Void] = [:]
    private var hosts: [ObjectIdentifier: WeakHost] = [:]
    private var reported = Set<String>()
    private var triggeredAt: [String: TimeInterval] = [:]
    private var dismissedLocally = Set<String>()
    private var generation = 0

    // "Show when" (D465)
    private enum MomentKind { case item, control, deferred }
    private struct MomentId: Hashable {
        let kind: MomentKind
        let key: String
        let token: String
    }
    private let screenClock: ScreenClock
    /// Sends the queue until this event (client eventId) has left it; false = still queued.
    private let deliverEvent: (String) async -> Bool
    /// Is this event still queued? (a pending re-check runs once it is not)
    private let isEventQueued: (String) -> Bool
    private let schedule: (TimeInterval, @escaping () -> Void) -> () -> Void
    /// Moments reached on the current screen (cleared by a new screen).
    private var revealed = Set<MomentId>()
    /// Keys whose spot was viewable on the current screen (deferred controls wait for it).
    private var viewedOnScreen = Set<String>()
    /// `key\0event` re-checked on the current screen.
    private var rechecked = Set<String>()
    /// Event names tracked in the visit `sessionEventsId`.
    private var sessionEvents = Set<String>()
    private var sessionEventsId: String?
    /// Every re-check not run yet, registered when its event is tracked, in tracking order
    /// (`seq`); the oldest dropped past `PENDING_RECHECK_MAX`. A re-check runs only if it is
    /// still here when its event is delivered - whether the delivery returns at once, returns
    /// later (queued behind a failing flush), or a later flush sends it - and leaves it as it
    /// runs, so it runs once. The cap holds by construction (1.4.0-beta.11).
    private var pendingRechecks: [Recheck] = []
    /// Answers apply in request order: an older request answering last never overwrites a newer one.
    private var requestSeq = 0
    private var appliedSeq: [String: Int] = [:]

    private struct Recheck {
        let id = UUID()
        let keys: [String]
        let eventId: String?
        /// `{ name, eventId, properties }`, the event as queued; nil without the event.
        let event: [String: Any]?
        /// Who and under which consent it was queued for: it never runs for anyone else.
        let subject: String
        let consent: String?
        let generation: Int
        let queuedAt: TimeInterval
        /// Tracking order, stamped when the event is tracked: "oldest" past the cap means tracked first.
        let seq: Int
    }
    private var recheckSeq = 0

    /// Pending re-checks kept at most (oldest dropped) and for at most this many seconds.
    static let PENDING_RECHECK_MAX = 20
    static let PENDING_RECHECK_MAX_AGE_SECONDS: TimeInterval = 60
    private var cancelMomentTimer: (() -> Void)?

    private struct WeakHost { weak var host: PlacementHost? }

    init(
        transport: PlacementTransport,
        load: @escaping () -> String?,
        save: @escaping (String?) -> Void,
        consent: @escaping () -> String?,
        userId: @escaping () -> String?,
        anonymousId: @escaping () -> String,
        sessionId: @escaping () -> String?,
        capabilities: @escaping () -> [String],
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        onMain: @escaping (@escaping () -> Void) -> Void = { block in DispatchQueue.main.async(execute: block) },
        screenClock: ScreenClock = ScreenClock(),
        deliverEvent: @escaping (String) async -> Bool = { _ in true },
        isEventQueued: @escaping (String) -> Bool = { _ in false },
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> () -> Void = { delay, block in
            let work = DispatchWorkItem(block: block)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return { work.cancel() }
        }
    ) {
        self.transport = transport
        self.load = load
        self.save = save
        self.consent = consent
        self.userId = userId
        self.anonymousId = anonymousId
        self.sessionId = sessionId
        self.capabilities = capabilities
        self.now = now
        self.onMain = onMain
        self.screenClock = screenClock
        self.deliverEvent = deliverEvent
        self.isEventQueued = isEventQueued
        self.schedule = schedule
        loadCache()
        locked { _ = updateMomentsLocked() }
        screenClock.observe { [weak self] change in
            switch change {
            case .screen: self?.screenChanged()
            case .paused: self?.stopMomentTimer()
            case .resumed: self?.scheduleMomentTimer()
            }
        }
        scheduleMomentTimer()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Surface (through Joryio)

    func getPlacements(_ keys: [String], completion: @escaping ([String: Placement]) -> Void) {
        let wanted = cleanKeys(keys)
        ensure(wanted) { [weak self] in
            guard let self else { return }
            let out = Dictionary(uniqueKeysWithValues: wanted.map { ($0, self.toPlacement($0)) })
            self.onMain { completion(out) }
        }
    }

    func getPlacements(_ keys: [String]) async -> [String: Placement] {
        let wanted = cleanKeys(keys)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            ensure(wanted) { cont.resume() }
        }
        return Dictionary(uniqueKeysWithValues: wanted.map { ($0, toPlacement($0)) })
    }

    func refreshPlacements(_ keys: [String]?) {
        let wanted = keys.map(cleanKeys) ?? knownKeys()
        if !wanted.isEmpty { fetchKeys(wanted, force: true) {} }
    }

    func onPlacementsUpdated(_ listener: @escaping ([String: Placement]) -> Void) -> JoryioSubscription {
        let id = UUID()
        locked { listeners[id] = listener }
        return JoryioSubscription { [weak self] in
            self?.locked { self?.listeners[id] = nil }
        }
    }

    /// A view starts showing `host`'s placement: drawn from the cache, fetched when stale.
    func attach(_ host: PlacementHost) {
        let key = host.placementKey
        guard Self.validKey(key) else { return }
        let fresh: Bool = locked {
            hosts[ObjectIdentifier(host)] = WeakHost(host: host)
            return freshEntry(key) != nil
        }
        if fresh {
            let placement = toPlacement(key)
            onMain { [weak host] in host?.onPlacementUpdated(placement) }
        }
        ensure([key]) { [weak self, weak host] in
            guard let self, !fresh else { return }
            let placement = self.toPlacement(key)
            self.onMain { host?.onPlacementUpdated(placement) }
        }
    }

    func detach(_ host: PlacementHost) {
        _ = locked { hosts.removeValue(forKey: ObjectIdentifier(host)) }
    }

    /// The app came to the foreground: placements on screen whose TTL passed are asked for again.
    func onForeground() {
        let stale: [String] = locked {
            Array(Set(liveHosts().map { $0.placementKey })).filter { freshEntry($0) == nil }
        }
        if !stale.isEmpty { fetchKeys(stale, force: false) {} }
    }

    /// The silent push `jry_sync: "placements"` (or `in_app`).
    func onSyncPush() { refreshPlacements(nil) }

    /// The person or the consent changed: forget every answer, ask again for what is on screen.
    func invalidate() {
        let (keys, toClear): ([String], [PlacementHost]) = locked {
            generation += 1
            cache.removeAll()
            lastNetworkAt.removeAll()
            triggeredAt.removeAll()
            dismissedLocally.removeAll()
            reported.removeAll()
            revealed.removeAll()
            viewedOnScreen.removeAll()
            rechecked.removeAll()
            pendingRechecks.removeAll()
            let live = liveHosts()
            return (Array(Set(live.map { $0.placementKey })), live)
        }
        save(nil)
        // The previous person's content goes now, on screen or not.
        if !toClear.isEmpty { onMain { toClear.forEach { $0.clearPlacement() } } }
        if !keys.isEmpty { fetchKeys(keys, force: true) {} }
    }

    /// An event was tracked: event-triggered items waiting on it become eligible (no round trip);
    /// "Show when" `event` moments are reached, and the keys waiting on it are re-checked.
    /// `event`: the event as queued - its eventId gates the re-check and rides on it.
    func onEventTracked(_ eventName: String, properties: [String: Any], event: Event? = nil) {
        var changed: [String] = []
        var recheck: [String] = []
        var seq = 0
        locked {
            for (key, entry) in cache {
                for item in entry.placement.items where item.triggers.contains(where: {
                    ($0["type"] as? String) == "event" && ($0["event"] as? String) == eventName && Self.triggerMatches($0, properties)
                }) {
                    triggeredAt[handle(key, item)] = now()
                    if !changed.contains(key) { changed.append(key) }
                }
            }
            // Show when: the keys that wait on this event, BEFORE it counts.
            let moment = ShowWhenMoment.event(eventName)
            for (key, entry) in cache {
                let p = entry.placement
                let waits = p.recheckOn.contains(eventName)
                    || p.items.contains { $0.showWhen == moment && !revealed.contains(itemMoment(key, $0)) }
                    || (p.isControl && p.showWhen == moment && !revealed.contains(controlMoment(key, p)))
                    || p.deferredControls.contains { $0.showWhen == moment && !revealed.contains(MomentId(kind: .deferred, key: key, token: $0.controlToken)) }
                if waits && rechecked.insert("\(key)\u{0}\(eventName)").inserted { recheck.append(key) }
            }
            visitEventsLocked()
            sessionEvents.insert(eventName)
            for key in updateMomentsLocked() where !changed.contains(key) { changed.append(key) }
            if !recheck.isEmpty {
                recheckSeq += 1
                seq = recheckSeq
            }
        }
        if !changed.isEmpty { applyChanged(changed) }
        reportDueDeferredControls()
        if !recheck.isEmpty {
            let rc = Recheck(keys: recheck, eventId: event?.eventId, event: event.flatMap(Self.recheckEventJson),
                             subject: subjectKey(), consent: consent(), generation: locked { generation }, queuedAt: now(), seq: seq)
            // Registered now, at track time, in tracking order: past the cap the OLDEST
            // tracked is dropped, however each delivery later returns.
            locked {
                if let at = pendingRechecks.firstIndex(where: { $0.seq > rc.seq }) {
                    pendingRechecks.insert(rc, at: at)
                } else {
                    pendingRechecks.append(rc)
                }
                if pendingRechecks.count > Self.PENDING_RECHECK_MAX { pendingRechecks.removeFirst(pendingRechecks.count - Self.PENDING_RECHECK_MAX) }
            }
            Task { [weak self] in await self?.startRecheck(rc) }
        }
    }

    /// The server must have the event before it answers again.
    private func startRecheck(_ rc: Recheck) async {
        // Still queued (the flush failed): it stays registered, and runs once, after the
        // next flush that sends it - if it has not been dropped by then.
        if let id = rc.eventId, !(await deliverEvent(id)) { return }
        // Delivered (at once, or after waiting behind a failing flush): it runs only if it
        // is still registered - not dropped past the cap, not already run.
        let taken: Bool = locked {
            guard let i = pendingRechecks.firstIndex(where: { $0.id == rc.id }) else { return false }
            pendingRechecks.remove(at: i)
            return true
        }
        if taken { await runRecheck(rc) }
    }

    /// The event queue finished a flush: re-checks whose event has left it run now, once.
    func onEventsFlushed() {
        // Too old, or queued for someone else / another consent: dropped, never run.
        let waiting: [Recheck] = locked {
            pendingRechecks.removeAll { !stillValidLocked($0) }
            return pendingRechecks
        }
        let due = waiting.filter { rc in rc.eventId.map { !isEventQueued($0) } ?? true }
        guard !due.isEmpty else { return }
        let ids = Set(due.map(\.id))
        // Only those still registered: a delivery that returned meanwhile has run its own.
        let taken: [Recheck] = locked {
            let t = pendingRechecks.filter { ids.contains($0.id) }
            pendingRechecks.removeAll { ids.contains($0.id) }
            return t
        }
        for rc in taken { Task { [weak self] in await self?.runRecheck(rc) } }
    }

    /// Re-checks waiting for their event (test seam).
    var pendingRecheckCount: Int { locked { pendingRechecks.count } }

    /// Lock held. The same person, consent and generation, and not older than the limit.
    private func stillValidLocked(_ rc: Recheck) -> Bool {
        rc.generation == generation && now() - rc.queuedAt <= Self.PENDING_RECHECK_MAX_AGE_SECONDS
            && rc.subject == subjectKey() && rc.consent == consent()
    }

    /// A request of its own (never batched with other keys), past the refresh limit.
    private func runRecheck(_ rc: Recheck) async {
        guard locked({ stillValidLocked(rc) }) else { return }
        var start = 0
        while start < rc.keys.count {
            let chunk = Array(rc.keys[start..<min(rc.keys.count, start + Placements.PLACEMENT_MAX_KEYS_PER_REQUEST)])
            await request(chunk, recheckEvent: rc.event)
            start += Placements.PLACEMENT_MAX_KEYS_PER_REQUEST
        }
    }

    /// `{ name, eventId, properties }` from the event as the queue encodes it.
    static func recheckEventJson(_ event: Event) -> [String: Any]? {
        guard let data = try? WireJSON.encoder().encode(event),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return ["name": event.type, "eventId": event.eventId, "properties": o["properties"] ?? [String: Any]()]
    }

    // MARK: - Fetching

    static func validKey(_ key: String) -> Bool {
        key.range(of: "^[a-z0-9][a-z0-9_]{0,63}$", options: .regularExpression) != nil
    }

    private func cleanKeys(_ keys: [String]) -> [String] {
        var out: [String] = []
        for key in keys where Self.validKey(key) && !out.contains(key) { out.append(key) }
        return out
    }

    private func liveHosts() -> [PlacementHost] {
        hosts = hosts.filter { $0.value.host != nil }
        return hosts.values.compactMap { $0.host }
    }

    private func knownKeys() -> [String] {
        locked { Array(Set(liveHosts().map { $0.placementKey } + Array(cache.keys))) }
    }

    private func freshEntry(_ key: String) -> Entry? {
        guard let entry = cache[key] else { return nil }
        return now() - entry.fetchedAt < TimeInterval(entry.placement.ttlSeconds) ? entry : nil
    }

    private func ensure(_ keys: [String], _ done: @escaping () -> Void) {
        let stale = locked { keys.filter { freshEntry($0) == nil } }
        if stale.isEmpty { done() } else { fetchKeys(stale, force: false, done) }
    }

    private func fetchKeys(_ keys: [String], force: Bool, _ done: @escaping () -> Void) {
        var pending = 0
        var scheduleBatch = false
        locked {
            let t = now()
            var waiters: [String] = []
            for key in keys {
                if inflight[key] != nil {
                    waiters.append(key)
                    if force { deferLocked(key) }
                    continue
                }
                if let last = lastNetworkAt[key], t - last < TimeInterval(Placements.PLACEMENT_MIN_REFRESH_SECONDS) {
                    if force { deferLocked(key) }
                    continue
                }
                batchKeys.append(key)
                inflight[key] = []
                waiters.append(key)
            }
            pending = waiters.count
            if pending > 0 {
                var left = pending
                let countDown: () -> Void = { [weak self] in
                    let fire: Bool = self?.locked { left -= 1; return left == 0 } ?? false
                    if fire { done() }
                }
                for key in waiters { inflight[key]?.append(countDown) }
            }
            if !batchKeys.isEmpty && !batchScheduled {
                batchScheduled = true
                scheduleBatch = true
            }
        }
        if scheduleBatch {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Placements.PLACEMENT_BATCH_WINDOW_MS) * 1_000_000)
                await self?.flushBatch()
            }
        }
        if pending == 0 { done() }
    }

    /// Called with the lock held.
    private func deferLocked(_ key: String) {
        if !deferredKeys.contains(key) { deferredKeys.append(key) }
        if deferredScheduled { return }
        deferredScheduled = true
        let oldest = deferredKeys.map { lastNetworkAt[$0] ?? 0 }.min() ?? 0
        let wait = max(0, oldest + TimeInterval(Placements.PLACEMENT_MIN_REFRESH_SECONDS) - now()) + 0.01
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self else { return }
            let keys: [String] = self.locked {
                self.deferredScheduled = false
                let k = self.deferredKeys
                self.deferredKeys.removeAll()
                return k
            }
            if !keys.isEmpty { self.fetchKeys(keys, force: false) {} }
        }
    }

    private func flushBatch() async {
        let keys: [String] = locked {
            batchScheduled = false
            let k = batchKeys
            batchKeys.removeAll()
            return k
        }
        var start = 0
        while start < keys.count {
            let chunk = Array(keys[start..<min(keys.count, start + Placements.PLACEMENT_MAX_KEYS_PER_REQUEST)])
            await request(chunk)
            start += Placements.PLACEMENT_MAX_KEYS_PER_REQUEST
        }
        let callbacks: [() -> Void] = locked { keys.flatMap { inflight.removeValue(forKey: $0) ?? [] } }
        callbacks.forEach { $0() }
    }

    private func request(_ keys: [String], recheckEvent: [String: Any]? = nil) async {
        guard let consentNow = consent() else { return }
        let personal = consentNow == "granted"
        let (generationAtStart, seq, shown, sentAt): (Int, Int, [String: [String]], TimeInterval) = locked {
            requestSeq += 1
            let t = now()
            for key in keys { lastNetworkAt[key] = t }
            var shown: [String: [String]] = [:]
            for host in liveHosts() where keys.contains(host.placementKey) {
                let ids = host.shownIds()
                if !ids.isEmpty { shown[host.placementKey] = ids }
            }
            return (generation, requestSeq, shown, t)
        }
        var body: [String: Any] = [
            "deviceType": "ios",
            "capabilities": capabilities(),
            "trackingConsent": consentNow,
            "placements": keys,
            "shown": shown,
            "context": ["screen": NSNull(), "url": NSNull()],
        ]
        if let locale = Locale.preferredLanguages.first { body["locale"] = locale }
        if personal {
            if let user = userId(), !user.isEmpty { body["userId"] = user }
            body["anonymousId"] = anonymousId()
            if let session = sessionId() { body["sessionId"] = session }
        }
        // A Show when re-check: the event that triggered it, counted by the server as arriving now.
        if let recheckEvent, JSONSerialization.isValidJSONObject(recheckEvent) { body["recheckEvent"] = recheckEvent }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let (status, answer) = await transport.fetchPlacements(data)
        if status == 0 || status >= 500 {
            // No answer or a server error: the keys may go again after
            // PLACEMENT_RETRY_AFTER_FAILURE_SECONDS, not the whole refresh window
            // (1.4.0-beta.12). A 429 or another 4xx keeps the window.
            locked {
                let retryAt = sentAt - TimeInterval(Placements.PLACEMENT_MIN_REFRESH_SECONDS - Placements.PLACEMENT_RETRY_AFTER_FAILURE_SECONDS)
                for key in keys where lastNetworkAt[key] == sentAt { lastNetworkAt[key] = retryAt }
            }
            return
        }
        guard (200...299).contains(status), let answer,
              let root = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any] else { return }
        if (root["success"] as? Bool) == false { return }
        guard let placements = root["placements"] as? [String: Any] else { return }
        var changed: [String] = []
        let applied: Bool = locked {
            guard generation == generationAtStart else { return false }
            let fetchedAt = now()
            for key in keys {
                // An answer to an older request that arrived after a newer one: not applied.
                if let applied = appliedSeq[key], applied > seq { continue }
                appliedSeq[key] = seq
                // A key the server left out is an empty placement, never an error.
                let json = (placements[key] as? [String: Any]) ?? ["placementKey": key, "items": []]
                let wire = PlacementWire(key: key, json)
                let before = cache[key]
                cache[key] = Entry(placement: wire, fetchedAt: fetchedAt)
                dismissedLocally = dismissedLocally.filter { !$0.hasPrefix("\(key)\u{0}") }
                if before == nil || !NSDictionary(dictionary: before!.placement.json).isEqual(to: json) { changed.append(key) }
            }
            // A moment already reached (an event earlier in the visit, seconds already spent) shows at once.
            for key in updateMomentsLocked() where !changed.contains(key) { changed.append(key) }
            return true
        }
        guard applied else { return }
        persistCache()
        if !changed.isEmpty { applyChanged(changed) }
        reportDueDeferredControls()
        scheduleMomentTimer()
    }

    private func applyChanged(_ keys: [String]) {
        let update = Dictionary(uniqueKeysWithValues: keys.map { ($0, toPlacement($0)) })
        let (targets, ls): ([PlacementHost], [([String: Placement]) -> Void]) = locked {
            (liveHosts().filter { keys.contains($0.placementKey) }, Array(listeners.values))
        }
        onMain {
            for host in targets { if let p = update[host.placementKey] { host.onPlacementUpdated(p) } }
            for l in ls { l(update) }
        }
    }

    // MARK: - Eligibility now

    private func handle(_ key: String, _ item: PlacementItemWire) -> String {
        "\(key)\u{0}\(item.deliveryToken ?? item.id)"
    }

    private func visibleItems(_ key: String) -> [PlacementItemWire] {
        locked {
            guard let entry = cache[key] else { return [] }
            let t = now()
            let items = entry.placement.items.filter { item in
                if let expires = item.expiresAt.flatMap(Self.parseIso), expires <= t { return false }
                if dismissedLocally.contains(handle(key, item)) { return false }
                // Show when: held until its moment on this screen.
                if !itemOpenLocked(key, item) { return false }
                if item.triggers.contains(where: { ($0["type"] as? String) == "event" }) {
                    guard let at = triggeredAt[handle(key, item)] else { return false }
                    let window = TimeInterval(item.triggerWindowSeconds ?? Placements.PLACEMENT_DEFAULT_TRIGGER_WINDOW_SECONDS)
                    if t - at > window { return false }
                }
                return true
            }
            return Array(items.prefix(entry.placement.maxItems))
        }
    }

    func toPlacement(_ key: String) -> Placement {
        let (cached, gen) = locked { (cache[key]?.placement, generation) }
        let wire = cached ?? PlacementWire(key: key, [:])
        let items = visibleItems(key).map { PlacementItem(placementKey: key, wire: $0, reporter: self, generation: gen) }
        return Placement(placementKey: key, items: items, isControl: wire.isControl, emptyBehavior: wire.emptyBehavior, maxItems: wire.maxItems, ttlSeconds: wire.ttlSeconds, reporter: self, generation: gen)
    }

    // MARK: - Reporting

    private static let genericElementIds: Set<String> = ["click", "clicked", "button", "link", "cta_click", "link_click", "button_click"]

    /// A transition to /v1/in-app/track: only with consent. `displayed` and `dismissed` once per
    /// delivery; a click or dismissal first counts the item as displayed.
    func report(_ generation: Int, _ key: String, _ item: PlacementItemWire, _ type: String, _ elementId: String?) {
        // Served for someone who is no longer here (identify / reset since): nothing.
        guard locked({ generation == self.generation }) else { return }
        guard consent() == "granted" else { return }
        if type == "displayed" {
            // An impression counts only when the content is shown: never while held (Show when).
            guard locked({ itemOpenLocked(key, item) }) else { return }
            _ = locked { viewedOnScreen.insert(key) }
            reportDueDeferredControls()
        }
        if type != "clicked" {
            let first = locked { reported.insert("\(type):\(handle(key, item))").inserted }
            if !first { return }
        }
        if type != "displayed" { report(generation, key, item, "displayed", nil) }
        let at = Self.iso(now())
        var body: [String: Any] = [
            "campaignId": item.id,
            "placementKey": key,
            "deviceType": "ios",
            "action": type,
        ]
        if let v = item.variantId { body["variantId"] = v }
        if let t = item.deliveryToken { body["deliveryToken"] = t }
        subject(&body)
        switch type {
        case "displayed": body["displayedAt"] = at
        case "clicked":
            body["clicked"] = true
            body["clickedAt"] = at
            if let e = elementId?.trimmingCharacters(in: .whitespaces), !e.isEmpty, !Self.genericElementIds.contains(e.lowercased()) {
                body["elementId"] = String(e.prefix(128))
            }
        case "dismissed": body["dismissedAt"] = at
        default: break
        }
        send(body)
    }

    func dismiss(_ generation: Int, _ key: String, _ item: PlacementItemWire) {
        guard locked({ generation == self.generation }) else { return }
        report(generation, key, item, "dismissed", nil)
        _ = locked { dismissedLocally.insert(handle(key, item)) }
        applyChanged([key])
    }

    /// A held-out person's empty spot was viewable: `in_app.control_viewed`, once per control token.
    /// With a Show when, not before the moment the treatment would have been revealed (ignored before it;
    /// onPlacementsUpdated fires at the moment). On any placement it also counts as "the spot was viewable"
    /// for the answer's deferred controls.
    func reportControl(_ generation: Int, _ key: String) {
        guard locked({ generation == self.generation }) else { return }
        _ = locked { viewedOnScreen.insert(key) }
        reportDueDeferredControls()
        let token: String? = locked {
            guard let p = cache[key]?.placement, p.isControl, let token = p.controlToken, controlOpenLocked(key, p) else { return nil }
            return token
        }
        guard let token else { return }
        guard consent() == "granted" else { return }
        guard locked({ reported.insert("control:\(token)").inserted }) else { return }
        sendControlViewed(token, key)
    }

    /// The exact body of every `control_viewed` report.
    private func sendControlViewed(_ token: String, _ key: String) {
        var body: [String: Any] = [
            "action": "control_viewed",
            "controlToken": token,
            "placementKey": key,
            "deviceType": "ios",
            "viewedAt": Self.iso(now()),
        ]
        subject(&body)
        send(body)
    }

    /// Deferred controls whose moment has come on a spot viewable on this screen: each once, with consent.
    private func reportDueDeferredControls() {
        guard consent() == "granted" else { return }
        let due: [(String, String)] = locked {
            var out: [(String, String)] = []
            for key in viewedOnScreen {
                guard let p = cache[key]?.placement else { continue }
                for d in p.deferredControls where momentOpenLocked(d.showWhen, MomentId(kind: .deferred, key: key, token: d.controlToken)) {
                    if reported.insert("control:\(d.controlToken)").inserted { out.append((d.controlToken, key)) }
                }
            }
            return out
        }
        for (token, key) in due { sendControlViewed(token, key) }
    }

    // MARK: - Show when (D465)

    private func itemMoment(_ key: String, _ item: PlacementItemWire) -> MomentId {
        MomentId(kind: .item, key: key, token: item.deliveryToken ?? item.id)
    }

    private func controlMoment(_ key: String, _ p: PlacementWire) -> MomentId {
        MomentId(kind: .control, key: key, token: p.controlToken ?? "")
    }

    /// Lock held. `load` always; otherwise once reached on this screen.
    private func momentOpenLocked(_ moment: ShowWhenMoment, _ id: MomentId) -> Bool {
        moment == .load || revealed.contains(id)
    }

    private func itemOpenLocked(_ key: String, _ item: PlacementItemWire) -> Bool {
        momentOpenLocked(item.showWhen, itemMoment(key, item))
    }

    private func controlOpenLocked(_ key: String, _ p: PlacementWire) -> Bool {
        momentOpenLocked(p.showWhen, controlMoment(key, p))
    }

    /// Lock held. The visit's event names, started over when the SDK session changed.
    private func visitEventsLocked() {
        let id = sessionId()
        if id != sessionEventsId {
            sessionEventsId = id
            sessionEvents.removeAll()
        }
    }

    /// Lock held. Has this moment come on the current screen?
    private func reachedLocked(_ moment: ShowWhenMoment) -> Bool {
        switch moment {
        case .load: return true
        case .seconds(let n): return screenClock.seconds + 0.001 >= n
        case .event(let e):
            visitEventsLocked()
            return sessionEvents.contains(e)
        case .never: return false
        }
    }

    /// Lock held. Marks every moment reached now; returns the keys whose Placement changed
    /// (an item revealed, a control answer's moment came).
    @discardableResult
    private func updateMomentsLocked() -> [String] {
        var changed: [String] = []
        for (key, entry) in cache {
            let p = entry.placement
            var ids: [(MomentId, ShowWhenMoment)] = p.items.filter { $0.showWhen != .load }.map { (itemMoment(key, $0), $0.showWhen) }
            if p.isControl, p.showWhen != .load { ids.append((controlMoment(key, p), p.showWhen)) }
            ids += p.deferredControls.filter { $0.showWhen != .load }.map { (MomentId(kind: .deferred, key: key, token: $0.controlToken), $0.showWhen) }
            for (id, moment) in ids where !revealed.contains(id) && reachedLocked(moment) {
                revealed.insert(id)
                if id.kind != .deferred && !changed.contains(key) { changed.append(key) }
            }
        }
        return changed
    }

    /// The seconds moments' timer fired (tests call it directly).
    func checkShowWhen() {
        let changed = locked { updateMomentsLocked() }
        if !changed.isEmpty { applyChanged(changed) }
        reportDueDeferredControls()
        scheduleMomentTimer()
    }

    /// A new screen: every moment starts again (content revealed by a non-load moment is held
    /// again until the new screen's moment; an event of this visit still counts at once).
    private func screenChanged() {
        let changed: [String] = locked {
            let before = revealed
            revealed.removeAll()
            viewedOnScreen.removeAll()
            rechecked.removeAll()
            pendingRechecks.removeAll()
            updateMomentsLocked()
            var keys: [String] = []
            for id in before.symmetricDifference(revealed) where id.kind != .deferred && !keys.contains(id.key) { keys.append(id.key) }
            return keys
        }
        if !changed.isEmpty { applyChanged(changed) }
        scheduleMomentTimer()
    }

    private func stopMomentTimer() {
        let cancel: (() -> Void)? = locked {
            defer { cancelMomentTimer = nil }
            return cancelMomentTimer
        }
        cancel?()
    }

    /// One timer for the nearest `seconds` moment not reached yet (none while in the background).
    private func scheduleMomentTimer() {
        stopMomentTimer()
        let wait: TimeInterval? = locked {
            guard screenClock.isVisible else { return nil }
            let elapsed = screenClock.seconds
            var next: TimeInterval?
            for (key, entry) in cache {
                let p = entry.placement
                var pending: [(MomentId, ShowWhenMoment)] = p.items.map { (itemMoment(key, $0), $0.showWhen) }
                if p.isControl { pending.append((controlMoment(key, p), p.showWhen)) }
                pending += p.deferredControls.map { (MomentId(kind: .deferred, key: key, token: $0.controlToken), $0.showWhen) }
                for (id, moment) in pending where !revealed.contains(id) {
                    guard case .seconds(let n) = moment else { continue }
                    let w = max(0, n - elapsed)
                    next = min(next ?? w, w)
                }
            }
            return next
        }
        guard let wait else { return }
        let cancel = schedule(wait + 0.05) { [weak self] in self?.checkShowWhen() }
        locked { cancelMomentTimer = cancel }
    }

    private func subject(_ body: inout [String: Any]) {
        if let user = userId(), !user.isEmpty { body["userId"] = user }
        body["anonymousId"] = anonymousId()
        if let session = sessionId() { body["sessionId"] = session }
    }

    private func send(_ body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        Task { [transport] in await transport.trackPlacement(data) }
    }

    // MARK: - Disk cache

    private func subjectKey() -> String { "\(userId() ?? "")|\(anonymousId())" }

    private func loadCache() {
        guard let raw = load(), let data = raw.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["subject"] as? String) == subjectKey(),   // another person's answers are not this one's
              let entries = root["entries"] as? [String: [String: Any]] else { return }
        for (key, e) in entries {
            guard Self.validKey(key), let p = e["placement"] as? [String: Any], let at = (e["fetchedAt"] as? NSNumber)?.doubleValue else { continue }
            cache[key] = Entry(placement: PlacementWire(key: key, p), fetchedAt: at)
        }
    }

    private func persistCache() {
        let root: [String: Any] = locked {
            var entries: [String: Any] = [:]
            for (key, entry) in cache { entries[key] = ["placement": entry.placement.json, "fetchedAt": entry.fetchedAt] }
            return ["subject": subjectKey(), "entries": entries]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root), let text = String(data: data, encoding: .utf8) else { return }
        save(text)
    }

    // MARK: - Helpers

    /// A trigger's own property condition; an unknown operator does not match (fails closed).
    static func triggerMatches(_ trigger: [String: Any], _ properties: [String: Any]) -> Bool {
        guard let attribute = trigger["attribute"] as? String else { return true }
        let actual = properties[attribute]
        let expected = trigger["value"]
        func num(_ v: Any?) -> Double {
            if let n = v as? NSNumber { return n.doubleValue }
            if let s = v as? String { return Double(s) ?? .nan }
            return .nan
        }
        func same(_ a: Any?, _ b: Any?) -> Bool {
            if let a = a as? NSNumber, let b = b as? NSNumber { return a.doubleValue == b.doubleValue }
            if let a = a as? String, let b = b as? String { return a == b }
            if let a = a as? Bool, let b = b as? Bool { return a == b }
            return a == nil && b == nil
        }
        switch trigger["operator"] as? String {
        case nil, "equals", "eq": return same(actual, expected)
        case "not_equals", "neq": return !same(actual, expected)
        case "greater_than", "gt": return num(actual) > num(expected)
        case "less_than", "lt": return num(actual) < num(expected)
        case "contains": return "\(actual ?? "")".contains("\(expected ?? "")")
        case "exists": return actual != nil && !(actual is NSNull)
        default: return false
        }
    }

    static func iso(_ t: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    static func parseIso(_ s: String) -> TimeInterval? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)?.timeIntervalSince1970
    }
}
