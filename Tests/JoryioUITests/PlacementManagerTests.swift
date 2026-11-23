import XCTest
@testable import Joryio
@testable import JoryioUI

/// Placements on iOS (docs/PLACEMENTS_PLAN.md, PR 6): the manager's rules
/// against a fake transport (the serve endpoint is mocked) - the same rules as
/// the web SDK's placements.spec.ts and Android's PlacementManagerTest.
final class PlacementManagerTests: XCTestCase {

    private final class FakeTransport: PlacementTransport {
        let lock = NSLock()
        var answer: ([String: Any]) -> (Int, Data?)
        private(set) var fetches: [[String: Any]] = []
        private(set) var tracks: [[String: Any]] = []
        init(_ answer: @escaping ([String: Any]) -> (Int, Data?)) { self.answer = answer }
        func fetchPlacements(_ body: Data) async -> (Int, Data?) {
            let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            lock.lock(); fetches.append(o); lock.unlock()
            return answer(o)
        }
        func trackPlacement(_ body: Data) async {
            let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            lock.lock(); tracks.append(o); lock.unlock()
        }
        var trackCount: Int { lock.lock(); defer { lock.unlock() }; return tracks.count }
    }

    private var clock: TimeInterval = 1_700_000_000
    private var consentValue: String? = "granted"
    private var user: String?
    private var stored: String?

    private func item(_ id: String = "camp-1", extra: String = "") -> String {
        """
        {"id":"\(id)","variantId":"v2","deliveryToken":"tok-\(id)","priority":8,"kind":"native",
         "data":{"headline":"Free shipping today"},
         "content":{"kind":"native","title":"Free shipping","body":"Today only","buttons":[{"id":"cta","text":"Shop","action":"url","url":"https://shop.example"}]}\(extra)}
        """
    }

    private func answer(_ placements: String) -> (Int, Data?) {
        (200, "{\"success\":true,\"placements\":{\(placements)}}".data(using: .utf8))
    }

    private func hero(_ items: String? = nil, extra: String = "") -> String {
        "\"home_hero\":{\"placementKey\":\"home_hero\",\"emptyBehavior\":\"collapse\",\"maxItems\":1,\"ttlSeconds\":300,\"isControl\":false,\"items\":[\(items ?? item())]\(extra)}"
    }

    private func manager(_ t: FakeTransport) -> PlacementManager {
        PlacementManager(
            transport: t,
            load: { [unowned self] in self.stored },
            save: { [unowned self] in self.stored = $0 },
            consent: { [unowned self] in self.consentValue },
            userId: { [unowned self] in self.user },
            anonymousId: { "anon-1" },
            sessionId: { "s-1" },
            capabilities: { ["placements", "content.native", "content.data"] },
            now: { [unowned self] in self.clock },
            onMain: { $0() }
        )
    }

    private func settle(_ seconds: Double = 0.15) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testBatchesKeysIntoOneRequestWithThePlanBody() async {
        let t = FakeTransport { _ in self.answer(self.hero() + ",\"cart_upsell\":{\"placementKey\":\"cart_upsell\",\"items\":[]}") }
        let m = manager(t)
        async let a = m.getPlacements(["home_hero"])
        async let b = m.getPlacements(["cart_upsell", "home_hero"])
        let (ra, rb) = await (a, b)
        XCTAssertEqual(t.fetches.count, 1)
        let body = t.fetches[0]
        XCTAssertEqual(Set(body["placements"] as? [String] ?? []), ["home_hero", "cart_upsell"])
        XCTAssertEqual(body["anonymousId"] as? String, "anon-1")
        XCTAssertEqual(body["sessionId"] as? String, "s-1")
        XCTAssertEqual(body["deviceType"] as? String, "ios")
        XCTAssertEqual(body["trackingConsent"] as? String, "granted")
        XCTAssertEqual(body["capabilities"] as? [String], ["placements", "content.native", "content.data"])
        XCTAssertEqual(ra["home_hero"]?.items.first?.id, "camp-1")
        XCTAssertEqual(ra["home_hero"]?.items.first?.data["headline"] as? String, "Free shipping today")
        XCTAssertEqual(ra["home_hero"]?.items.first?.content?.title, "Free shipping")
        XCTAssertEqual(rb["cart_upsell"]?.items.count, 0)
        XCTAssertEqual(rb["cart_upsell"]?.emptyBehavior, "collapse")
    }

    /// D444 Phase 2b: a recommendation item's product cards reach the app and the bridges (toJson).
    func testExposesProductCardsAndCarriesThemThroughToJson() async {
        let products = ",\"products\":[{\"id\":\"sku-1\",\"title\":\"Mug\",\"price\":\"$9\",\"compareAtPrice\":\"$10\",\"discountPercent\":10,\"imageUrl\":\"https://cdn/x.png\",\"url\":\"https://shop/x\"},{\"title\":\"no id\"}]"
        let t = FakeTransport { _ in self.answer(self.hero(self.item(extra: products))) }
        let r = await manager(t).getPlacements(["home_hero"])
        let item = r["home_hero"]?.items.first
        XCTAssertEqual(item?.products.count, 1)
        XCTAssertEqual(item?.products.first?.id, "sku-1")
        XCTAssertEqual(item?.products.first?.discountPercent, 10)
        let json = r["home_hero"]?.toJson()
        let items = json?["items"] as? [[String: Any]]
        let bridged = items?.first?["products"] as? [[String: Any]]
        XCTAssertEqual(bridged?.first?["id"] as? String, "sku-1")
        XCTAssertEqual(bridged?.first?["compareAtPrice"] as? String, "$10")
    }

    /// onPlacementsUpdated answers the one JoryioSubscription every listener of
    /// every Joryio SDK returns: cancel() stops it, twice is harmless.
    func testOnPlacementsUpdatedAnswersAJoryioSubscriptionWhoseCancelStopsTheUpdates() async {
        var itemId = "camp-1"
        let t = FakeTransport { _ in self.answer(self.hero(self.item(itemId))) }
        let m = manager(t)
        var heard = 0
        let sub: JoryioSubscription = m.onPlacementsUpdated { _ in heard += 1 }
        _ = await m.getPlacements(["home_hero"])
        await settle()
        XCTAssertEqual(heard, 1)
        sub.cancel()
        sub.cancel()
        itemId = "camp-2"
        clock += 300
        _ = await m.getPlacements(["home_hero"])
        await settle()
        XCTAssertEqual(t.fetches.count, 2)
        XCTAssertEqual(heard, 1)
    }

    func testServesTheCacheForTtlAndRateLimitsRefreshes() async {
        let t = FakeTransport { _ in self.answer(self.hero()) }
        let m = manager(t)
        _ = await m.getPlacements(["home_hero"])
        _ = await m.getPlacements(["home_hero"])
        m.refreshPlacements(["home_hero"])
        m.refreshPlacements(["home_hero"])
        await settle()
        XCTAssertEqual(t.fetches.count, 1)
        clock += 300
        _ = await m.getPlacements(["home_hero"])
        XCTAssertEqual(t.fetches.count, 2)
        XCTAssertEqual(Placements.PLACEMENT_MIN_REFRESH_SECONDS, 30)
        XCTAssertEqual(Placements.PLACEMENT_VIEWABLE_FRACTION, 0.5)
    }

    func testA429KeepsTheCache() async {
        var status = 200
        let t = FakeTransport { _ in status == 200 ? self.answer(self.hero()) : (status, nil) }
        let m = manager(t)
        _ = await m.getPlacements(["home_hero"])
        status = 429
        clock += 301
        let r = await m.getPlacements(["home_hero"])
        XCTAssertEqual(t.fetches.count, 2)
        XCTAssertEqual(r["home_hero"]?.items.map { $0.id }, ["camp-1"])
    }

    func testWithoutConsentTheRequestNamesNobodyAndNothingIsReported() async {
        consentValue = "denied"
        let t = FakeTransport { _ in self.answer(self.hero()) }
        let m = manager(t)
        let r = await m.getPlacements(["home_hero"])
        let body = t.fetches[0]
        XCTAssertEqual(body["trackingConsent"] as? String, "denied")
        XCTAssertNil(body["anonymousId"])
        XCTAssertNil(body["userId"])
        XCTAssertNil(body["sessionId"])
        r["home_hero"]?.items.first?.markDisplayed()
        r["home_hero"]?.items.first?.markClicked(elementId: "cta")
        await settle()
        XCTAssertEqual(t.trackCount, 0)
    }

    func testNothingIsSentWhenSendingIsImpossible() async {
        consentValue = nil
        let t = FakeTransport { _ in self.answer(self.hero()) }
        let r = await manager(t).getPlacements(["home_hero"])
        XCTAssertTrue(t.fetches.isEmpty)
        XCTAssertEqual(r["home_hero"]?.items.count, 0)
    }

    func testReportsDisplayedOnceAndAClickCountsDisplayedFirst() async {
        let t = FakeTransport { _ in self.answer(self.hero()) }
        let m = manager(t)
        let item = await m.getPlacements(["home_hero"])["home_hero"]!.items[0]
        item.markClicked(elementId: "cta")
        item.markDisplayed()
        await settle()
        let actions = t.tracks.map { $0["action"] as? String ?? "" }
        XCTAssertEqual(actions.sorted(), ["clicked", "displayed"])
        let displayed = t.tracks.first { ($0["action"] as? String) == "displayed" }!
        XCTAssertEqual(displayed["campaignId"] as? String, "camp-1")
        XCTAssertEqual(displayed["deliveryToken"] as? String, "tok-camp-1")
        XCTAssertEqual(displayed["placementKey"] as? String, "home_hero")
        XCTAssertEqual(t.tracks.first { ($0["action"] as? String) == "clicked" }?["elementId"] as? String, "cta")
    }

    func testADismissalIsReportedAndHidesTheItem() async {
        let t = FakeTransport { _ in self.answer(self.hero()) }
        let m = manager(t)
        await m.getPlacements(["home_hero"])["home_hero"]!.items[0].markDismissed()
        await settle()
        XCTAssertEqual(Set(t.tracks.map { $0["action"] as? String ?? "" }), ["displayed", "dismissed"])
        let after = await m.getPlacements(["home_hero"])
        XCTAssertEqual(after["home_hero"]?.items.count, 0)
    }

    func testAHeldOutPersonReportsControlViewedOncePerToken() async {
        let t = FakeTransport { _ in self.answer("\"home_hero\":{\"placementKey\":\"home_hero\",\"isControl\":true,\"controlToken\":\"ctl-1\",\"items\":[]}") }
        let m = manager(t)
        let p = await m.getPlacements(["home_hero"])["home_hero"]!
        XCTAssertTrue(p.isControl)
        p.markDisplayed()
        p.markDisplayed()
        await settle()
        XCTAssertEqual(t.tracks.count, 1)
        XCTAssertEqual(t.tracks[0]["action"] as? String, "control_viewed")
        XCTAssertEqual(t.tracks[0]["controlToken"] as? String, "ctl-1")
        XCTAssertNil(t.tracks[0]["campaignId"])
    }

    func testAnAnswerFromBeforeAnIdentityChangeIsDiscarded() async {
        var m: PlacementManager!
        let t = FakeTransport { _ in m.invalidate(); return self.answer(self.hero()) }
        m = manager(t)
        let r = await m.getPlacements(["home_hero"])
        XCTAssertEqual(r["home_hero"]?.items.count, 0)
    }

    func testEventTriggeredItemsWaitForTheirEvent() async {
        let triggered = item(extra: ",\"triggers\":[{\"type\":\"event\",\"event\":\"checkout_started\",\"attribute\":\"value\",\"operator\":\"gt\",\"value\":50}]")
        let t = FakeTransport { _ in self.answer(self.hero(triggered)) }
        let m = manager(t)
        let first = await m.getPlacements(["home_hero"])
        XCTAssertEqual(first["home_hero"]?.items.count, 0)
        m.onEventTracked("checkout_started", properties: ["value": 10])
        let low = await m.getPlacements(["home_hero"])
        XCTAssertEqual(low["home_hero"]?.items.count, 0)
        m.onEventTracked("checkout_started", properties: ["value": 80])
        let high = await m.getPlacements(["home_hero"])
        XCTAssertEqual(high["home_hero"]?.items.count, 1)
        XCTAssertEqual(t.fetches.count, 1)
    }

    func testTheDiskCacheServesTheSamePersonOnly() async {
        let t = FakeTransport { _ in self.answer(self.hero()) }
        _ = await manager(t).getPlacements(["home_hero"])
        let t2 = FakeTransport { _ in self.answer(self.hero()) }
        let again = await manager(t2).getPlacements(["home_hero"])
        XCTAssertEqual(again["home_hero"]?.items.count, 1)
        XCTAssertTrue(t2.fetches.isEmpty)
        user = "user-2"
        let t3 = FakeTransport { _ in self.answer(self.hero()) }
        _ = await manager(t3).getPlacements(["home_hero"])
        XCTAssertEqual(t3.fetches.first?["userId"] as? String, "user-2")
    }

    func testUnknownOperatorsDoNotMatch() {
        XCTAssertFalse(PlacementManager.triggerMatches(["attribute": "a", "operator": "regex", "value": "x"], ["a": "x"]))
        XCTAssertTrue(PlacementManager.triggerMatches(["attribute": "a", "value": 2], ["a": 2.0]))
    }

    func testAPlacementFromBeforeAnIdentityChangeReportsNothing() async {
        let t = FakeTransport { _ in self.answer(self.hero()) }
        let m = manager(t)
        let old = await m.getPlacements(["home_hero"])["home_hero"]!
        m.invalidate()
        old.items[0].markDisplayed()
        old.items[0].markClicked(elementId: "cta")
        old.items[0].markDismissed()
        old.markDisplayed()
        await settle()
        XCTAssertEqual(t.trackCount, 0)
    }

    private final class Host: PlacementHost {
        var placementKey = "home_hero"
        var cleared = 0
        func shownIds() -> [String] { [] }
        func onPlacementUpdated(_ placement: Placement) {}
        func clearPlacement() { cleared += 1 }
    }

    func testInvalidateClearsHostsAtOnceAndForgetsWhatWasReported() async {
        let t = FakeTransport { _ in self.answer(self.hero()) }
        let m = manager(t)
        let host = Host()
        m.attach(host)
        await m.getPlacements(["home_hero"])["home_hero"]!.items[0].markDisplayed()
        await settle()
        m.invalidate()
        XCTAssertEqual(host.cleared, 1)
        clock += 30
        await m.getPlacements(["home_hero"])["home_hero"]!.items[0].markDisplayed()
        await settle()
        XCTAssertEqual(t.trackCount, 2)
    }

    func testTheHtmlViewAllowsOnlyItsOwnDocumentAndOpensOnlyHttpLinks() {
        var loaded = false
        var links: [URL] = []
        let blank = URL(string: "about:blank")
        XCTAssertEqual(PlacementWebView.policy(for: .other, url: blank, isMainFrame: true, loadedDocument: &loaded, onLink: { links.append($0) }), .allow)
        // A second load (meta refresh, script redirect, form post) is cancelled silently.
        XCTAssertEqual(PlacementWebView.policy(for: .other, url: URL(string: "https://evil.example"), isMainFrame: true, loadedDocument: &loaded, onLink: { links.append($0) }), .cancel)
        XCTAssertEqual(PlacementWebView.policy(for: .other, url: blank, isMainFrame: true, loadedDocument: &loaded, onLink: { links.append($0) }), .cancel)
        XCTAssertEqual(PlacementWebView.policy(for: .formSubmitted, url: URL(string: "https://x.example"), isMainFrame: true, loadedDocument: &loaded, onLink: { links.append($0) }), .cancel)
        XCTAssertTrue(links.isEmpty)
        XCTAssertEqual(PlacementWebView.policy(for: .linkActivated, url: URL(string: "https://shop.example"), isMainFrame: true, loadedDocument: &loaded, onLink: { links.append($0) }), .cancel)
        XCTAssertEqual(links.map { $0.absoluteString }, ["https://shop.example"])
        XCTAssertTrue(PlacementView.isSafeUrl(URL(string: "https://shop.example")!))
        for bad in ["javascript:alert(1)", "myapp://cart", "file:///etc/hosts", "data:text/html,x", "tel:123"] {
            XCTAssertFalse(PlacementView.isSafeUrl(URL(string: bad)!), bad)
        }
    }

    func testIsAppDeepLinkAcceptsOnlyAppSchemeLinks() {
        for good in ["myapp://cart", "MyApp://p/1?x=y", "com.shop.app://home", "  myapp://cart "] {
            XCTAssertTrue(isAppDeepLink(good), good)
        }
        for bad in ["javascript:alert(1)", "javascript://%0aalert(1)", "JAVASCRIPT://x", "data:text/html,x", "data://x",
                    "intent://scan#Intent;end", "file:///etc/passwd", "vbscript://x", "blob://x", "about://blank", "content://x",
                    "http://x.example", "https://x.example", "myapp:cart", "myapp://", "/relative", "", "1app://x"] {
            XCTAssertFalse(isAppDeepLink(bad), bad)
        }
        XCTAssertFalse(isAppDeepLink(nil))
    }

    func testADeepLinkButtonReachesTheHandlerOnlyForAnAppLink() {
        XCTAssertEqual(PlacementView.linkRoute(action: "deep_link", url: "myapp://cart", hasDeepLinkHandler: true), .deepLink(URL(string: "myapp://cart")!))
        // Without a handler, or on a plain `url` button, an app link is not opened by the view.
        XCTAssertEqual(PlacementView.linkRoute(action: "deep_link", url: "myapp://cart", hasDeepLinkHandler: false), PlacementView.LinkRoute.none)
        XCTAssertEqual(PlacementView.linkRoute(action: "url", url: "myapp://cart", hasDeepLinkHandler: true), PlacementView.LinkRoute.none)
        for bad in ["javascript:alert(1)", "javascript://%0aalert(1)", "data:text/html,x", "intent://x#Intent;end", "file:///etc/hosts", "content://x"] {
            XCTAssertEqual(PlacementView.linkRoute(action: "deep_link", url: bad, hasDeepLinkHandler: true), PlacementView.LinkRoute.none, bad)
            XCTAssertEqual(PlacementView.linkRoute(action: "url", url: bad, hasDeepLinkHandler: true), PlacementView.LinkRoute.none, bad)
        }
        // http(s) opens through the safe path and never reaches the handler.
        for web in ["https://shop.example/p", "http://shop.example/p"] {
            XCTAssertEqual(PlacementView.linkRoute(action: "deep_link", url: web, hasDeepLinkHandler: true), .open(URL(string: web)!), web)
            XCTAssertEqual(PlacementView.linkRoute(action: "url", url: web, hasDeepLinkHandler: false), .open(URL(string: web)!), web)
        }
        XCTAssertEqual(PlacementView.linkRoute(action: "dismiss", url: "https://shop.example", hasDeepLinkHandler: true), PlacementView.LinkRoute.none)
    }

    @MainActor
    func testPlacementViewDrawsANativeCardAndReportsTheHoldoutSpot() async {
        let t = FakeTransport { _ in self.answer(self.hero()) }
        let m = manager(t)
        _ = await m.getPlacements(["home_hero"])
        let view = PlacementView(placementKey: "home_hero")
        view.onPlacementUpdated(m.toPlacement("home_hero"))
        XCTAssertEqual(view.shownIds(), ["camp-1"])
        let swiftUI = JoryioPlacement("home_hero")
        XCTAssertEqual(swiftUI.placementKey, "home_hero")
    }

    /// The built-in product cards row: drawn for a data item with products,
    /// one card per product, a tap reported as `product:<id>`.
    @MainActor
    func testPlacementViewDrawsProductCardsAndReportsAProductClick() async {
        let products = ",\"products\":[{\"id\":\"sku-1\",\"title\":\"Mug\",\"price\":\"$9\",\"compareAtPrice\":\"$12\",\"imageUrl\":\"https://cdn.example/mug.png\",\"url\":\"myapp://product/1\"},{\"id\":\"sku-2\",\"title\":\"Cup\",\"price\":\"$5\",\"url\":null}]"
        let dataItem = "{\"id\":\"camp-1\",\"variantId\":\"v2\",\"deliveryToken\":\"tok-1\",\"kind\":\"data\",\"data\":{}\(products)}"
        let t = FakeTransport { _ in self.answer(self.hero(dataItem)) }
        let m = manager(t)
        _ = await m.getPlacements(["home_hero"])
        let placement = m.toPlacement("home_hero")

        let view = PlacementView(placementKey: "home_hero")
        view.productButtonText = "Buy"
        view.onPlacementUpdated(placement)
        XCTAssertEqual(view.shownIds(), ["camp-1"])
        func find(_ id: String, in v: UIView) -> UIView? {
            if v.accessibilityIdentifier == id { return v }
            for s in v.subviews { if let f = find(id, in: s) { return f } }
            return nil
        }
        XCTAssertNotNil(find("joryio-placement-products:camp-1", in: view))
        let first = find("joryio-placement-product:sku-1", in: view)
        XCTAssertNotNil(first)
        XCTAssertNotNil(find("joryio-placement-product:sku-2", in: view))
        // The optional button only on a card that opens something.
        XCTAssertTrue((first?.subviews ?? []).contains { $0 is UIButton })
        XCTAssertFalse((find("joryio-placement-product:sku-2", in: view)?.subviews ?? []).contains { $0 is UIButton })
        XCTAssertEqual(Placements.placementProductElementId("sku-1"), "product:sku-1")
        XCTAssertEqual(Placements.placementProductElementId(String(repeating: "x", count: 300)).count, 128)

        let item = placement.items[0]
        view.productTapped(item, item.products[0])
        await settle()
        let clicked = t.tracks.first { $0["action"] as? String == "clicked" }
        XCTAssertEqual(clicked?["elementId"] as? String, "product:sku-1")
        XCTAssertEqual(clicked?["placementKey"] as? String, "home_hero")

        // showProducts = false: a data item is the app's to draw again.
        let plain = PlacementView(placementKey: "home_hero")
        plain.showProducts = false
        plain.onPlacementUpdated(placement)
        XCTAssertEqual(plain.shownIds(), [])
        let swiftUI = JoryioPlacement("home_hero", showProducts: false, productButtonText: "Buy", productCardWidth: 120)
        XCTAssertEqual(swiftUI.productCardWidth, 120)
    }
}
