import XCTest
import UserNotifications
@testable import Joryio
@testable import JoryioNotificationServiceExtension

/// The second 1.3.0 review (scan 2) and contract addendum 13-23. Each test
/// names the finding it pins and failed against the code before its fix.
final class ReleaseRound2Tests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        UserDefaults.standard.removeObject(forKey: "jry_campaign_impressions")
        UserDefaults.standard.removeObject(forKey: "jry_displayed_campaigns")
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func incrementsSent(_ key: String) -> Double {
        TestSupport.requests("/v1/attributes")
            .compactMap { ($0.json?["increment"] as? [String: Any])?[key] as? NSNumber }
            .reduce(0) { $0 + $1.doubleValue }
    }

    // MARK: 1 - a write during an in-flight flush must not resend the $inc

    func testAWriteDuringAnInFlightFlushDoesNotCountTheIncrementTwice() throws {
        // The first attributes request stays in flight for a while.
        let firstSeen = NSLock()
        var seen = 0
        StubURLProtocol.delayFor = { request in
            guard request.url?.path.hasSuffix("/v1/attributes") == true else { return 0 }
            firstSeen.lock(); defer { firstSeen.unlock() }
            seen += 1
            return seen == 1 ? 1.5 : 0
        }
        let sdk = TestSupport.sdk()

        sdk.incrementAttribute("visits")
        waitUntil { TestSupport.requests("/v1/attributes").count == 1 }

        // A second write while the first request is IN FLIGHT. This used to
        // cancel that request: the server had applied it, the SDK kept the
        // value as unsent, and the next flush sent it again.
        sdk.incrementAttribute("visits")

        waitUntil(timeout: 8) { self.incrementsSent("visits") >= 2 }
        Thread.sleep(forTimeInterval: 1.5)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(incrementsSent("visits"), 2, "two increments of 1 must reach the server as 2, not 3")
    }

    // MARK: 2 / addendum 15 - 2xx success:false is a failure everywhere

    func testSuccessFalseIsAFailureOnEveryRoute() async {
        StubURLProtocol.responder = { _ in (200, Data(#"{"success":false,"error":"db down"}"#.utf8)) }
        let network = TestSupport.network()
        var failures = 0
        do { try await network.setAttributes(SetAttributesRequest(userId: nil, anonymousId: "a", attributes: ["k": 1])) } catch { failures += 1 }
        do { try await network.identify(IdentifyRequest(userId: "u", anonymousId: "a", attributes: [:])) } catch { failures += 1 }
        do { try await network.addAlias(AddAliasRequest(anonymousId: "a", userId: nil, aliasLabel: "l", aliasName: "n")) } catch { failures += 1 }
        do { try await network.updateChannelSubscription(ChannelSubscriptionRequest(channel: "email", status: "subscribed", userId: nil, anonymousId: "a")) } catch { failures += 1 }
        do { try await network.updateSubscriptionGroup(SubscriptionGroupRequest(groupId: "g", channel: "email", action: "subscribe", userId: nil, anonymousId: "a")) } catch { failures += 1 }
        do { try await network.registerPushToken(userId: nil, anonymousId: "a", deviceToken: "t", deviceId: nil, deviceInfo: [:]) } catch { failures += 1 }
        XCTAssertEqual(failures, 6, "a 200 with success:false used to be acknowledged as stored")
    }

    func testAnAttributeTheServerDidNotStoreStaysPending() {
        StubURLProtocol.responder = { request in
            request.url!.path.hasSuffix("/v1/attributes")
                ? (200, Data(#"{"success":false}"#.utf8))
                : (200, Data(#"{"success":true}"#.utf8))
        }
        let storage = TestSupport.storage()
        let sdk = TestSupport.sdk(storage: storage)
        sdk.setAttribute("plan", value: "pro")
        waitUntil { TestSupport.requests("/v1/attributes").count >= 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(PendingAttributes(storage: storage).pendingAttributes()["plan"] as? String, "pro")
    }

    func testAFailedIdentifyIsResentWhenSendingResumes() {
        var fail = true
        StubURLProtocol.responder = { request in
            if request.url!.path.hasSuffix("/v1/identify"), fail { return (200, Data(#"{"success":false}"#.utf8)) }
            return (200, Data(#"{"success":true}"#.utf8))
        }
        let sdk = TestSupport.sdk()
        sdk.identify("user-1")
        waitUntil { TestSupport.requests("/v1/identify").count == 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        fail = false

        // Opt-in is one of the triggers that resends what is owed.
        sdk.optIn()
        waitUntil { TestSupport.requests("/v1/identify").count == 2 }
        XCTAssertEqual(TestSupport.requests("/v1/identify").last?.json?["userId"] as? String, "user-1")
    }

    // MARK: 3 / addendum 14 - the opt-out marker key

    func testTheOptOutRecordUsesAKeyTheBackendKeeps() throws {
        let sdk = TestSupport.sdk()
        sdk.optOut()
        waitUntil { !TestSupport.requests("/v1/attributes").isEmpty }
        let attributes = try XCTUnwrap(TestSupport.requests("/v1/attributes").first?.json?["attributes"] as? [String: Any])
        XCTAssertEqual(attributes["tracking_opted_out"] as? Bool, true)
        XCTAssertNil(attributes["$tracking_opted_out"], "the backend strips $-keys, so the record never landed")

        sdk.optIn()
        waitUntil { TestSupport.requests("/v1/attributes").count >= 2 }
        let cleared = try XCTUnwrap(TestSupport.requests("/v1/attributes").last?.json?["attributes"] as? [String: Any])
        XCTAssertEqual(cleared["tracking_opted_out"] as? Bool, false)
    }

    // MARK: 6 - the reinstall check waits for the first unlock

    func testALaunchBeforeTheFirstUnlockDoesNotWipeTheKeychain() {
        let key = TestSupport.uniqueKey()
        let keychain = InMemorySecureStore()
        let defaults = TestSupport.defaults()
        TestSupport.storage(sdkKey: key, defaults: defaults, secureStore: keychain).setUserId("signed-in")

        // Before first unlock UserDefaults reads as empty (a fresh domain) and
        // the Keychain is locked. That launch looked like a reinstall.
        keychain.locked = true
        _ = TestSupport.storage(sdkKey: key, defaults: TestSupport.defaults(), secureStore: keychain)
        keychain.locked = false

        XCTAssertEqual(keychain.getString(forKey: "user_id"), "signed-in", "a background launch after reboot deleted the user")
        XCTAssertEqual(TestSupport.storage(sdkKey: key, defaults: defaults, secureStore: keychain).getUserId(), "signed-in")
    }

    // MARK: 7 - SDK key rotation keeps the opt-out

    func testAnOptOutSurvivesAnSdkKeyRotation() {
        let defaults = TestSupport.defaults()
        TestSupport.storage(sdkKey: TestSupport.uniqueKey(), defaults: defaults).setOptedOut(true)
        XCTAssertTrue(TestSupport.storage(sdkKey: TestSupport.uniqueKey(), defaults: defaults).getOptedOut(),
                      "a new SDK key in the next release opted everyone back in")
    }

    /// D-c (round 5): every key the SDK writes uses the product's own
    /// prefix; the old product prefix is gone with no migration.
    func testStorageKeysUseTheJoryioPrefixOnly() {
        let defaults = TestSupport.defaults()
        let key = TestSupport.uniqueKey()
        let storage = TestSupport.storage(sdkKey: key, defaults: defaults)
        _ = storage.getAnonymousId()
        _ = storage.getDeviceId()
        storage.setOptedOut(true)
        let written = defaults.dictionaryRepresentation().keys.filter { $0.contains(key) || $0.hasPrefix("joryio_") || $0.hasPrefix("jry_") || $0.hasPrefix("hip") }
        XCTAssertTrue(written.contains("jry_\(key)_anonymous_id"), "\(written)")
        XCTAssertTrue(written.contains("jry_\(key)_device_id"), "\(written)")
        XCTAssertFalse(written.contains { $0.lowercased().hasPrefix("hip") }, "\(written)")
    }

    // MARK: 8 / addendum 17 - the budget is spent only when displayed

    private func makeManager() -> InAppMessagingManager {
        let storage = TestSupport.storage()
        let logger = TestSupport.logger()
        return InAppMessagingManager(
            networkClient: TestSupport.network(),
            storage: storage,
            identityManager: IdentityManager(storage: storage, logger: logger),
            sessionManager: SessionManager(storage: storage, logger: logger, sessionTimeout: 1800),
            logger: logger
        )
    }

    private func campaign(_ id: String, delay: Int? = nil, cap: [String: Any]? = nil) throws -> InAppCampaign {
        var json: [String: Any] = [
            "id": id, "name": id, "type": "modal", "priority": 1,
            "content": ["kind": "native", "title": "Hello", "body": "Body"],
        ]
        if let delay { json["delay"] = delay }
        if let cap { json["frequencyCap"] = cap }
        return try TestSupport.campaign(json)
    }

    func testAHandOffSpendsNothingUntilTheHostReportsDisplayed() async throws {
        let manager = makeManager()
        manager.onMessageReady = { _ in }
        manager.setActiveCampaignsForTesting([try campaign("capped", cap: ["maxImpressions": 1, "timeWindow": "lifetime"])])

        await manager.evaluateCampaigns()
        XCTAssertEqual(manager.impressionCountForTesting("capped"), 0, "the hand-off itself used to spend the budget")

        manager.trackHostImpression(campaignId: "capped", action: "displayed")
        XCTAssertEqual(manager.impressionCountForTesting("capped"), 1)
    }

    // MARK: 9 - a display delay cut short by reset() frees nothing

    func testADelayedMessageCutShortByResetDoesNotFreeTheNextOne() async throws {
        let manager = makeManager()
        manager.setMinimumGapForTesting(0)
        var handed: [String] = []
        manager.onMessageReady = { handed.append($0.id) }
        manager.setActiveCampaignsForTesting([try campaign("delayed", delay: 1)])

        let first = Task { await manager.evaluateCampaigns() }
        try await Task.sleep(nanoseconds: 200_000_000)

        // Logout while it waits; the next user's message takes the slot.
        manager.clear()
        manager.onMessageReady = { handed.append($0.id) }
        manager.setActiveCampaignsForTesting([try campaign("next")])
        await manager.evaluateCampaigns()
        XCTAssertEqual(handed, ["next"])

        await first.value
        XCTAssertTrue(manager.isDisplayingForTesting, "the stale delayed message released the next user's slot")
        XCTAssertEqual(handed, ["next"])
    }

    // MARK: 10 - the extension's content handler runs once

    func testTheExtensionContentHandlerIsCalledExactlyOnce() {
        for _ in 0..<500 {
            let service = JoryioNotificationService()
            let lock = NSLock()
            var calls = 0
            service.prepareForTesting(content: UNMutableNotificationContent()) { _ in
                lock.lock(); calls += 1; lock.unlock()
            }
            DispatchQueue.concurrentPerform(iterations: 4) { _ in service.deliver() }
            XCTAssertEqual(calls, 1)
            if calls != 1 { break }
        }
    }

    // MARK: 11 / addendum 21 - wipeData erases everything but the opt-out

    func testWipeDataErasesTheDeviceAndUnregistersTheToken() throws {
        let storage = TestSupport.storage()
        let sdk = TestSupport.sdk(storage: storage)
        sdk.identify("erase-me")
        let token = String(repeating: "ab12", count: 16) // an APNs token is hex
        sdk.registerPushToken(token)
        waitUntil { !TestSupport.requests("/v1/push/register").isEmpty }
        let deviceId = storage.getDeviceId()
        let anonymousId = sdk.getAnonymousId()

        sdk.wipeData()

        waitUntil { !TestSupport.requests("/v1/push/unregister").isEmpty }
        let unregister = try XCTUnwrap(TestSupport.requests("/v1/push/unregister").first?.json)
        XCTAssertEqual(unregister["token"] as? String, token)
        XCTAssertEqual(unregister["userId"] as? String, "erase-me", "filed under the identity being erased")
        XCTAssertNil(sdk.getDeviceToken())
        XCTAssertNil(storage.getDeviceToken())
        XCTAssertNil(sdk.getUserId())
        XCTAssertNotEqual(sdk.getAnonymousId(), anonymousId)
        XCTAssertNotEqual(storage.getDeviceId(), deviceId, "the device id survived the wipe")
        // Same on every SDK: push stays off after an erasure until the app asks again.
        XCTAssertTrue(storage.isPushUnregistered(), "the next OS token would re-register automatically")
    }

    func testWipeDataKeepsTheOptOut() {
        let storage = TestSupport.storage()
        let sdk = TestSupport.sdk(storage: storage)
        sdk.optOut()
        sdk.wipeData()
        XCTAssertTrue(sdk.isUserOptedOut())
        XCTAssertTrue(storage.getOptedOut())
    }

    // MARK: 12 - reset() starts a session that is announced

    func testResetSendsASessionStartForTheNewSession() throws {
        let storage = TestSupport.storage()
        let sdk = TestSupport.sdk(config: TestSupport.sdkConfig(trackSessionStart: true), storage: storage)
        let before = sdk.getSessionId()

        sdk.reset()

        let after = sdk.getSessionId()
        XCTAssertNotEqual(after, before)
        let sent = TestSupport.requests("/v1/track/batch").flatMap { ($0.json?["events"] as? [[String: Any]]) ?? [] }
        let queued = (try storage.dequeueQueuedEvents(limit: 100)).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.json.utf8))) as? [String: Any]
        }
        let starts = (sent + queued).filter { $0["type"] as? String == "Session Start" && $0["sessionId"] as? String == after }
        // By event id: an event in flight is both sent and still queued
        // until its batch is acknowledged.
        XCTAssertEqual(Set(starts.compactMap { $0["eventId"] as? String }).count, 1, "reset() began a new session and never said so")
    }

    // MARK: 12 - more than 200 unsets go out in several requests

    func testUnsetsAreSentNoMoreThanTheServerTakesPerRequest() {
        let pending = PendingAttributes()
        for i in 0..<250 { pending.markUnset("k\(i)") }
        let first = pending.snapshot()
        XCTAssertEqual(first.unsets.count, 200, "the backend caps unset at 200; 250 was refused with 400 forever")
        pending.acknowledge(first)
        XCTAssertEqual(pending.snapshot().unsets.count, 50)
    }

    func testAllPendingUnsetsAreDeliveredByOneFlush() {
        let storage = TestSupport.storage()
        let sdk = TestSupport.sdk(storage: storage)
        for i in 0..<250 { sdk.unsetAttribute("k\(i)") }
        waitUntil(timeout: 8) {
            TestSupport.requests("/v1/attributes").flatMap { ($0.json?["unset"] as? [String]) ?? [] }.count == 250
        }
        XCTAssertTrue(TestSupport.requests("/v1/attributes").allSatisfy { (($0.json?["unset"] as? [String]) ?? []).count <= 200 })
    }

    // MARK: 12 - one invalid key does not hold every other write hostage

    func testAWriteTheServerRefusesIsSplitAndOnlyTheBadKeyDropped() {
        StubURLProtocol.responder = { request in
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if request.url!.path.hasSuffix("/v1/attributes"), body.contains("bad_key") {
                return (400, Data(#"{"message":"invalid"}"#.utf8))
            }
            return (200, Data(#"{"success":true}"#.utf8))
        }
        let storage = TestSupport.storage()
        let sdk = TestSupport.sdk(storage: storage)
        sdk.setAttributes(["bad_key": "x", "plan": "pro", "city": "Haifa"])

        waitUntil(timeout: 8) { PendingAttributes(storage: storage).isEmpty }
        let accepted = TestSupport.requests("/v1/attributes").filter { !(String(data: $0.body, encoding: .utf8) ?? "").contains("bad_key") }
        let keys = Set(accepted.flatMap { (($0.json?["attributes"] as? [String: Any]) ?? [:]).keys })
        XCTAssertEqual(keys, ["plan", "city"], "a 400 used to keep the whole set pending, refused on every flush")
    }

    // MARK: 12 - a form submission is not retried

    func testAFormSubmissionIsSentOnce() async {
        StubURLProtocol.responder = { _ in (500, Data()) }
        let network = NetworkClient(
            sdkKey: "jry_sdk_ios_test",
            apiEndpoint: "https://api-eu1.joryio.test/api",
            logger: TestSupport.logger(),
            maxRetries: 3,
            retryBackoffMs: 1,
            requestTimeout: 5,
            authStore: SdkAuthTokenStore(enabled: false, initialToken: nil),
            sessionConfiguration: {
                let c = URLSessionConfiguration.ephemeral
                c.protocolClasses = [StubURLProtocol.self]
                return c
            }()
        )
        _ = try? await network.submitInAppForm(InAppFormSubmitRequest(campaignId: "c", userId: nil, anonymousId: "a", values: [:]))
        XCTAssertEqual(TestSupport.requests("/v1/in-app/form-submit").count, 1, "a 5xx after the server stored it submitted the form again")
    }

    // MARK: Date attributes are acknowledged

    func testADateAttributeIsAcknowledged() {
        let pending = PendingAttributes()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        pending.mark(["last_purchase": date])
        pending.acknowledge(pending.snapshot())
        XCTAssertTrue(pending.isEmpty, "a Date never compared equal, so it was re-sent on every flush")
    }

    // MARK: Addendum 16 - identify right after reset uses the NEW anonymous id

    func testIdentifyRightAfterResetUsesTheNewAnonymousId() throws {
        let sdk = TestSupport.sdk()
        sdk.identify("customer-a")
        let anonymousA = sdk.getAnonymousId()

        sdk.reset()
        sdk.identify("customer-b")

        waitUntil { TestSupport.requests("/v1/identify").count == 2 }
        let second = try XCTUnwrap(TestSupport.requests("/v1/identify").first { $0.json?["userId"] as? String == "customer-b" }?.json)
        XCTAssertNotEqual(second["anonymousId"] as? String, anonymousA, "B would be merged with A's anonymous history")
        XCTAssertEqual(second["anonymousId"] as? String, sdk.getAnonymousId())
        XCTAssertEqual(sdk.getUserId(), "customer-b")
    }

    // MARK: Addendum 19 - nil from the host

    func testANilAttributeValueUnsetsTheAttribute() throws {
        let storage = TestSupport.storage()
        let sdk = TestSupport.sdk(storage: storage)
        let nothing: String? = nil
        sdk.setAttribute("nickname", value: nothing)
        sdk.setAttributes(["legacy": NSNull()])
        waitUntil { !TestSupport.requests("/v1/attributes").isEmpty }
        let body = try XCTUnwrap(TestSupport.requests("/v1/attributes").first?.json)
        XCTAssertEqual(Set((body["unset"] as? [String]) ?? []), ["nickname", "legacy"])
        XCTAssertNil(body["attributes"], "null used to be SET as a value")
    }

    func testEmptyRequiredArgumentsAreIgnored() {
        let sdk = TestSupport.sdk()
        sdk.identify("")
        sdk.track("")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(sdk.getUserId(), "identify(\"\") identified the device as an empty user id")
        XCTAssertEqual(sdk.getQueueSize(), 0)
    }

    func testAnEmptySdkAuthTokenChangesNothing() {
        let sdk = TestSupport.sdk()
        sdk.setSdkAuthenticationToken("")
        sdk.identify("u")
        waitUntil { !TestSupport.requests("/v1/identify").isEmpty }
        XCTAssertNil(TestSupport.requests("/v1/identify").first?.headers["X-Joryio-Auth"],
                     "an empty token (a bridge's null) switched SDK authentication on with no credential")
    }

    // MARK: Bridge teardown - the auth-error handler can be removed

    func testClearingTheSdkAuthErrorHandlerStopsCallingIt() {
        StubURLProtocol.responder = { request in
            request.url!.path.hasSuffix("/v1/identify")
                ? (401, Data(#"{"error":"sdk_authentication_error","reason":"expired"}"#.utf8))
                : (200, Data(#"{"success":true}"#.utf8))
        }
        let sdk = TestSupport.sdk()
        sdk.setSdkAuthenticationToken("jwt-1")
        let lock = NSLock()
        var calls = 0
        sdk.setSdkAuthenticationErrorHandler { _ in lock.lock(); calls += 1; lock.unlock() }
        sdk.clearSdkAuthenticationErrorHandler()

        sdk.identify("u")
        waitUntil { !TestSupport.requests("/v1/identify").isEmpty }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(calls, 0)
    }

    // MARK: Addendum 20 - calls before initialize() are kept (cap 1000)

    func testCallsBeforeInitializeAreReplayedInOrder() throws {
        let storage = TestSupport.storage()
        let sdk = TestSupport.sdk(storage: storage, initialize: false)
        sdk.track("before-1")
        sdk.identify("early-user")
        sdk.track("before-2")
        XCTAssertEqual(sdk.preInitCallCountForTesting, 3)

        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: TestSupport.sdkConfig())

        XCTAssertEqual(sdk.getUserId(), "early-user")
        let names = try storage.dequeueQueuedEvents(limit: 10).compactMap {
            ((try? JSONSerialization.jsonObject(with: Data($0.json.utf8))) as? [String: Any])?["type"] as? String
        }
        // No client $identify (contract v5, 59): the server records it.
        XCTAssertEqual(names, ["before-1", "before-2"], "calls before init used to be dropped")
    }

    func testThePreInitBufferIsCappedAt1000OldestFirst() {
        let sdk = TestSupport.sdk(initialize: false)
        for i in 0..<1005 { sdk.track("e\(i)") }
        XCTAssertEqual(sdk.preInitCallCountForTesting, Joryio.maxPreInitCalls)
        XCTAssertEqual(Joryio.maxPreInitCalls, 1000)
    }

    // MARK: Addendum 22 - unregisterPush is durable

    func testUnregisterPushHoldsAcrossARestart() {
        let storage = TestSupport.storage()
        let identity = IdentityManager(storage: storage, logger: TestSupport.logger())
        let first = PushNotificationManager(networkClient: TestSupport.network(), identityManager: identity, storage: storage, logger: TestSupport.logger())
        first.unregisterWithOS = {}
        first.registerDeviceToken("tok", explicit: true)
        waitUntil { TestSupport.requests("/v1/push/register").count == 1 }
        first.unregister()
        waitUntil { TestSupport.requests("/v1/push/unregister").count == 1 }

        // Next launch: the OS hands the token over again, as it does every launch.
        let relaunched = PushNotificationManager(networkClient: TestSupport.network(), identityManager: identity, storage: storage, logger: TestSupport.logger())
        relaunched.didRegisterForRemoteNotifications(deviceToken: Data([0xAB, 0xCD]))
        relaunched.retryRegistrationIfUnconfirmed()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(TestSupport.requests("/v1/push/register").count, 1, "the next launch registered the token again")

        // The app asking again lifts it.
        relaunched.registerDeviceToken("tok", explicit: true)
        waitUntil { TestSupport.requests("/v1/push/register").count == 2 }
    }
}
