import XCTest
@testable import Joryio

/// `InAppConfig.holdInAppMessagesForHandler` (SDK 1.3.2). An app that draws
/// in-app messages itself sets its callback AFTER initialize(); a message ready
/// before that was drawn by the SDK - the React Native bug found testing
/// 1.3.1-beta.2. With the hold, it waits for the callback instead.
final class InAppHoldForHandlerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        UserDefaults.standard.removeObject(forKey: "jry_campaign_impressions")
        UserDefaults.standard.removeObject(forKey: "jry_displayed_campaigns")
    }

    private var identity: IdentityManager!

    private func makeManager(hold: Bool) -> InAppMessagingManager {
        let storage = TestSupport.storage()
        let logger = TestSupport.logger()
        let identity = IdentityManager(storage: storage, logger: logger)
        self.identity = identity
        let session = SessionManager(storage: storage, logger: logger, sessionTimeout: 1800)
        return InAppMessagingManager(
            networkClient: TestSupport.network(),
            storage: storage,
            identityManager: identity,
            sessionManager: session,
            logger: logger,
            holdInAppMessagesForHandler: hold
        )
    }

    private func campaign(_ id: String) throws -> InAppCampaign {
        try TestSupport.campaign([
            "id": id, "name": id, "type": "modal", "priority": 1,
            "content": ["kind": "native", "title": "Hello", "body": "Body"],
        ])
    }

    func testTheOptionIsOffByDefault() {
        XCTAssertFalse(InAppConfig().holdInAppMessagesForHandler)
    }

    func testWithoutTheHoldAMessageReadyBeforeTheCallbackGoesToTheSdkRenderer() async throws {
        // The race the option closes: nothing is parked, the SDK's own route runs.
        let manager = makeManager(hold: false)
        manager.setActiveCampaignsForTesting([try campaign("c1")])
        await manager.evaluateCampaigns()
        XCTAssertNil(manager.heldForHandlerIdForTesting)
    }

    func testAHeldMessageIsNotDrawnAndReachesTheCallbackSetLater() async throws {
        let manager = makeManager(hold: true)
        manager.setActiveCampaignsForTesting([try campaign("c1")])

        await manager.evaluateCampaigns()
        XCTAssertEqual(manager.heldForHandlerIdForTesting, "c1")
        XCTAssertTrue(manager.isDisplayingForTesting, "the held message keeps the one display slot")
        XCTAssertEqual(manager.impressionCountForTesting("c1"), 0, "nothing is spent while held")

        var handed: [String] = []
        manager.setHostRenderer({ handed.append($0.id) }, capabilities: ["content.native"])
        waitUntil { handed == ["c1"] }
        XCTAssertNil(manager.heldForHandlerIdForTesting)
        XCTAssertEqual(manager.hostCapabilities, ["content.native"])
        XCTAssertEqual(manager.impressionCountForTesting("c1"), 0, "the host's 'displayed' report spends it, not the hand-off")

        manager.trackHostImpression(campaignId: "c1", action: "dismissed")
        XCTAssertFalse(manager.isDisplayingForTesting)
    }

    func testClearingInsteadEndsTheHoldAndHandsTheMessageToTheSdkRenderer() async throws {
        let manager = makeManager(hold: true)
        manager.setActiveCampaignsForTesting([try campaign("c1")])
        await manager.evaluateCampaigns()
        XCTAssertEqual(manager.heldForHandlerIdForTesting, "c1")

        manager.clearHostRenderer()
        XCTAssertNil(manager.heldForHandlerIdForTesting)
        // No window in a unit test, so the SDK's renderer declines - and the
        // slot is freed rather than left held by a message nobody will draw.
        waitUntil { !manager.isDisplayingForTesting }
    }

    func testTheHoldEndsAtTheFirstSet() async throws {
        let manager = makeManager(hold: true)
        manager.setHostRenderer({ _ in }, capabilities: nil)
        manager.clearHostRenderer()
        manager.setActiveCampaignsForTesting([try campaign("c2")])
        await manager.evaluateCampaigns()
        XCTAssertNil(manager.heldForHandlerIdForTesting, "after a set and a clear the SDK draws as before")
    }

    func testResetDropsAHeldMessageButKeepsTheHold() async throws {
        let manager = makeManager(hold: true)
        manager.setActiveCampaignsForTesting([try campaign("c1")])
        await manager.evaluateCampaigns()
        XCTAssertEqual(manager.heldForHandlerIdForTesting, "c1")

        manager.clear()
        XCTAssertNil(manager.heldForHandlerIdForTesting)
        XCTAssertFalse(manager.isDisplayingForTesting)

        // The next person's message is still held: the app has not set its callback.
        manager.setActiveCampaignsForTesting([try campaign("c3")])
        await manager.evaluateCampaigns()
        XCTAssertEqual(manager.heldForHandlerIdForTesting, "c3")
    }

    func testAnIdentityOrConsentChangeDropsAHeldMessageAndFreesTheSlot() async throws {
        let manager = makeManager(hold: true)
        manager.setActiveCampaignsForTesting([try campaign("c1")])
        await manager.evaluateCampaigns()

        manager.invalidate()
        XCTAssertNil(manager.heldForHandlerIdForTesting)
        XCTAssertFalse(manager.isDisplayingForTesting)
    }

    func testAMessageHeldForUserAIsNeverHandedToUserB() async throws {
        // The identity binding on its own, without the invalidate() the SDK
        // facade also calls on identify: a message parked for A is checked
        // against the person current at delivery and dropped for B.
        let manager = makeManager(hold: true)
        identity.identify(userId: "user-a")
        manager.setActiveCampaignsForTesting([try campaign("c1")])
        await manager.evaluateCampaigns()
        XCTAssertEqual(manager.heldForHandlerIdForTesting, "c1")

        identity.identify(userId: "user-b")
        var handed: [String] = []
        manager.setHostRenderer({ handed.append($0.id) }, capabilities: nil)
        waitUntil { !manager.isDisplayingForTesting }
        XCTAssertEqual(handed, [], "a message chosen for A reached B")
    }

    func testAResetBeforeTheCallbackMeansNothingIsDelivered() async throws {
        let manager = makeManager(hold: true)
        manager.setActiveCampaignsForTesting([try campaign("c1")])
        await manager.evaluateCampaigns()
        manager.clear()
        var handed: [String] = []
        manager.setHostRenderer({ handed.append($0.id) }, capabilities: nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(handed, [])
    }
}
