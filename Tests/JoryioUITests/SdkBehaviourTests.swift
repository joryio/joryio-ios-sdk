import XCTest
import UserNotifications
@testable import Joryio
@testable import JoryioNotificationServiceExtension

/// One test (at least) per bug fixed for 1.3.0. Each names the defect it pins;
/// each failed against the code before the fix.
final class SdkBehaviourTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    // MARK: Booleans on the wire (finding 10)

    func testBooleanNSNumberEncodesAsJSONBoolean() throws {
        // From Objective-C, a React Native / Unity bridge or JSONSerialization,
        // a boolean is an NSNumber - which also matches `as Int`.
        let event = Event(
            type: "t",
            properties: ["flag": NSNumber(value: true), "off": kCFBooleanFalse as Any, "swift": true, "count": 1],
            userId: nil,
            anonymousId: "a",
            sessionId: nil
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        )
        let props = try XCTUnwrap(json["properties"] as? [String: Any])
        let raw = String(data: try JSONEncoder().encode(event), encoding: .utf8) ?? ""
        XCTAssertTrue(raw.contains("\"flag\":true"), raw)
        XCTAssertTrue(raw.contains("\"off\":false"), raw)
        XCTAssertTrue(raw.contains("\"swift\":true"), raw)
        XCTAssertEqual((props["count"] as? NSNumber)?.intValue, 1)
        XCTAssertTrue(raw.contains("\"count\":1"), raw)
    }

    // MARK: Pending attribute queue (findings 11, 25)

    func testArrayAndObjectAttributesAreAcknowledged() {
        let pending = PendingAttributes()
        let sent: [String: Any] = ["tags": ["a", "b"], "address": ["city": "Haifa", "zip": 31000]]
        pending.mark(sent)
        pending.acknowledge(sent)
        XCTAssertTrue(pending.isEmpty, "array/object values used to stay pending forever")
    }

    func testAcknowledgeKeepsAValueChangedMidFlight() {
        let pending = PendingAttributes()
        pending.mark(["tags": ["a"]])
        let sent = pending.snapshot()
        pending.mark(["tags": ["a", "b"]])
        pending.acknowledge(sent)
        XCTAssertEqual(pending.pendingAttributes()["tags"] as? [String], ["a", "b"])
    }

    func testBooleanIsNotTheNumberOne() {
        XCTAssertFalse(PendingAttributes.isSameValue(true, 1))
        XCTAssertTrue(PendingAttributes.isSameValue(NSNumber(value: true), true))
    }

    func testIncrementAndUnsetAreQueuedAndFolded() {
        let pending = PendingAttributes()
        pending.markIncrement("visits", by: 1)
        pending.markIncrement("visits", by: 2)
        pending.markUnset("legacy")
        var snapshot = pending.snapshot()
        XCTAssertEqual(snapshot.increments["visits"], 3)
        XCTAssertEqual(snapshot.unsets, ["legacy"])

        // set then increment folds into the set.
        pending.mark(["score": 10])
        pending.markIncrement("score", by: 5)
        snapshot = pending.snapshot()
        XCTAssertEqual((snapshot.sets["score"] as? NSNumber)?.doubleValue, 15)
        XCTAssertNil(snapshot.increments["score"])

        // An increment arriving mid-flight is still owed after the ack.
        let inFlight = pending.snapshot()
        pending.markIncrement("visits", by: 4)
        pending.acknowledge(inFlight)
        XCTAssertEqual(pending.snapshot().increments["visits"], 4)
        XCTAssertTrue(pending.snapshot().unsets.isEmpty)
    }

    func testIncrementsSurviveARestart() {
        let storage = TestSupport.storage()
        let first = PendingAttributes(storage: storage)
        first.markIncrement("visits", by: 2)
        first.markUnset("old")
        let restored = PendingAttributes(storage: storage)
        XCTAssertEqual(restored.snapshot().increments["visits"], 2)
        XCTAssertEqual(restored.snapshot().unsets, ["old"])
    }

    func testADateAttributeDoesNotStopTheQueueBeingPersisted() {
        let storage = TestSupport.storage()
        let first = PendingAttributes(storage: storage)
        first.mark(["last_purchase": Date(timeIntervalSince1970: 0), "plan": "pro"])
        let restored = PendingAttributes(storage: storage)
        XCTAssertEqual(restored.pendingAttributes()["plan"] as? String, "pro")
        XCTAssertEqual(restored.pendingAttributes()["last_purchase"] as? String, "1970-01-01T00:00:00.000Z")
    }

    // MARK: Timestamps are UTC with a real Z (contract 7)

    func testQueuedEventTimestampsAreUTC() throws {
        let storage = TestSupport.storage()
        let event = Event(type: "t", timestamp: Date(timeIntervalSince1970: 1_700_000_000), userId: nil, anonymousId: "a", sessionId: nil)
        try storage.enqueueEvent(event)
        let json = try XCTUnwrap(storage.dequeueQueuedEvents(limit: 1).first?.json)
        XCTAssertTrue(json.contains("\"timestamp\":\"2023-11-14T22:13:20.000Z\""), json)
    }

    // MARK: Session Start after a timeout (finding 9)

    func testRenewalReportsANewSession() {
        let storage = TestSupport.storage()
        let session = SessionManager(storage: storage, logger: TestSupport.logger(), sessionTimeout: 0.05)
        XCTAssertFalse(session.checkAndRenewSession())
        Thread.sleep(forTimeInterval: 0.1)
        let before = session.getSessionId()
        XCTAssertTrue(session.checkAndRenewSession(), "the caller emits Session Start on this answer")
        XCTAssertNotEqual(session.getSessionId(), before)
    }

    // MARK: reset() gets a new anonymous id (finding 17)

    func testResetMintsANewAnonymousId() {
        let storage = TestSupport.storage()
        let identity = IdentityManager(storage: storage, logger: TestSupport.logger())
        let before = identity.getAnonymousId()
        identity.identify(userId: "u1")
        identity.pending.mark(["plan": "pro"])

        identity.reset()

        XCTAssertNotEqual(identity.getAnonymousId(), before)
        XCTAssertEqual(storage.getAnonymousId(), identity.getAnonymousId(), "and it is persisted")
        XCTAssertNil(identity.getUserId())
        XCTAssertTrue(identity.pending.isEmpty)
    }

    // MARK: Keychain survives reinstall (finding 6)

    func testAReinstallDoesNotInheritTheKeychain() {
        let key = TestSupport.uniqueKey()
        let keychain = InMemorySecureStore()
        let firstInstall = TestSupport.storage(sdkKey: key, secureStore: keychain)
        firstInstall.setUserId("previous-user")
        firstInstall.setDeviceToken("previous-token")
        XCTAssertEqual(firstInstall.getUserId(), "previous-user")

        // Uninstall removes UserDefaults (a fresh suite) and the app container
        // (a fresh directory); the Keychain - the same store - stays.
        let reinstall = TestSupport.storage(sdkKey: key, secureStore: keychain)
        XCTAssertNil(reinstall.getUserId(), "a fresh install reported as the previous install's user")
        XCTAssertNil(reinstall.getDeviceToken())
    }

    func testAnUpgradeKeepsTheKeychain() {
        let key = TestSupport.uniqueKey()
        let defaults = TestSupport.defaults()
        let keychain = InMemorySecureStore()
        let old = TestSupport.storage(sdkKey: key, defaults: defaults, secureStore: keychain)
        old.setUserId("kept")
        // Same defaults domain (an app update): the marker is there.
        XCTAssertEqual(TestSupport.storage(sdkKey: key, defaults: defaults, secureStore: keychain).getUserId(), "kept")
    }

    func testABuildThatPredatesTheMarkerIsAnUpgradeNotAReinstall() {
        let key = TestSupport.uniqueKey()
        let defaults = TestSupport.defaults()
        let keychain = InMemorySecureStore()
        // An older build: an anonymous id in defaults, no marker.
        defaults.set("anon-from-old-build", forKey: "jry_\(key)_anonymous_id")
        keychain.setString("old-user", forKey: "user_id")
        XCTAssertEqual(TestSupport.storage(sdkKey: key, defaults: defaults, secureStore: keychain).getUserId(), "old-user")
    }

    // MARK: Pre-init safety (finding 1, contract 12)

    func testPublicCallsBeforeInitializeDoNotCrashAndOptOutIsRecorded() {
        let sdk = Joryio.shared
        defer {
            UserDefaults.standard.removeObject(forKey: Joryio.pendingOptOutKey)
            UserDefaults.standard.removeObject(forKey: Joryio.pendingWipeKey)
        }
        // Each of these dereferenced an implicitly-unwrapped collaborator.
        sdk.setSubscription(channel: "email", status: "subscribed")
        sdk.addToSubscriptionGroup("g", channel: "email")
        sdk.removeFromSubscriptionGroup("g", channel: "email")
        sdk.addAlias("loyalty_id", name: "L-1")
        sdk.clearInAppMessageCallback()
        sdk.incrementAttribute("n")
        sdk.unsetAttribute("n")
        sdk.trackInAppImpression(campaignId: "c", action: "displayed")
        sdk.unregisterPush()
        sdk.wipeData()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Joryio.pendingWipeKey))

        sdk.optOut()
        XCTAssertTrue(sdk.isUserOptedOut())
        XCTAssertEqual(UserDefaults.standard.object(forKey: Joryio.pendingOptOutKey) as? Bool, true)

        // ...and initialize() honours it, persistently.
        let storage = TestSupport.storage()
        Joryio.applyPreInitOptOut(to: storage)
        XCTAssertTrue(storage.getOptedOut())
        XCTAssertNil(UserDefaults.standard.object(forKey: Joryio.pendingOptOutKey))

        sdk.optIn()
        XCTAssertFalse(sdk.isUserOptedOut())
        Joryio.applyPreInitOptOut(to: storage)
        XCTAssertFalse(storage.getOptedOut())
    }

    // MARK: Push routes at the host root (contract 10)

    func testPushTrackingRoutesAreBuiltOnTheHostRoot() {
        XCTAssertEqual(NetworkClient.trackingRoot(of: "https://api-eu1.joryio.com/api"), "https://api-eu1.joryio.com")
        XCTAssertEqual(NetworkClient.trackingRoot(of: "http://localhost:3000/api"), "http://localhost:3000")
    }

    func testPushClickAndReceiptGoToTheRoot() async throws {
        let network = TestSupport.network()
        try await network.trackPushClick(trackingId: "abc")
        try await network.reportPushDelivered(trackingId: "def")
        let paths = StubURLProtocol.requests.map(\.url.absoluteString)
        XCTAssertEqual(paths, [
            "https://api-eu1.joryio.test/track/push/click/abc",
            "https://api-eu1.joryio.test/track/push/delivered/def",
        ])
    }

    // MARK: unregisterPush tells the backend (finding 13)

    func testUnregisterCallsTheBackend() async throws {
        let network = TestSupport.network()
        try await network.unregisterPushToken(userId: nil, anonymousId: "anon", deviceToken: "tok")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url.path, "/api/v1/push/unregister")
        XCTAssertEqual(request.json?["token"] as? String, "tok")
        XCTAssertEqual(request.json?["platform"] as? String, "ios")
        XCTAssertEqual(request.json?["anonymousId"] as? String, "anon")
    }

    // MARK: addAlias works anonymously (contract 2)

    func testAddAliasCarriesTheAnonymousIdAndNoUserIdWhenAnonymous() async throws {
        let network = TestSupport.network()
        try await network.addAlias(AddAliasRequest(anonymousId: "anon-1", userId: nil, aliasLabel: "loyalty_id", aliasName: "L-1"))
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url.path, "/api/v1/alias/add")
        XCTAssertEqual(request.json?["anonymousId"] as? String, "anon-1")
        XCTAssertNil(request.json?["userId"])
        XCTAssertEqual(request.json?["aliasLabel"] as? String, "loyalty_id")
        XCTAssertEqual(request.json?["aliasName"] as? String, "L-1")
    }

    // MARK: SDK authentication without the flag (bridge requirement)

    func testSettingATokenTurnsSdkAuthenticationOn() {
        let store = SdkAuthTokenStore(enabled: false, initialToken: nil)
        XCTAssertFalse(store.enabled)
        store.setToken("jwt")
        XCTAssertTrue(store.enabled, "Android opts in on a token; iOS dropped it unless the flag was set")
        XCTAssertTrue(SdkAuthTokenStore(enabled: false, initialToken: "seed").enabled)
    }

    // MARK: Permission vocabulary (finding 24, contract 8)

    func testProvisionalAndEphemeralAreGrantedEverywhere() {
        XCTAssertEqual(Joryio.pushPermissionStatus(.provisional), "granted")
        XCTAssertEqual(Joryio.pushPermissionStatus(.ephemeral), "granted")
        XCTAssertEqual(Joryio.pushPermissionStatus(.authorized), "granted")
        XCTAssertEqual(Joryio.pushPermissionStatus(.notDetermined), "notDetermined")
        XCTAssertEqual(Joryio.pushPermissionStatus(.denied), "denied")
    }

    // MARK: Notification Service Extension (finding 14)

    func testExtensionReadsTheContractImageKey() {
        XCTAssertEqual(JoryioNotificationService.imageUrlKey, PushPayloadKeys.imageUrl)
    }

    // MARK: Helpers

}
