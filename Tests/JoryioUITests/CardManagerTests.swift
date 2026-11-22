import XCTest
@testable import Joryio
@testable import JoryioUI

/// Content cards on iOS (docs/PLACEMENTS_PLAN.md section 11): the manager's
/// rules against a fake transport (the feed endpoint is mocked) - the same
/// rules as Android's CardManagerTest and the web SDK's card tests.
final class CardManagerTests: XCTestCase {

    private final class FakeTransport: CardTransport {
        let lock = NSLock()
        var answer: ([String: Any]) async -> (Int, Data?)
        private var _fetches: [[String: Any]] = []
        private var _tracks: [[String: Any]] = []
        init(_ answer: @escaping ([String: Any]) async -> (Int, Data?)) { self.answer = answer }
        var fetches: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _fetches }
        var tracks: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _tracks }
        func fetchCards(_ body: Data) async -> (Int, Data?) {
            let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            lock.lock(); _fetches.append(o); lock.unlock()
            return await answer(o)
        }
        func trackCard(_ body: Data) async {
            let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            lock.lock(); _tracks.append(o); lock.unlock()
        }
    }

    private var clock: TimeInterval = 1_700_000_000
    private var consentValue: String? = "granted"
    private var user: String? = "user-1"
    private var storedFeed: String?
    private var storedDevice: String?

    private func card(_ id: String, read: Bool = false, pinned: Bool = false) -> String {
        """
        {"id":"\(id)","campaignId":"camp-\(id)","variantId":"v1","title":"Title \(id)","body":"Body \(id)","imageUrl":null,
         "buttonText":"Open","url":"https://shop.example/sale","pinned":\(pinned),
         "createdAt":"2026-11-20T10:00:00.000Z","expiresAt":"2099-12-20T10:00:00.000Z",
         "read":\(read),"clicked":false,"deliveryToken":"tok-\(id)"}
        """
    }

    private func feed(_ cards: [String], unread: Int, scope: String = "server", next: String? = nil) -> (Int, Data?) {
        let nextJson = next.map { "\"\($0)\"" } ?? "null"
        let s = """
        {"success":true,"evaluatedAt":"2026-11-21T10:00:00.000Z","etag":"e1","notModified":false,
         "cards":[\(cards.joined(separator: ","))],"unreadCount":\(unread),"nextCursor":\(nextJson),
         "ttlSeconds":300,"stateScope":"\(scope)"}
        """
        return (200, s.data(using: .utf8))
    }

    private func manager(_ t: FakeTransport) -> CardManager {
        CardManager(
            transport: t,
            loadFeed: { [unowned self] in self.storedFeed },
            saveFeed: { [unowned self] in self.storedFeed = $0 },
            loadDevice: { [unowned self] in self.storedDevice },
            saveDevice: { [unowned self] in self.storedDevice = $0 },
            consent: { [unowned self] in self.consentValue },
            userId: { [unowned self] in self.user },
            anonymousId: { "anon-1" },
            sessionId: { "s-1" },
            capabilities: { ["cards", "content.native"] },
            now: { [unowned self] in self.clock },
            onMain: { $0() }
        )
    }

    private func settle(_ seconds: Double = 0.15) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// The feed and device caches are per workspace, like flags and placements
    /// (FlagsTests): the kv table is one database per app, so the keys carry
    /// the SDK key and the unscoped keys of older builds are never read.
    func testCardsStorageKeysArePerSdkKey() {
        XCTAssertEqual(Joryio.cardsStorageKey(sdkKey: "jry_live_a"), "jry_jry_live_a_cards_cache")
        XCTAssertEqual(Joryio.cardsDeviceStateStorageKey(sdkKey: "jry_live_a"), "jry_jry_live_a_cards_device_state")
        XCTAssertNotEqual(Joryio.cardsStorageKey(sdkKey: "jry_live_a"), Joryio.cardsStorageKey(sdkKey: "jry_live_b"))
        XCTAssertNotEqual(Joryio.cardsDeviceStateStorageKey(sdkKey: "jry_live_a"), Joryio.cardsDeviceStateStorageKey(sdkKey: "jry_live_b"))
        XCTAssertNotEqual(Joryio.cardsStorageKey(sdkKey: "jry_live_a"), Joryio.legacyCardsStorageKey)
        XCTAssertNotEqual(Joryio.cardsDeviceStateStorageKey(sdkKey: "jry_live_a"), Joryio.legacyCardsDeviceStateStorageKey)
        XCTAssertEqual(Joryio.legacyCardsStorageKey, "cards_cache")
        XCTAssertEqual(Joryio.legacyCardsDeviceStateStorageKey, "cards_device_state")
    }

    func testConstantsHaveTheSharedValues() {
        XCTAssertEqual(Cards.CARD_MIN_REFRESH_SECONDS, 30)
        XCTAssertEqual(Cards.CARD_FEED_TTL_SECONDS, 300)
        XCTAssertEqual(Cards.capability, "cards")
        XCTAssertEqual(Cards.syncType, "cards")
        XCTAssertEqual([Cards.Action.viewed, Cards.Action.read, Cards.Action.clicked, Cards.Action.dismissed], ["viewed", "read", "clicked", "dismissed"])
    }

    func testReadsTheFeedWithTheContractBody() async {
        let t = FakeTransport { _ in self.feed([self.card("a", pinned: true), self.card("b", read: true)], unread: 1, next: "c1") }
        let m = manager(t)
        let f = await m.getCards()
        XCTAssertEqual(t.fetches.count, 1)
        let body = t.fetches[0]
        XCTAssertEqual(body["userId"] as? String, "user-1")
        XCTAssertEqual(body["anonymousId"] as? String, "anon-1")
        XCTAssertEqual(body["sessionId"] as? String, "s-1")
        XCTAssertEqual(body["trackingConsent"] as? String, "granted")
        XCTAssertEqual(body["limit"] as? Int, 20)
        XCTAssertTrue((body["capabilities"] as? [String] ?? []).contains("cards"))
        XCTAssertNil(body["cursor"])
        XCTAssertNil(body["etag"])
        XCTAssertEqual(f.cards.map { $0.id }, ["a", "b"])
        let a = f.cards[0]
        XCTAssertEqual(a.campaignId, "camp-a")
        XCTAssertEqual(a.variantId, "v1")
        XCTAssertEqual(a.title, "Title a")
        XCTAssertEqual(a.buttonText, "Open")
        XCTAssertEqual(a.url, "https://shop.example/sale")
        XCTAssertTrue(a.pinned)
        XCTAssertFalse(a.read)
        XCTAssertEqual(f.unreadCount, 1)
        XCTAssertEqual(f.nextCursor, "c1")
        XCTAssertEqual(f.stateScope, "server")
        XCTAssertEqual(m.getUnreadCardCount(), 1)
    }

    func testNotModifiedKeepsTheCachedCardsAndSendsTheEtag() async {
        var notModified = false
        let t = FakeTransport { _ in
            if notModified {
                return (200, "{\"success\":true,\"etag\":\"e1\",\"notModified\":true,\"cards\":[],\"unreadCount\":0,\"nextCursor\":null,\"ttlSeconds\":300,\"stateScope\":\"server\"}".data(using: .utf8))
            }
            return self.feed([self.card("a")], unread: 1)
        }
        let m = manager(t)
        _ = await m.getCards()
        notModified = true
        clock += 301
        let f = await m.getCards()
        XCTAssertEqual(t.fetches.count, 2)
        XCTAssertEqual(t.fetches[1]["etag"] as? String, "e1")
        XCTAssertEqual(f.cards.map { $0.id }, ["a"])
        XCTAssertEqual(f.unreadCount, 1)
    }

    func testA429AndSuccessFalseKeepTheCache() async {
        var status = 0
        let t = FakeTransport { _ in
            switch status {
            case 0: return self.feed([self.card("a")], unread: 1)
            case 429: return (429, nil)
            default: return (200, "{\"success\":false,\"reason\":\"evaluation_error\",\"etag\":\"\",\"cards\":[],\"unreadCount\":0,\"nextCursor\":null,\"ttlSeconds\":300,\"stateScope\":\"device\"}".data(using: .utf8))
            }
        }
        let m = manager(t)
        _ = await m.getCards()
        status = 429
        clock += 301
        let afterLimit = await m.getCards()
        XCTAssertEqual(afterLimit.cards.map { $0.id }, ["a"])
        status = 200
        clock += 31
        let f = await m.getCards()
        XCTAssertEqual(t.fetches.count, 3)
        XCTAssertEqual(f.cards.map { $0.id }, ["a"])
        XCTAssertEqual(f.stateScope, "server")
    }

    func testServesTheCacheForTheTtlAndCoalescesRefreshes() async {
        let t = FakeTransport { _ in self.feed([self.card("a")], unread: 1) }
        let m = manager(t)
        _ = await m.getCards()
        _ = await m.getCards()
        XCTAssertEqual(t.fetches.count, 1)
        m.refreshCards()
        m.refreshCards()
        await settle()
        // Inside CARD_MIN_REFRESH_SECONDS: deferred, not sent now.
        XCTAssertEqual(t.fetches.count, 1)
    }

    func testReportsCarryTheTokenTheActionAndTheSessionOnceEach() async {
        let t = FakeTransport { _ in self.feed([self.card("a"), self.card("b")], unread: 2) }
        let m = manager(t)
        _ = await m.getCards()
        m.markCardViewed("a")
        m.markCardViewed("a")
        m.markCardRead("a")
        m.markCardRead("a")
        m.markCardClicked("a")
        m.dismissCard("b")
        await settle()
        let sent = Set(t.tracks.map { "\($0["deliveryToken"] as? String ?? ""):\($0["action"] as? String ?? "")" })
        XCTAssertEqual(t.tracks.count, 5)
        XCTAssertEqual(sent, ["tok-a:viewed", "tok-a:read", "tok-a:clicked", "tok-b:viewed", "tok-b:dismissed"])
        for body in t.tracks {
            XCTAssertEqual(Set(body.keys), ["deliveryToken", "action", "sessionId"])
            XCTAssertEqual(body["sessionId"] as? String, "s-1")
        }
    }

    func testReportsApplyToTheCacheAtOnceAndTellTheListeners() async {
        let t = FakeTransport { _ in self.feed([self.card("a"), self.card("b"), self.card("c")], unread: 3) }
        let m = manager(t)
        _ = await m.getCards()
        var updates: [CardFeed] = []
        let sub = m.onCardsUpdated { updates.append($0) }
        m.markCardRead("a")
        XCTAssertEqual(m.getUnreadCardCount(), 2)
        XCTAssertEqual(m.view().cards.first { $0.id == "a" }?.read, true)
        m.markCardClicked("b")
        let b = m.view().cards.first { $0.id == "b" }
        XCTAssertEqual(b?.clicked, true)
        XCTAssertEqual(b?.read, true)
        XCTAssertEqual(m.getUnreadCardCount(), 1)
        m.dismissCard("c")
        XCTAssertEqual(m.view().cards.map { $0.id }, ["a", "b"])
        XCTAssertEqual(m.getUnreadCardCount(), 0)
        XCTAssertEqual(updates.count, 3)
        XCTAssertEqual(updates.last?.unreadCount, 0)
        sub.cancel()
    }

    func testAnAnonymousVisitorsReadAndDismissedStayOnTheDeviceUntilReset() async {
        user = nil
        let t = FakeTransport { _ in self.feed([self.card("a"), self.card("b"), self.card("c")], unread: 3, scope: "device") }
        let m = manager(t)
        _ = await m.getCards()
        m.markCardRead("a")
        m.dismissCard("b")
        XCTAssertNotNil(storedDevice)

        // A new launch: the server knows nothing of it, the device does.
        storedFeed = nil
        let again = manager(t)
        let f = await again.getCards()
        XCTAssertEqual(f.cards.map { $0.id }, ["a", "c"])
        XCTAssertEqual(f.cards.first { $0.id == "a" }?.read, true)
        XCTAssertEqual(f.unreadCount, 1)
        XCTAssertEqual(f.stateScope, "device")

        // A reset (or identify) clears the device's state.
        again.invalidate(clearDeviceState: true)
        XCTAssertNil(storedDevice)
        clock += 31
        let fresh = await again.getCards()
        XCTAssertEqual(fresh.cards.map { $0.id }, ["a", "b", "c"])
        XCTAssertEqual(fresh.unreadCount, 3)
    }

    func testTheSilentPushRefreshesTheFeed() async {
        let t = FakeTransport { _ in self.feed([self.card("a")], unread: 1) }
        let m = manager(t)
        m.onSyncPush()
        await settle()
        XCTAssertEqual(t.fetches.count, 1)
        XCTAssertEqual(m.view().cards.map { $0.id }, ["a"])
    }

    func testAnAnswerFromBeforeAnIdentityChangeIsDiscarded() async {
        let gate = DispatchSemaphore(value: 0)
        let t = FakeTransport { _ in
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async { _ = gate.wait(timeout: .now() + 3); c.resume() }
            }
            return self.feed([self.card("old-person")], unread: 1)
        }
        let m = manager(t)
        m.refreshCards()
        await settle()
        XCTAssertEqual(t.fetches.count, 1)
        user = "user-2"
        m.invalidate(clearDeviceState: true)
        gate.signal()
        await settle(0.3)
        XCTAssertFalse(m.view().cards.contains { $0.id == "old-person" })
        // A report for the previous person's card goes nowhere.
        m.markCardRead("old-person")
        await settle()
        XCTAssertTrue(t.tracks.isEmpty)
    }

    func testWithoutConsentNothingIsAskedAndNothingReported() async {
        consentValue = "denied"
        let t = FakeTransport { _ in self.feed([self.card("a")], unread: 1) }
        let m = manager(t)
        let f = await m.getCards()
        XCTAssertTrue(t.fetches.isEmpty)
        XCTAssertTrue(f.cards.isEmpty)
        XCTAssertEqual(f.unreadCount, 0)
    }

    func testTheNextPageIsAddedToTheFeed() async {
        let t = FakeTransport { body in
            body["cursor"] != nil
                ? self.feed([self.card("c")], unread: 3)
                : self.feed([self.card("a"), self.card("b")], unread: 3, next: "c1")
        }
        let m = manager(t)
        _ = await m.getCards()
        let page = await m.getCards(cursor: "c1")
        XCTAssertEqual(t.fetches[1]["cursor"] as? String, "c1")
        XCTAssertNil(t.fetches[1]["etag"])
        XCTAssertEqual(page.cards.map { $0.id }, ["c"])
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(m.view().cards.map { $0.id }, ["a", "b", "c"])
    }

    func testTheFeedCacheSurvivesALaunchForTheSamePersonOnly() async {
        let t = FakeTransport { _ in self.feed([self.card("a")], unread: 1) }
        _ = await manager(t).getCards()
        let again = manager(t)
        XCTAssertEqual(again.view().cards.map { $0.id }, ["a"])
        XCTAssertEqual(again.getUnreadCardCount(), 1)
        user = "someone-else"
        XCTAssertTrue(manager(t).view().cards.isEmpty)
    }

    func testCardLinksFollowThePlacementRule() {
        XCTAssertTrue(PlacementView.isSafeUrl(URL(string: "https://shop.example/sale")!))
        XCTAssertFalse(isAppDeepLink("https://shop.example/sale"))
        XCTAssertTrue(isAppDeepLink("myapp://cart"))
        for link in ["javascript:alert(1)", "javascript://x", "data:text/html,x", "file:///data/x", "intent://x#Intent;end",
                     "content://x", "vbscript://x", "blob://x", "about://blank", "  JavaScript://x", "myapp:cart", ""] {
            XCTAssertFalse(isAppDeepLink(link), link)
            if let url = URL(string: link) { XCTAssertFalse(PlacementView.isSafeUrl(url), link) }
        }
    }
}
