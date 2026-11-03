import XCTest
@testable import Joryio

/// An in-app message counts as DISPLAYED only once the person could see it
/// (InAppDisplay.IN_APP_DISPLAY_DWELL_MS, the same rule on every SDK).
///
/// Production, 2026-11-02/03: a modal was served and reported displayed in the
/// same second, during a sign-in redirect and a logout. The tester saw at most
/// a flash, both counted, and the 2-per-7-days cap was used up (BACKLOG D320).
final class InAppDisplayDwellTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        UserDefaults.standard.removeObject(forKey: "jry_campaign_impressions")
        UserDefaults.standard.removeObject(forKey: "jry_displayed_campaigns")
    }

    private var drawn: [String] = []
    private var active = true
    private var stable = true
    private var onScreen = true

    private func makeManager(dwell: TimeInterval) -> InAppMessagingManager {
        let storage = TestSupport.storage()
        let logger = TestSupport.logger()
        let identity = IdentityManager(storage: storage, logger: logger)
        let session = SessionManager(storage: storage, logger: logger, sessionTimeout: 1800)
        let manager = InAppMessagingManager(
            networkClient: TestSupport.network(),
            storage: storage,
            identityManager: identity,
            sessionManager: session,
            logger: logger
        )
        manager.displayDwellSeconds = dwell
        manager.hostStableTimeoutSeconds = 0.3
        manager.hostStablePollSeconds = 0.05
        manager.appActiveOverrideForTesting = { [unowned self] in self.active }
        manager.hostStableOverrideForTesting = { [unowned self] in self.stable }
        manager.messageOnScreenOverrideForTesting = { [unowned self] in self.onScreen }
        manager.drawOverrideForTesting = { [unowned self] campaign in
            self.drawn.append(campaign.id)
            return true
        }
        return manager
    }

    private func campaign(_ id: String) throws -> InAppCampaign {
        try TestSupport.campaign([
            "id": id,
            "name": id,
            "type": "modal",
            "priority": 1,
            "content": ["kind": "native", "title": "Hello", "body": "Body"],
            "frequencyCap": ["maxImpressions": 2, "timeWindow": "7d"],
        ])
    }

    /// The `action` of every /v1/in-app/track request for `id`, in order.
    private func reports(_ id: String) -> [String] {
        StubURLProtocol.requests
            .filter { $0.url.path.hasSuffix("/v1/in-app/track") }
            .compactMap { $0.json }
            .filter { $0["campaignId"] as? String == id }
            .compactMap { $0["action"] as? String }
    }

    func testTheDwellIsOneSecondOnEveryPlatform() {
        XCTAssertEqual(InAppDisplay.IN_APP_DISPLAY_DWELL_MS, 1000)
    }

    // MARK: Unsettled screen before show -> no show

    func testNothingIsDrawnWhileTheScreenIsNotSettled() async throws {
        stable = false
        let manager = makeManager(dwell: 0.1)
        manager.setActiveCampaignsForTesting([try campaign("unsettled")])

        await manager.evaluateCampaigns()

        XCTAssertEqual(drawn, [], "drawn mid-transition: the screen it sat on was going away")
        XCTAssertFalse(manager.isDisplayingForTesting, "a message that was not drawn kept the display slot")
        XCTAssertEqual(manager.impressionCountForTesting("unsettled"), 0)
        XCTAssertEqual(reports("unsettled"), [])

        // Deferred, not dropped: the next time the app is active and settled.
        stable = true
        manager.appBecameActive()
        waitUntil { self.drawn == ["unsettled"] }
    }

    // MARK: Hidden before the dwell -> no displayed, cap not consumed

    func testLeavingTheAppBeforeTheDwellCountsNothing() async throws {
        let manager = makeManager(dwell: 0.3)
        manager.setActiveCampaignsForTesting([try campaign("left")])

        await manager.evaluateCampaigns()
        XCTAssertEqual(drawn, ["left"])
        active = false
        manager.appLeftForeground()
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(reports("left"), [], "reported displayed for a message the person left before seeing")
        XCTAssertEqual(manager.impressionCountForTesting("left"), 0, "the frequency cap was spent on a message nobody saw")
        XCTAssertEqual(manager.countedForTesting("left"), false)

        // Back in the app with the message still up: the dwell starts again.
        active = true
        manager.appBecameActive()
        waitUntil { self.reports("left") == ["displayed"] }
        XCTAssertEqual(manager.impressionCountForTesting("left"), 1)
    }

    func testAMessageGoneFromTheScreenAtTheEndOfTheDwellCountsNothing() async throws {
        let manager = makeManager(dwell: 0.2)
        manager.setActiveCampaignsForTesting([try campaign("gone")])

        await manager.evaluateCampaigns()
        onScreen = false
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(reports("gone"), [])
        XCTAssertEqual(manager.impressionCountForTesting("gone"), 0)
    }

    // MARK: Visible >= dwell -> displayed once

    func testAMessageUpForTheDwellCountsOnce() async throws {
        let manager = makeManager(dwell: 0.2)
        manager.setActiveCampaignsForTesting([try campaign("seen")])

        await manager.evaluateCampaigns()
        XCTAssertEqual(reports("seen"), [], "reported displayed at draw time, before anyone could see it")

        waitUntil { self.reports("seen") == ["displayed"] }
        // A second becoming-active must not count it again.
        manager.appBecameActive()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(reports("seen"), ["displayed"])
        XCTAssertEqual(manager.impressionCountForTesting("seen"), 1)
        XCTAssertEqual(manager.countedForTesting("seen"), true)
    }

    // MARK: Click / dismiss before the dwell count as seen

    func testADismissBeforeTheDwellCountsAsDisplayedThenDismissed() async throws {
        let manager = makeManager(dwell: 30)
        manager.setActiveCampaignsForTesting([try campaign("closed")])

        await manager.evaluateCampaigns()
        manager.messageViewDidDismiss("closed")

        waitUntil { self.reports("closed").count == 2 }
        XCTAssertEqual(reports("closed"), ["displayed", "dismissed"])
        XCTAssertEqual(manager.impressionCountForTesting("closed"), 1)
    }

    func testAClickBeforeTheDwellCountsAsDisplayedThenClicked() async throws {
        let manager = makeManager(dwell: 30)
        manager.setActiveCampaignsForTesting([try campaign("tapped")])

        await manager.evaluateCampaigns()
        manager.messageViewClicked("tapped", action: "cta", url: nil)

        waitUntil { self.reports("tapped").count == 2 }
        XCTAssertEqual(reports("tapped"), ["displayed", "clicked"])
        XCTAssertEqual(manager.impressionCountForTesting("tapped"), 1)
    }

    func testAConversionOrFormBeforeTheDwellCountsAsDisplayedFirst() async throws {
        let manager = makeManager(dwell: 30)
        manager.setActiveCampaignsForTesting([try campaign("converted")])

        await manager.evaluateCampaigns()
        // `logConversion` from the SDK's web view arrives through the host API.
        manager.trackHostImpression(campaignId: "converted", action: "converted")

        waitUntil { self.reports("converted").count == 2 }
        XCTAssertEqual(reports("converted"), ["displayed", "converted"])

        // A form submit counts too; already counted, so nothing more.
        await manager.noteInteraction(campaignId: "converted")
        XCTAssertEqual(manager.impressionCountForTesting("converted"), 1)
    }

    // MARK: Programmatic removal before the dwell reports nothing

    func testAResetBeforeTheDwellReportsNothing() async throws {
        let manager = makeManager(dwell: 0.3)
        manager.setActiveCampaignsForTesting([try campaign("reset")])

        await manager.evaluateCampaigns()
        manager.clear()
        manager.messageViewDidDismiss("reset")
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(reports("reset"), [], "a message dropped before it counted reported displayed or dismissed")
    }

    // MARK: The stability probe

    @MainActor
    func testTheStabilityProbe() {
        XCTAssertFalse(InAppMessagingManager.hostIsStable(window: nil, appActive: true))
        let top = UIViewController()
        let nav = UINavigationController(rootViewController: top)
        XCTAssertTrue(InAppMessagingManager.topViewController(from: nav) === top)
    }
}
