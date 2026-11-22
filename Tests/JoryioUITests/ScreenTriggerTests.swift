import XCTest
@testable import Joryio

/// `time_on_screen` in-app triggers (Joryio BACKLOG D444 follow-up): the app
/// equivalent of the web's time_on_page. Contract:
/// packages/backend/src/common/in-app-screen-triggers.ts.
final class ScreenTriggerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        UserDefaults.standard.removeObject(forKey: "jry_campaign_impressions")
        UserDefaults.standard.removeObject(forKey: "jry_displayed_campaigns")
    }

    /// A clock the test moves by hand.
    final class FakeTime {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
    }

    private func makeManager(time: FakeTime) -> InAppMessagingManager {
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
        manager.screenClock = ScreenClock(now: { time.now })
        return manager
    }

    private func campaign(_ id: String, seconds: Any, screen: String? = nil) throws -> InAppCampaign {
        var trigger: [String: Any] = ["type": "time_on_screen", "value": seconds]
        if let screen { trigger["screenName"] = screen }
        return try TestSupport.campaign([
            "id": id, "name": id, "type": "modal", "priority": 1,
            "triggers": [trigger],
            "content": ["kind": "native", "title": "Hello", "body": "Body"],
        ])
    }

    func testTheTriggerDecodesItsScreenNameAndDoesNotDisplayOnSync() throws {
        let c = try campaign("c1", seconds: 30, screen: "Checkout")
        XCTAssertEqual(c.triggers?.first?.type, "time_on_screen")
        XCTAssertEqual(c.triggers?.first?.screenName, "Checkout")
        XCTAssertFalse(InAppMessagingManager.displaysOnSync(c))
    }

    func testScreenNameMatchingIsTrimmedCaseInsensitiveAndEmptyMeansAnyScreen() {
        XCTAssertTrue(ScreenClock.screenNameMatches(nil, nil))
        XCTAssertTrue(ScreenClock.screenNameMatches("  ", "Home"))
        XCTAssertTrue(ScreenClock.screenNameMatches("Checkout", " checkout "))
        XCTAssertFalse(ScreenClock.screenNameMatches("Checkout", "CheckoutConfirm"))
        XCTAssertFalse(ScreenClock.screenNameMatches("Checkout", nil))
    }

    func testTheClockRestartsOnANewScreenOnlyAndBackgroundTimeDoesNotCount() {
        let time = FakeTime()
        let clock = ScreenClock(now: { time.now })
        XCTAssertTrue(clock.enter("Home"))
        time.advance(10)
        XCTAssertFalse(clock.enter("home"), "the same screen again is not a new visit")
        XCTAssertEqual(clock.seconds, 10, accuracy: 0.001)
        clock.pause()
        time.advance(100)
        XCTAssertEqual(clock.seconds, 10, accuracy: 0.001)
        clock.resume()
        time.advance(5)
        XCTAssertEqual(clock.seconds, 15, accuracy: 0.001, "resumed, not restarted")
        XCTAssertTrue(clock.enter("Cart"))
        XCTAssertEqual(clock.seconds, 0, accuracy: 0.001)
        XCTAssertEqual(clock.name, "Cart")
    }

    func testItFiresOnTheNamedScreenAfterTheSecondsOncePerVisit() throws {
        let time = FakeTime()
        let manager = makeManager(time: time)
        manager.setActiveCampaignsForTesting([try campaign("c1", seconds: 30, screen: "Checkout")])

        manager.screenViewed("Home")
        time.advance(60)
        XCTAssertEqual(manager.screenCheckDue(), [], "another screen")
        XCTAssertNil(manager.nextScreenDeadline())

        manager.screenViewed("Checkout")
        XCTAssertEqual(manager.nextScreenDeadline() ?? -1, 30, accuracy: 0.001)
        time.advance(29)
        XCTAssertEqual(manager.screenCheckDue(), [])
        time.advance(1)
        XCTAssertEqual(manager.screenCheckDue(), ["c1"])
        time.advance(60)
        XCTAssertEqual(manager.screenCheckDue(), [], "once per visit")

        manager.screenViewed("Home")
        manager.screenViewed("Checkout")
        time.advance(30)
        XCTAssertEqual(manager.screenCheckDue(), ["c1"], "a new visit re-arms it")
    }

    func testWithoutAScreenNameAnyScreenCountsAndBackgroundPausesIt() throws {
        let time = FakeTime()
        let manager = makeManager(time: time)
        manager.setActiveCampaignsForTesting([try campaign("c1", seconds: "10")])
        time.advance(4)
        manager.appLeftForeground()
        time.advance(600)
        XCTAssertNil(manager.nextScreenDeadline(), "nothing is scheduled in the background")
        XCTAssertEqual(manager.screenCheckDue(), [])
        manager.appBecameActive()
        XCTAssertEqual(manager.nextScreenDeadline() ?? -1, 6, accuracy: 0.001, "time before the first trackScreen counts for any screen")
        time.advance(6)
        XCTAssertEqual(manager.screenCheckDue(), ["c1"])
    }

    func testUnusableSecondsNeverFire() throws {
        let time = FakeTime()
        let manager = makeManager(time: time)
        manager.setActiveCampaignsForTesting([try campaign("zero", seconds: 0), try campaign("huge", seconds: 99999), try campaign("text", seconds: "soon")])
        time.advance(100_000)
        XCTAssertEqual(manager.screenCheckDue(), [])
    }

    func testSyncDeclaresScreenContextAlsoWhenAHostDraws() {
        XCTAssertEqual(InAppMessagingManager.withScreenContext(["content.native"]), ["content.native", "screen_context"])
        XCTAssertEqual(InAppMessagingManager.withScreenContext(["screen_context"]), ["screen_context"])
        XCTAssertEqual(ScreenClock.capability, "screen_context")
        XCTAssertEqual(ScreenClock.triggerType, "time_on_screen")
    }

    func testTheSyncRequestCarriesScreenContext() async {
        let manager = makeManager(time: FakeTime())
        manager.setHostRenderer({ _ in }, capabilities: ["content.native"])
        await manager.syncCampaigns(force: true)
        let body = TestSupport.requests("/v1/in-app/sync").last?.json
        XCTAssertEqual(body?["capabilities"] as? [String], ["content.native", "screen_context"])
    }
}
