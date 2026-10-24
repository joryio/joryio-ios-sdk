import XCTest
@testable import Joryio
@testable import JoryioUI

/// In-app fixes for 1.3.0 (findings 2, 3, 4, 5). Each failed before its fix.
final class InAppBehaviourTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        // The manager keeps impression history in standard defaults.
        UserDefaults.standard.removeObject(forKey: "jry_campaign_impressions")
        UserDefaults.standard.removeObject(forKey: "jry_displayed_campaigns")
    }

    private func makeManager(network: NetworkClient = TestSupport.network()) -> InAppMessagingManager {
        let storage = TestSupport.storage()
        let logger = TestSupport.logger()
        let identity = IdentityManager(storage: storage, logger: logger)
        let session = SessionManager(storage: storage, logger: logger, sessionTimeout: 1800)
        return InAppMessagingManager(
            networkClient: network,
            storage: storage,
            identityManager: identity,
            sessionManager: session,
            logger: logger
        )
    }

    private func nativeCampaign(
        id: String,
        type: String = "modal",
        triggers: [[String: Any]]? = nil,
        frequencyCap: [String: Any]? = nil,
        reevaluate: Bool = false
    ) throws -> InAppCampaign {
        var json: [String: Any] = [
            "id": id,
            "name": id,
            "type": type,
            "priority": 1,
            "content": ["kind": "native", "title": "Hello", "body": "Body"],
        ]
        if let triggers { json["triggers"] = triggers }
        if let frequencyCap { json["frequencyCap"] = frequencyCap }
        if reevaluate { json["reevaluateBeforeDisplay"] = true }
        return try TestSupport.campaign(json)
    }

    // MARK: Clicks use the vocabulary (finding 2, contract 9)

    func testAClickSendsClickedWithTheElementIdSeparately() throws {
        let request = InAppMessagingManager.clickRequest(campaignId: "c", elementId: "buy_now", sessionId: "s", anonymousId: "a")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(json["action"] as? String, "clicked", "the click NAME used to be sent as the action and refused")
        XCTAssertEqual(json["elementId"] as? String, "buy_now")
        XCTAssertEqual(json["clicked"] as? Bool, true)
        XCTAssertNotNil(json["clickedAt"])
    }

    func testAClickReachesTheServerAsClicked() throws {
        let manager = makeManager()
        manager.messageViewClicked("c1", action: "buy_now", url: nil)
        waitUntil { StubURLProtocol.requests.contains { $0.url.path.hasSuffix("/v1/in-app/track") } }
        let body = try XCTUnwrap(StubURLProtocol.requests.first { $0.url.path.hasSuffix("/v1/in-app/track") }?.json)
        XCTAssertEqual(body["action"] as? String, "clicked")
        XCTAssertEqual(body["elementId"] as? String, "buy_now")
    }

    func testHostActionsMapOntoTheBackendVocabulary() {
        XCTAssertEqual(InAppMessagingManager.impressionKind(for: "impression"), .display)
        XCTAssertEqual(InAppMessagingManager.impressionKind(for: "Displayed"), .display)
        XCTAssertEqual(InAppMessagingManager.impressionKind(for: "cta_click"), .click)
        XCTAssertEqual(InAppMessagingManager.impressionKind(for: "closed"), .dismiss)
        XCTAssertNil(InAppMessagingManager.impressionKind(for: "button:cta"))
        XCTAssertEqual(InAppMessagingManager.ImpressionKind.display.wireAction, "displayed")
        XCTAssertEqual(InAppMessagingManager.ImpressionKind.dismiss.wireAction, "dismissed")
    }

    // MARK: The display slot is released (finding 3)

    func testAFailedReCheckReleasesTheDisplaySlot() async throws {
        // The re-check answers "not eligible".
        StubURLProtocol.responder = { _ in (200, Data(#"{"eligible":false}"#.utf8)) }
        let manager = makeManager()
        manager.setActiveCampaignsForTesting([try nativeCampaign(id: "recheck", reevaluate: true)])

        await manager.evaluateCampaigns()

        XCTAssertFalse(manager.isDisplayingForTesting, "one 'no' from the re-check locked in-app messaging for the session")
    }

    func testTheHostReportingReleasesTheDisplaySlot() async throws {
        let manager = makeManager()
        var handed: [String] = []
        manager.onMessageReady = { handed.append($0.id) }
        manager.setActiveCampaignsForTesting([try nativeCampaign(id: "first")])

        await manager.evaluateCampaigns()
        XCTAssertEqual(handed, ["first"])
        XCTAssertTrue(manager.isDisplayingForTesting)

        manager.trackHostImpression(campaignId: "first", action: "dismissed")
        XCTAssertFalse(manager.isDisplayingForTesting, "the host path never released the slot")
    }

    func testClearingTheCallbackHandsDisplayBackAndFreesTheSlot() async throws {
        let manager = makeManager()
        manager.onMessageReady = { _ in }
        manager.hostCapabilities = ["content.native"]
        manager.setActiveCampaignsForTesting([try nativeCampaign(id: "held")])
        await manager.evaluateCampaigns()
        XCTAssertTrue(manager.isDisplayingForTesting)

        manager.clearHostRenderer()

        XCTAssertNil(manager.onMessageReady)
        XCTAssertNil(manager.hostCapabilities)
        XCTAssertFalse(manager.isDisplayingForTesting)
    }

    func testTheSdkDoesNotReportDisplayedForAHostRenderedMessage() async throws {
        let manager = makeManager()
        manager.onMessageReady = { _ in }
        manager.setActiveCampaignsForTesting([try nativeCampaign(id: "host")])

        await manager.evaluateCampaigns()
        try await Task.sleep(nanoseconds: 300_000_000)

        // Only THIS campaign's reports: the previous test's async "dismissed"
        // for its own campaign can land after setUp reset the capture (seen
        // twice in full-suite runs, never alone).
        let tracked = StubURLProtocol.requests.filter {
            $0.url.path.hasSuffix("/v1/in-app/track") && String(decoding: $0.body, as: UTF8.self).contains("\"host\"")
        }
        XCTAssertTrue(tracked.isEmpty, "the host reports displayed; the SDK used to send its own too")
    }

    // MARK: Triggers go through the same gates (finding 4)

    func testAnEventTriggerRespectsTheFrequencyCap() async throws {
        let manager = makeManager()
        manager.setMinimumGapForTesting(0)
        var handed = 0
        manager.onMessageReady = { _ in handed += 1 }
        manager.setActiveCampaignsForTesting([
            try nativeCampaign(
                id: "on-cart",
                triggers: [["type": "event", "event": "add_to_cart"]],
                frequencyCap: ["maxImpressions": 1, "timeWindow": "lifetime"]
            ),
        ])

        manager.onEventTracked("add_to_cart", properties: [:])
        waitUntil { handed == 1 }
        // The host's "displayed" is what spends the budget (contract 17).
        manager.trackHostImpression(campaignId: "on-cart", action: "displayed")
        manager.trackHostImpression(campaignId: "on-cart", action: "dismissed")

        manager.onEventTracked("add_to_cart", properties: [:])
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(handed, 1, "the event path bypassed the cap and displayed on every event")
    }

    func testAnEventTriggerDoesNotStackOnAMessageAlreadyShowing() async throws {
        let manager = makeManager()
        var handed: [String] = []
        manager.onMessageReady = { handed.append($0.id) }
        manager.setActiveCampaignsForTesting([
            try nativeCampaign(id: "on-sync"),
            try nativeCampaign(id: "on-cart", triggers: [["type": "event", "event": "add_to_cart"]]),
        ])

        await manager.evaluateCampaigns()
        manager.onEventTracked("add_to_cart", properties: [:])
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(handed, ["on-sync"])
    }

    // MARK: Banners let touches through (finding 5)

    func testABannerOnlyTakesTouchesInsideItsCard() throws {
        let banner = try XCTUnwrap(InAppNativeMessageView.make(campaign: try nativeCampaign(id: "b", type: "banner"), delegate: nil))
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        host.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: host.topAnchor),
            banner.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            banner.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        host.layoutIfNeeded()

        XCTAssertFalse(banner.point(inside: CGPoint(x: 195, y: 800), with: nil),
                       "a banner covered the whole window and swallowed every tap")
        let card = try XCTUnwrap(banner.interactionArea)
        let inside = card.convert(CGPoint(x: card.bounds.midX, y: card.bounds.midY), to: banner)
        XCTAssertTrue(banner.point(inside: inside, with: nil))
    }

    func testAModalStillBlocksTheScreen() throws {
        let modal = try XCTUnwrap(InAppNativeMessageView.make(campaign: try nativeCampaign(id: "m"), delegate: nil))
        modal.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        XCTAssertTrue(modal.point(inside: CGPoint(x: 5, y: 5), with: nil))
    }
}
