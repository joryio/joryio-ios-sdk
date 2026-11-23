import Foundation

/// The HTTP the manager needs; NetworkClient in the app, a fake in tests.
protocol CardTransport: AnyObject {
    /// POST /v1/in-app/cards once (no retries): HTTP status (0 = no answer) and body.
    func fetchCards(_ body: Data) async -> (Int, Data?)
    /// POST /v1/in-app/track.
    func trackCard(_ body: Data) async
}

/**
 Fetches, caches and refreshes the person's card feed and reports what they did
 with each card (docs/PLACEMENTS_PLAN.md section 11), by the rules every Joryio
 SDK shares:

 - the last feed is served from the cache (memory + disk, scoped to the
   person) for its `ttlSeconds` (`Cards.CARD_FEED_TTL_SECONDS`);
 - at most one network refresh per `Cards.CARD_MIN_REFRESH_SECONDS`: a forced
   refresh inside that window is deferred to its end and coalesced;
 - `notModified: true`, `success: false`, HTTP 429 or no answer keep the cache;
 - an identity or consent change bumps a generation: an answer to a request
   made before it is discarded; identity changes also clear the anonymous
   visitor's device state;
 - a report is applied to the cache at once and listeners are told;
 - `stateScope: "device"` (an anonymous visitor): read / dismissed card ids
   are kept on the device and applied to every feed;
 - without tracking consent nothing is requested and nothing reported (an
   inbox is personal: the server answers an unconsented device an empty feed).
 */
final class CardManager {
    static let pageSize = 20
    /// Read / dismissed ids an anonymous device keeps (oldest dropped first).
    static let deviceStateMax = 500

    private final class Inflight {
        var callbacks: [() -> Void]
        init(_ first: @escaping () -> Void) { callbacks = [first] }
    }

    private let transport: CardTransport
    private let loadFeed: () -> String?
    private let saveFeed: (String?) -> Void
    private let loadDevice: () -> String?
    private let saveDevice: (String?) -> Void
    /// nil = nothing may be sent; "granted" | "pending" | "denied" otherwise.
    private let consent: () -> String?
    private let userId: () -> String?
    private let anonymousId: () -> String
    private let sessionId: () -> String?
    private let capabilities: () -> [String]
    private let now: () -> TimeInterval
    private let onMain: (@escaping () -> Void) -> Void

    private let lock = NSLock()
    private var wireCards: [Card] = []
    private var serverUnread = 0
    private var nextCursor: String?
    private var stateScope = Cards.StateScope.server
    private var etag: String?
    private var ttlSeconds = Cards.CARD_FEED_TTL_SECONDS
    private var fetchedAt: TimeInterval?
    private var lastNetworkAt: TimeInterval?
    private var inflight: Inflight?
    private var deferredScheduled = false
    private var listeners: [UUID: (CardFeed) -> Void] = [:]
    private var reported = Set<String>()
    /// What this device did since the last identity change, keyed by card id + createdAt (a replaced card is a new one).
    private var overlayRead = Set<String>()
    private var overlayClicked = Set<String>()
    private var overlayDismissed = Set<String>()
    /// An anonymous visitor's state, by card id, on disk (in order, oldest first). Cleared on identify / reset.
    private var deviceRead: [String] = []
    private var deviceDismissed: [String] = []
    /// The app reads cards (or did on an earlier launch): foreground refreshes are worth a request.
    private var used = false
    private var generation = 0

    init(
        transport: CardTransport,
        loadFeed: @escaping () -> String?,
        saveFeed: @escaping (String?) -> Void,
        loadDevice: @escaping () -> String?,
        saveDevice: @escaping (String?) -> Void,
        consent: @escaping () -> String?,
        userId: @escaping () -> String?,
        anonymousId: @escaping () -> String,
        sessionId: @escaping () -> String?,
        capabilities: @escaping () -> [String],
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        onMain: @escaping (@escaping () -> Void) -> Void = { block in DispatchQueue.main.async(execute: block) }
    ) {
        self.transport = transport
        self.loadFeed = loadFeed
        self.saveFeed = saveFeed
        self.loadDevice = loadDevice
        self.saveDevice = saveDevice
        self.consent = consent
        self.userId = userId
        self.anonymousId = anonymousId
        self.sessionId = sessionId
        self.capabilities = capabilities
        self.now = now
        self.onMain = onMain
        loadFeedCache()
        loadDeviceState()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Surface (through Joryio)

    func getCards(cursor: String?, completion: @escaping (CardFeed) -> Void) {
        locked { used = true }
        if let cursor {
            Task { [weak self] in
                guard let self else { return }
                let page = await self.loadPage(cursor)
                self.onMain { completion(page) }
            }
            return
        }
        ensure { [weak self] in
            guard let self else { return }
            let feed = self.view()
            self.onMain { completion(feed) }
        }
    }

    func getCards(cursor: String? = nil) async -> CardFeed {
        locked { used = true }
        if let cursor { return await loadPage(cursor) }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            ensure { cont.resume() }
        }
        return view()
    }

    /// From the cache, never the network.
    func getUnreadCardCount() -> Int {
        locked { used = true }
        return view().unreadCount
    }

    func refreshCards() {
        locked { used = true }
        fetch(force: true) {}
    }

    func onCardsUpdated(_ listener: @escaping (CardFeed) -> Void) -> JoryioSubscription {
        let id = UUID()
        locked {
            used = true
            listeners[id] = listener
        }
        return JoryioSubscription { [weak self] in
            self?.locked { self?.listeners[id] = nil }
        }
    }

    func markCardViewed(_ cardId: String, token: String? = nil) { report(cardId, token, Cards.Action.viewed) }
    func markCardRead(_ cardId: String, token: String? = nil) { report(cardId, token, Cards.Action.read) }
    func markCardClicked(_ cardId: String, token: String? = nil) { report(cardId, token, Cards.Action.clicked) }
    func dismissCard(_ cardId: String, token: String? = nil) { report(cardId, token, Cards.Action.dismissed) }

    /// The app came to the foreground: a feed the app reads whose TTL passed is asked for again.
    func onForeground() {
        let stale = locked { (used || fetchedAt != nil) && !freshLocked() }
        if stale { fetch(force: false) {} }
    }

    /// The silent push `jry_sync: "cards"`: a card was added for this person.
    func onSyncPush() { refreshCards() }

    /// The person or the consent changed: forget the feed (and, for a new
    /// person, the anonymous visitor's device state), tell the listeners, and
    /// ask again if the app is showing cards.
    func invalidate(clearDeviceState: Bool) {
        let ls: [(CardFeed) -> Void] = locked {
            generation += 1
            wireCards = []
            serverUnread = 0
            nextCursor = nil
            stateScope = Cards.StateScope.server
            etag = nil
            ttlSeconds = Cards.CARD_FEED_TTL_SECONDS
            fetchedAt = nil
            lastNetworkAt = nil
            inflight = nil
            reported.removeAll()
            overlayRead.removeAll()
            overlayClicked.removeAll()
            overlayDismissed.removeAll()
            if clearDeviceState {
                deviceRead.removeAll()
                deviceDismissed.removeAll()
            }
            return Array(listeners.values)
        }
        saveFeed(nil)
        if clearDeviceState { saveDevice(nil) }
        if !ls.isEmpty {
            let feed = view()
            onMain { ls.forEach { $0(feed) } }
            fetch(force: true) {}
        }
    }

    // MARK: - Fetching

    /// Called with the lock held.
    private func freshLocked() -> Bool {
        guard let at = fetchedAt else { return false }
        return now() - at < TimeInterval(ttlSeconds)
    }

    private func ensure(_ done: @escaping () -> Void) {
        if locked({ freshLocked() }) { done() } else { fetch(force: false, done) }
    }

    /// Ask for the first page. A request already running is joined; inside
    /// `CARD_MIN_REFRESH_SECONDS` of the last one nothing goes out - a forced
    /// refresh is deferred to the end of that window, anything else gets the cache.
    private func fetch(force: Bool, _ done: @escaping () -> Void) {
        enum Next { case joined, cache, start(Inflight) }
        let next: Next = locked {
            if let running = inflight {
                running.callbacks.append(done)
                if force { deferLocked() }
                return .joined
            }
            if let last = lastNetworkAt, now() - last < TimeInterval(Cards.CARD_MIN_REFRESH_SECONDS) {
                if force { deferLocked() }
                return .cache
            }
            let created = Inflight(done)
            inflight = created
            return .start(created)
        }
        switch next {
        case .joined: return
        case .cache: done()
        case .start(let mine):
            Task { [weak self] in
                await self?.requestFirstPage()
                let callbacks: [() -> Void] = self?.locked {
                    if self?.inflight === mine { self?.inflight = nil }
                    return mine.callbacks
                } ?? mine.callbacks
                callbacks.forEach { $0() }
            }
        }
    }

    /// Called with the lock held.
    private func deferLocked() {
        if deferredScheduled { return }
        deferredScheduled = true
        let wait = max(0, (lastNetworkAt ?? 0) + TimeInterval(Cards.CARD_MIN_REFRESH_SECONDS) - now()) + 0.01
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self else { return }
            self.locked { self.deferredScheduled = false }
            self.fetch(force: false) {}
        }
    }

    /// One POST; nil when there is nothing to use (no consent, failure, 429, success false, a stale answer).
    private func post(cursor: String?) async -> ([String: Any], Int)? {
        guard let consentNow = consent() else { return nil }
        // An inbox is personal: without consent the server would answer an
        // empty feed, so nothing is asked (and nobody named).
        guard consentNow == "granted" else { return nil }
        let (generationAtStart, sentEtag): (Int, String?) = locked {
            if cursor == nil { lastNetworkAt = now() }
            return (generation, cursor == nil ? etag : nil)
        }
        var body: [String: Any] = [
            "anonymousId": anonymousId(),
            "deviceType": "ios",
            "capabilities": capabilities(),
            "trackingConsent": consentNow,
            "limit": Self.pageSize,
        ]
        if let user = userId(), !user.isEmpty { body["userId"] = user }
        if let session = sessionId() { body["sessionId"] = session }
        if let locale = Locale.preferredLanguages.first { body["locale"] = locale }
        if let cursor { body["cursor"] = cursor }
        if let sentEtag, !sentEtag.isEmpty { body["etag"] = sentEtag }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        let (status, answer) = await transport.fetchCards(data)
        guard (200...299).contains(status), let answer else { return nil }
        guard locked({ generation == generationAtStart }) else { return nil }
        guard let root = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any] else { return nil }
        if (root["success"] as? Bool) == false { return nil }
        return (root, generationAtStart)
    }

    private func requestFirstPage() async {
        guard let (root, gen) = await post(cursor: nil) else { return }
        let outcome: (changed: Bool, listeners: [(CardFeed) -> Void])? = locked {
            guard generation == gen else { return nil }
            let t = now()
            let ttl = (root["ttlSeconds"] as? NSNumber)?.intValue ?? Cards.CARD_FEED_TTL_SECONDS
            ttlSeconds = ttl > 0 ? ttl : Cards.CARD_FEED_TTL_SECONDS
            if (root["notModified"] as? Bool) == true, fetchedAt != nil {
                // The feed we hold is still the feed: keep the cards.
                fetchedAt = t
                return (false, Array(listeners.values))
            }
            let before = viewLocked()
            wireCards = Self.parseCards(root)
            serverUnread = max(0, (root["unreadCount"] as? NSNumber)?.intValue ?? 0)
            nextCursor = root["nextCursor"] as? String
            stateScope = (root["stateScope"] as? String) == Cards.StateScope.device ? Cards.StateScope.device : Cards.StateScope.server
            etag = root["etag"] as? String
            fetchedAt = t
            return (before != viewLocked(), Array(listeners.values))
        }
        guard let outcome else { return }
        persistFeed()
        if outcome.changed, !outcome.listeners.isEmpty { notify(outcome.listeners) }
    }

    /// The page after `cursor`: added to the cached feed; returns that page (with this device's state applied).
    private func loadPage(_ cursor: String) async -> CardFeed {
        func emptyPage() -> CardFeed {
            let v = view()
            return CardFeed(cards: [], unreadCount: v.unreadCount, nextCursor: v.nextCursor, stateScope: v.stateScope)
        }
        guard let (root, gen) = await post(cursor: cursor) else { return emptyPage() }
        let result: (CardFeed, [(CardFeed) -> Void])? = locked {
            guard generation == gen else { return nil }
            let cards = Self.parseCards(root)
            let known = Set(wireCards.map { $0.id })
            wireCards += cards.filter { !known.contains($0.id) }
            nextCursor = root["nextCursor"] as? String
            if let n = (root["unreadCount"] as? NSNumber)?.intValue { serverUnread = max(0, n) }
            let full = viewLocked()
            let ids = Set(cards.map { $0.id })
            let page = CardFeed(cards: full.cards.filter { ids.contains($0.id) }, unreadCount: full.unreadCount, nextCursor: full.nextCursor, stateScope: full.stateScope)
            return (page, Array(listeners.values))
        }
        guard let (page, ls) = result else { return emptyPage() }
        if !ls.isEmpty { notify(ls) }
        return page
    }

    private func notify(_ ls: [(CardFeed) -> Void]) {
        let feed = view()
        onMain { ls.forEach { $0(feed) } }
    }

    // MARK: - The feed with this device's state

    private func overlayKey(_ c: Card) -> String { "\(c.id)\u{0}\(c.createdAt)" }

    func view() -> CardFeed { locked { viewLocked() } }

    /// The cached feed with what this device did applied: dismissed and
    /// expired cards removed, read / clicked set, and the unread count lowered
    /// by each card the server counted as unread that is no longer.
    private func viewLocked() -> CardFeed {
        let t = now()
        var unread = serverUnread
        var out: [Card] = []
        for c in wireCards {
            let key = overlayKey(c)
            let dismissed = overlayDismissed.contains(key) || deviceDismissed.contains(c.id)
            let expired = c.expiresAt.flatMap(PlacementManager.parseIso).map { $0 <= t } ?? false
            let clicked = c.clicked || overlayClicked.contains(key)
            let read = c.read || clicked || overlayRead.contains(key) || deviceRead.contains(c.id)
            if !c.read, read || dismissed || expired { unread -= 1 }
            if dismissed || expired { continue }
            out.append(read == c.read && clicked == c.clicked ? c : c.with(read: read, clicked: clicked))
        }
        return CardFeed(cards: out, unreadCount: max(0, unread), nextCursor: nextCursor, stateScope: stateScope)
    }

    // MARK: - Reporting

    /// A report: applied to the cache at once (listeners told), sent to
    /// /v1/in-app/track only with consent. Each action at most once per card;
    /// read / clicked / dismissed first count the card as viewed; `read` on a
    /// card already read sends nothing.
    private func report(_ cardId: String, _ token: String?, _ action: String) {
        let outcome: (card: Card, send: [String], listeners: [(CardFeed) -> Void], deviceChanged: Bool)? = locked {
            // A card of someone who is no longer here (identify / reset since), or unknown: nothing.
            guard let card = wireCards.first(where: { $0.id == cardId }), token == nil || token == card.deliveryToken else { return nil }
            let key = overlayKey(card)
            let alreadyRead = card.read || card.clicked || overlayRead.contains(key) || overlayClicked.contains(key) || deviceRead.contains(card.id)
            if action == Cards.Action.read, alreadyRead {
                reported.insert("\(Cards.Action.read):\(card.id)")
                return nil
            }
            guard reported.insert("\(action):\(card.id)").inserted else { return nil }
            var send: [String] = []
            if action != Cards.Action.viewed, reported.insert("\(Cards.Action.viewed):\(card.id)").inserted { send.append(Cards.Action.viewed) }
            send.append(action)
            let device = stateScope == Cards.StateScope.device
            var deviceChanged = false
            switch action {
            case Cards.Action.read:
                overlayRead.insert(key)
                if device, !deviceRead.contains(card.id) { deviceRead.append(card.id); deviceChanged = true }
            case Cards.Action.clicked:
                overlayClicked.insert(key)
                overlayRead.insert(key)
                reported.insert("\(Cards.Action.read):\(card.id)")
                if device, !deviceRead.contains(card.id) { deviceRead.append(card.id); deviceChanged = true }
            case Cards.Action.dismissed:
                overlayDismissed.insert(key)
                if device, !deviceDismissed.contains(card.id) { deviceDismissed.append(card.id); deviceChanged = true }
            default:
                break
            }
            return (card, send, action == Cards.Action.viewed ? [] : Array(listeners.values), deviceChanged)
        }
        guard let outcome else { return }
        if outcome.deviceChanged { persistDeviceState() }
        if !outcome.listeners.isEmpty { notify(outcome.listeners) }
        guard consent() == "granted" else { return }
        let session = sessionId()
        let bodies: [Data] = outcome.send.compactMap { a in
            var body: [String: Any] = ["deliveryToken": outcome.card.deliveryToken, "action": a]
            if let session { body["sessionId"] = session }
            return try? JSONSerialization.data(withJSONObject: body)
        }
        guard !bodies.isEmpty else { return }
        // Reports reach the server in the order they were made - `viewed`
        // before the `read` / `dismissed` it implies, across calls too: each
        // report's task waits for the one before it.
        reportLock.lock()
        let previous = lastReport
        lastReport = Task { [transport] in
            await previous?.value
            for data in bodies { await transport.trackCard(data) }
        }
        reportLock.unlock()
    }

    /// The last report on its way: the next one waits for it.
    private var lastReport: Task<Void, Never>?
    private let reportLock = NSLock()

    // MARK: - Parsing + disk

    static func parseCards(_ root: [String: Any]) -> [Card] {
        ((root["cards"] as? [[String: Any]]) ?? []).compactMap { Card($0) }
    }

    private func subjectKey() -> String { "\(userId() ?? "")|\(anonymousId())" }

    /// A JSON value or NSNull. Taking `Any?` keeps every Swift version from
    /// warning about an Optional implicitly coerced to Any (pod lib lint fails on warnings).
    private static func jsonOrNull(_ value: Any?) -> Any { value ?? NSNull() }

    private func persistFeed() {
        let root: [String: Any] = locked {
            [
                "subject": subjectKey(),
                "fetchedAt": fetchedAt ?? 0,
                "etag": Self.jsonOrNull(etag),
                "ttlSeconds": ttlSeconds,
                "unreadCount": serverUnread,
                "nextCursor": Self.jsonOrNull(nextCursor),
                "stateScope": stateScope,
                "cards": wireCards.map { $0.wireJson() },
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root), let text = String(data: data, encoding: .utf8) else { return }
        saveFeed(text)
    }

    private func loadFeedCache() {
        guard let raw = loadFeed(), let data = raw.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["subject"] as? String) == subjectKey()   // another person's feed is not this one's
        else { return }
        wireCards = Self.parseCards(root)
        serverUnread = (root["unreadCount"] as? NSNumber)?.intValue ?? 0
        nextCursor = root["nextCursor"] as? String
        stateScope = (root["stateScope"] as? String) == Cards.StateScope.device ? Cards.StateScope.device : Cards.StateScope.server
        etag = root["etag"] as? String
        let ttl = (root["ttlSeconds"] as? NSNumber)?.intValue ?? Cards.CARD_FEED_TTL_SECONDS
        ttlSeconds = ttl > 0 ? ttl : Cards.CARD_FEED_TTL_SECONDS
        fetchedAt = (root["fetchedAt"] as? NSNumber)?.doubleValue
    }

    private func persistDeviceState() {
        let root: [String: Any] = locked {
            if deviceRead.count > Self.deviceStateMax { deviceRead.removeFirst(deviceRead.count - Self.deviceStateMax) }
            if deviceDismissed.count > Self.deviceStateMax { deviceDismissed.removeFirst(deviceDismissed.count - Self.deviceStateMax) }
            return ["anonymousId": anonymousId(), "read": deviceRead, "dismissed": deviceDismissed]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root), let text = String(data: data, encoding: .utf8) else { return }
        saveDevice(text)
    }

    private func loadDeviceState() {
        guard let raw = loadDevice(), let data = raw.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["anonymousId"] as? String) == anonymousId()   // kept for one anonymous visitor
        else { return }
        deviceRead = (root["read"] as? [String]) ?? []
        deviceDismissed = (root["dismissed"] as? [String]) ?? []
    }
}
