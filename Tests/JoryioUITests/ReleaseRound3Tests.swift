import XCTest
import UIKit
@testable import Joryio

/// The third 1.3.0 review (scan 3) and contract addendum v3 (items 24-35).
/// Each test names the finding it pins and failed against the code before
/// its fix.
final class ReleaseRound3Tests: XCTestCase {

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

    private let ok = Data(#"{"success":true}"#.utf8)

    private func queuedTypes(_ storage: StorageManager) throws -> [String] {
        try storage.dequeueEvents(limit: 1000).map(\.type)
    }

    // MARK: S1 - a launch before the first unlock waits for it

    func testInitializeWaitsUntilProtectedDataIsAvailable() throws {
        let storage = TestSupport.storage()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        var unlocked = false
        let sdk = Joryio(environment: Joryio.Environment(
            storage: { _, _ in storage },
            sessionConfiguration: configuration,
            defaults: TestSupport.defaults(),
            systemIntegration: false,
            // The Keychain's answers before / after the first unlock; the
            // production probe decides (scan 4, finding 1).
            secItemCalls: KeychainHelper.SecItemCalls(
                copyMatching: { _ in unlocked ? errSecSuccess : errSecInteractionNotAllowed },
                add: { _ in unlocked ? errSecSuccess : errSecInteractionNotAllowed }
            )
        ))

        sdk.track("before-unlock")
        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: TestSupport.sdkConfig())

        // It used to run on unreadable storage: opt-out false, a NEW
        // anonymous id, no database for the whole process.
        XCTAssertTrue(sdk.isInitializationDeferredForTesting)
        XCTAssertEqual(sdk.getAnonymousId(), "", "the SDK started on unreadable storage")
        XCTAssertEqual(sdk.preInitCallCountForTesting, 1, "calls are still queued while it waits")

        unlocked = true
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        waitUntil { !sdk.getAnonymousId().isEmpty }
        XCTAssertFalse(sdk.isInitializationDeferredForTesting)
        XCTAssertEqual(try queuedTypes(storage), ["before-unlock"])
    }

    // MARK: S2 - a server unregister is retried until it lands, across restarts

    func testAFailedServerUnregisterIsRetriedAfterARestart() {
        var fail = true
        StubURLProtocol.responder = { request in
            if request.url!.path.hasSuffix("/v1/push/unregister"), fail { return (503, Data()) }
            return (200, Data(#"{"success":true}"#.utf8))
        }
        let storage = TestSupport.storage()
        let identity = IdentityManager(storage: storage, logger: TestSupport.logger())
        let first = PushNotificationManager(networkClient: TestSupport.network(), identityManager: identity, storage: storage, logger: TestSupport.logger())
        first.unregisterWithOS = {}
        first.registerDeviceToken("tok-s2", explicit: true)
        waitUntil { TestSupport.requests("/v1/push/register").count == 1 }
        first.unregister()
        waitUntil { TestSupport.requests("/v1/push/unregister").count == 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNotNil(storage.getPendingPushUnregisters(), "a failed unregister used to be forgotten")

        // Next launch, the server is back.
        fail = false
        let relaunched = PushNotificationManager(networkClient: TestSupport.network(), identityManager: identity, storage: storage, logger: TestSupport.logger())
        relaunched.retryPendingUnregisters(force: true)
        waitUntil { TestSupport.requests("/v1/push/unregister").count >= 2 }
        XCTAssertEqual(TestSupport.requests("/v1/push/unregister").last?.json?["token"] as? String, "tok-s2")
        waitUntil { storage.getPendingPushUnregisters() == nil }
    }

    // MARK: S3 - identify / alias / subscriptions survive a restart AND reset()

    func testAnIdentifyThatFailedSurvivesResetAndARestart() throws {
        var fail = true
        StubURLProtocol.responder = { [ok] request in
            if request.url!.path.hasSuffix("/v1/identify"), fail { return (503, Data()) }
            return (200, ok)
        }
        let storage = TestSupport.storage()
        let sdk = TestSupport.sdk(storage: storage)
        sdk.identify("user-s3")
        waitUntil { TestSupport.requests("/v1/identify").count == 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        // reset() used to empty the list: the identify was gone for good.
        sdk.reset()
        XCTAssertEqual(sdk.writeOutboxForTesting?.snapshot().filter { $0.kind == .identify }.count, 1)

        // A restart (new instance on the same storage) still sends it.
        fail = false
        let relaunched = TestSupport.sdk(storage: storage)
        waitUntil { TestSupport.requests("/v1/identify").filter { $0.json?["userId"] as? String == "user-s3" }.count >= 2 }
        waitUntil { relaunched.writeOutboxForTesting?.count == 0 }
        _ = sdk
    }

    // MARK: Contract 28 - 404 retried after the events, bounded; 403 never blocks

    func testASubscriptionAnswered404IsRetriedAfterFlushingEvents() {
        var notFound = 2
        StubURLProtocol.responder = { [ok] request in
            if request.url!.path.hasSuffix("/v1/subscriptions/channel"), notFound > 0 {
                notFound -= 1
                return (404, Data())
            }
            return (200, ok)
        }
        let sdk = TestSupport.sdk()
        sdk.writeOutboxForTesting?.notFoundDelay = 0.05
        sdk.track("creates-profile")
        sdk.setSubscription(channel: "email", status: "subscribed")
        waitUntil { TestSupport.requests("/v1/subscriptions/channel").count == 3 }
        // The events went out before the retry - they create the profile.
        XCTAssertFalse(TestSupport.requests("/v1/track/batch").isEmpty)
        waitUntil { sdk.writeOutboxForTesting?.count == 0 }
    }

    func testASubscriptionStill404IsDroppedAfterFiveAttempts() {
        StubURLProtocol.responder = { [ok] request in
            request.url!.path.hasSuffix("/v1/subscriptions/channel") ? (404, Data()) : (200, ok)
        }
        let sdk = TestSupport.sdk()
        sdk.writeOutboxForTesting?.notFoundDelay = 0.01
        sdk.setSubscription(channel: "sms", status: "unsubscribed")
        waitUntil { sdk.writeOutboxForTesting?.count == 0 }
        XCTAssertEqual(TestSupport.requests("/v1/subscriptions/channel").count, WriteOutbox.maxNotFoundAttempts)
    }

    func testA403OnOneWriteDoesNotBlockTheNext() {
        StubURLProtocol.responder = { [ok] request in
            request.url!.path.hasSuffix("/v1/identify") ? (403, Data()) : (200, ok)
        }
        let sdk = TestSupport.sdk()
        sdk.identify("refused")
        sdk.addAlias("loyalty_id", name: "L-1")
        waitUntil { TestSupport.requests("/v1/alias/add").count == 1 }
        waitUntil { sdk.writeOutboxForTesting?.count == 0 }
    }

    // MARK: S4 / contract 26 - a stale sync answer is discarded, then synced again

    func testASyncInFlightDuringResetIsDiscardedAndRunsAgain() async throws {
        let campaignJSON = #"{"id":"previous-user","name":"p","type":"modal","priority":1,"content":{"kind":"native","title":"t","body":"b"},"triggers":[{"type":"event","event":"never"}]}"#
        var syncs = 0
        let lock = NSLock()
        StubURLProtocol.delayFor = { request in
            request.url!.path.hasSuffix("/v1/in-app/sync") ? 0.8 : 0
        }
        StubURLProtocol.responder = { request in
            guard request.url!.path.hasSuffix("/v1/in-app/sync") else { return (200, Data(#"{"success":true}"#.utf8)) }
            lock.lock(); syncs += 1; let n = syncs; lock.unlock()
            let campaigns = n == 1 ? "[\(campaignJSON)]" : "[]"
            return (200, Data(#"{"success":true,"evaluatedAt":"2026-10-06T00:00:00Z","campaigns":\#(campaigns)}"#.utf8))
        }
        let storage = TestSupport.storage()
        let logger = TestSupport.logger()
        let manager = InAppMessagingManager(
            networkClient: TestSupport.network(),
            storage: storage,
            identityManager: IdentityManager(storage: storage, logger: logger),
            sessionManager: SessionManager(storage: storage, logger: logger, sessionTimeout: 1800),
            logger: logger
        )

        let first = Task { await manager.syncCampaigns(force: true) }
        try await Task.sleep(nanoseconds: 200_000_000)
        // Logout while it is in flight, and the forced re-sync reset() asks for.
        manager.clear()
        await manager.syncCampaigns(force: true)
        await first.value

        XCTAssertFalse(manager.activeCampaignIdsForTesting.contains("previous-user"),
                       "the previous user's campaigns were installed for the next one")
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(syncs, 2, "the forced re-sync asked for during the stale one was skipped")
    }

    // MARK: M1 - an acknowledgement from before reset() clears nothing after it

    func testAnAcknowledgementFromBeforeResetClearsNothingAfterIt() {
        let pending = PendingAttributes()
        pending.mark(["plan": "pro"])
        let sentBeforeReset = pending.snapshot()
        pending.clear()                       // reset()
        pending.mark(["plan": "pro"])         // the next person, same value
        pending.acknowledge(sentBeforeReset)
        XCTAssertEqual(pending.pendingAttributes()["plan"] as? String, "pro",
                       "the previous user's ack cleared the next user's write")
    }

    // MARK: M2 / contract 33 - the opt-out record follows the opt-out, retried

    private func markerValues() -> [Bool] {
        TestSupport.requests("/v1/attributes").compactMap {
            ($0.json?["attributes"] as? [String: Any])?["tracking_opted_out"] as? Bool
        }
    }

    func testTheOptOutRecordIsRetriedUntilStored() {
        var failures = 1
        StubURLProtocol.responder = { [ok] request in
            if request.url!.path.hasSuffix("/v1/attributes"), failures > 0 { failures -= 1; return (503, Data()) }
            return (200, ok)
        }
        let storage = TestSupport.storage()
        let sdk = TestSupport.sdk(storage: storage)
        sdk.writeOutboxForTesting?.baseBackoff = 0.05
        sdk.optOut()
        waitUntil { self.markerValues() == [true, true] }
        waitUntil { storage.getOptOutMarkerAcked() }
    }

    func testTheFalseRecordIsRetriedToo() {
        let storage = TestSupport.storage()
        storage.setOptedOut(true)
        storage.setOptOutMarkerAcked(true)
        var failures = 1
        StubURLProtocol.responder = { [ok] request in
            if request.url!.path.hasSuffix("/v1/attributes"), failures > 0 { failures -= 1; return (200, Data(#"{"success":false}"#.utf8)) }
            return (200, ok)
        }
        let sdk = TestSupport.sdk(storage: storage)
        sdk.writeOutboxForTesting?.baseBackoff = 0.05
        sdk.optIn()
        // It used to be one best-effort request.
        waitUntil { self.markerValues() == [false, false] }
        waitUntil { !storage.getOptOutMarkerAcked() }
    }

    func testAnOptOutDecidedAtInitReachesTheProfile() {
        _ = TestSupport.sdk(config: TestSupport.sdkConfig(optOut: true))
        waitUntil { self.markerValues() == [true] }
    }

    func testNoRecordIsSentWhenNothingChanged() {
        let sdk = TestSupport.sdk()
        sdk.optIn()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(markerValues(), [], "optIn() sent a record every call")
    }

    // MARK: M3 - an optOut() before init keeps unregisterPush()

    func testAPreInitOptOutKeepsUnregisterAndFlush() {
        let sdk = TestSupport.sdk(initialize: false)
        sdk.track("collected")
        sdk.unregisterPush()
        sdk.flush()
        sdk.optOut()
        XCTAssertEqual(sdk.preInitCallCountForTesting, 2, "the opt-out also discarded unregisterPush()")
    }

    // MARK: M4 / contract 32 - Session Start first, and not for a resumed session

    func testSessionStartPrecedesReplayedCallsAndIsNotResent() throws {
        let storage = TestSupport.storage()
        let sdk = TestSupport.sdk(storage: storage, initialize: false)
        sdk.track("before-init")
        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: TestSupport.sdkConfig(trackSessionStart: true))
        XCTAssertEqual(try queuedTypes(storage), ["Session Start", "before-init"],
                       "Session Start was queued behind the calls of the session it opens")

        // A cold start inside the session timeout resumes it: no new Session Start.
        _ = TestSupport.sdk(config: TestSupport.sdkConfig(trackSessionStart: true), storage: storage)
        XCTAssertEqual(try queuedTypes(storage).filter { $0 == "Session Start" }.count, 1)
    }

    // MARK: M5 - a delete that fails does not resend the same rows in a loop

    final class FailingDeleteStorage: StorageManager {
        override func deleteEvents(ids: [Int64]) throws { throw StorageError.databaseNotInitialized }
    }

    func testADeleteFailureStopsTheFlush() async throws {
        let storage = FailingDeleteStorage(
            sdkKey: TestSupport.uniqueKey(),
            logger: TestSupport.logger(),
            databaseDirectory: TestSupport.tempDirectory(),
            userDefaults: TestSupport.defaults(),
            secureStore: InMemorySecureStore()
        )
        try storage.enqueueEvent(TestSupport.event("a"))
        let sender = EventQueueContractTests.FakeSender()
        let queue = QueueManager(storage: storage, sender: sender, logger: TestSupport.logger(), batchSize: 50,
                                 flushInterval: 3600, maxQueueSize: 1000, sendImmediately: false, startTimer: false)
        await queue.flush()
        XCTAssertEqual(sender.sent.count, 1, "the same rows were re-sent in a tight loop")
    }

    // MARK: Contract 24 - consent model A

    func testStartConsentRules() {
        XCTAssertEqual(Joryio.startConsent(preInit: nil, config: nil, storedDenied: false), .granted)
        XCTAssertEqual(Joryio.startConsent(preInit: nil, config: nil, storedDenied: true), .denied)
        XCTAssertEqual(Joryio.startConsent(preInit: nil, config: .pending, storedDenied: true), .denied)
        XCTAssertEqual(Joryio.startConsent(preInit: nil, config: .pending, storedDenied: false), .pending)
        XCTAssertEqual(Joryio.startConsent(preInit: nil, config: .granted, storedDenied: true), .granted)
        XCTAssertEqual(Joryio.startConsent(preInit: .denied, config: .granted, storedDenied: false), .denied)
    }

    func testDeniedIsStoredAndOnlyAnExplicitGrantLiftsIt() {
        let storage = TestSupport.storage()
        let first = TestSupport.sdk(storage: storage)
        first.updateConsent(.denied)

        // Next launch with the default (unset) config: still denied. It used to
        // be forgotten, and the default config said `granted`.
        let unset = TestSupport.sdk(config: JoryioConfig(flushInterval: 3600, trackSessionStart: false, inApp: InAppConfig(enabled: false), maxRetries: 0), storage: storage)
        XCTAssertEqual(unset.getTrackingConsent(), .denied)
        unset.track("must-not-collect")
        XCTAssertEqual(unset.getQueueSize(), 0)

        let pending = TestSupport.sdk(config: TestSupport.sdkConfig(trackingConsent: .pending), storage: storage)
        XCTAssertEqual(pending.getTrackingConsent(), .denied, "pending overrode a stored denied")
        pending.updateConsent(.pending)
        XCTAssertEqual(pending.getTrackingConsent(), .denied)

        let granted = TestSupport.sdk(config: TestSupport.sdkConfig(trackingConsent: .granted), storage: storage)
        XCTAssertEqual(granted.getTrackingConsent(), .granted)
        XCTAssertFalse(storage.getConsentDenied())
    }

    func testGrantingConsentNeverLiftsAnOptOut() {
        let sdk = TestSupport.sdk()
        sdk.optOut()
        sdk.updateConsent(.denied)
        sdk.updateConsent(.granted)
        XCTAssertTrue(sdk.isUserOptedOut())
        sdk.track("x")
        XCTAssertEqual(sdk.getQueueSize(), 0)
    }

    func testAConsentDecisionBeforeInitIsAppliedBeforeAnyInitSideEffect() throws {
        let storage = TestSupport.storage()
        let sdk = TestSupport.sdk(storage: storage, initialize: false)
        sdk.updateConsent(.denied)
        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: TestSupport.sdkConfig(trackSessionStart: true))
        XCTAssertEqual(try queuedTypes(storage), [], "a Session Start was recorded before the denial applied")
        XCTAssertTrue(storage.getConsentDenied())
    }

    // MARK: Contract 29 - permanent refusals

    func testRejectedIndicesAreDroppedNotRetried() {
        func classify(_ body: String) -> NetworkClient.BatchOutcome {
            NetworkClient.classifyBatchResponse(status: 200, body: Data(body.utf8), retryAfterHeader: nil, batchCount: 4)
        }
        XCTAssertEqual(classify(#"{"success":false,"failedIndices":[1,2],"rejectedIndices":[2]}"#), .partial(failedIndices: [1]))
        XCTAssertEqual(classify(#"{"success":false,"rejectedIndices":[0,3]}"#), .partial(failedIndices: [1, 2]))
        XCTAssertEqual(classify(#"{"success":true,"rejectedIndices":[0]}"#), .partial(failedIndices: []))
    }

    func testEventsTheServerWouldRefuseAreDroppedAtTrack() {
        let sdk = TestSupport.sdk()
        var many: [String: Any] = [:]
        for i in 0..<201 { many["k\(i)"] = i }
        sdk.track("too-many-keys", properties: many)
        sdk.track(String(repeating: "n", count: 256))
        // Six levels (the properties object is level 1): the server refuses it.
        sdk.track("too-deep", properties: ["a": ["b": ["c": ["d": ["e": ["f": 1]]]]]])
        sdk.track("too-big", properties: ["blob": String(repeating: "x", count: 52_000)])
        sdk.track("", properties: [:])
        XCTAssertEqual(sdk.getQueueSize(), 0)
        // Exactly the server's limits, which it ACCEPTS: five levels with a
        // plain value at the deepest; 200 top-level keys with more nested
        // keys (only top-level keys count); Hebrew text under 51,200
        // characters (measured in characters, not UTF-8 bytes).
        sdk.track("five-levels", properties: ["a": ["b": ["c": ["d": ["e": 1]]]]])
        var wide: [String: Any] = [:]
        for i in 0..<199 { wide["k\(i)"] = i }
        wide["nested"] = Dictionary(uniqueKeysWithValues: (0..<50).map { ("n\($0)", $0) })
        sdk.track("nested-keys", properties: wide)
        sdk.track("hebrew", properties: ["text": String(repeating: "ש", count: 40_000)])
        XCTAssertEqual(sdk.getQueueSize(), 3)
    }

    // MARK: Contract 30 - SDK authentication and users

    private func event(_ name: String, user: String?) -> Event {
        Event(type: name, userId: user, anonymousId: "anon", sessionId: "s")
    }

    func testABatchNeverMixesUsersAndAPreviousUsersRefusedEventsAreDropped() async throws {
        let storage = TestSupport.storage()
        try storage.enqueueEvent(event("a1", user: "alice"))
        try storage.enqueueEvent(event("a2", user: "alice"))
        try storage.enqueueEvent(event("b1", user: "bob"))
        let sender = EventQueueContractTests.FakeSender()
        sender.answers = [{ _ in .authFailed(reason: .subMismatch) }, { _ in .accepted }]
        let queue = QueueManager(storage: storage, sender: sender, logger: TestSupport.logger(), batchSize: 50,
                                 flushInterval: 3600, maxQueueSize: 1000, sendImmediately: false, startTimer: false)
        queue.currentUserId = { "bob" }
        await queue.flush()
        XCTAssertEqual(sender.sent.map(\.count), [2, 1], "a batch mixed two users' events")
        XCTAssertEqual(storage.getQueueSize(), 0, "alice's refused events blocked bob's for good")
    }

    func testTheAuthHandlerIsCalledWhenNoTokenWasEverSet() {
        StubURLProtocol.responder = { [ok] request in
            request.url!.path.hasSuffix("/v1/identify")
                ? (401, Data(#"{"error":"sdk_authentication_error","reason":"missing"}"#.utf8))
                : (200, ok)
        }
        let sdk = TestSupport.sdk(config: JoryioConfig(
            flushInterval: 3600, trackSessionStart: false, inApp: InAppConfig(enabled: false),
            maxRetries: 0, enableSdkAuthentication: true
        ))
        let lock = NSLock()
        var reasons: [SdkAuthErrorReason] = []
        sdk.setSdkAuthenticationErrorHandler { error in lock.lock(); reasons.append(error.reason); lock.unlock() }
        sdk.identify("needs-a-token")
        waitUntil { lock.lock(); defer { lock.unlock() }; return reasons.contains(.missing) }
    }

    // MARK: Contract 35 - a forced flush skips the SDK's backoff, never Retry-After

    func testAForcedFlushHonoursRetryAfter() async throws {
        let storage = TestSupport.storage()
        try storage.enqueueEvent(TestSupport.event("a"))
        let sender = EventQueueContractTests.FakeSender()
        sender.defaultAnswer = .retryLater(retryAfter: 60)
        let queue = QueueManager(storage: storage, sender: sender, logger: TestSupport.logger(), batchSize: 50,
                                 flushInterval: 3600, maxQueueSize: 1000, sendImmediately: false, startTimer: false)
        await queue.flush()
        queue.resetBackoff()
        await queue.flush(force: true)
        XCTAssertEqual(sender.sent.count, 1, "consent granted / a manual flush ignored the server's Retry-After")
        XCTAssertTrue(queue.isWaitingForRetryAfter)
    }

    func testAForcedFlushSkipsTheSdksOwnBackoff() async throws {
        let storage = TestSupport.storage()
        try storage.enqueueEvent(TestSupport.event("a"))
        let sender = EventQueueContractTests.FakeSender()
        sender.answers = [{ _ in .retryLater(retryAfter: nil) }]
        let queue = QueueManager(storage: storage, sender: sender, logger: TestSupport.logger(), batchSize: 50,
                                 flushInterval: 3600, maxQueueSize: 1000, sendImmediately: false, startTimer: false)
        await queue.flush()
        await queue.flush()
        XCTAssertEqual(sender.sent.count, 1)
        await queue.flush(force: true)
        XCTAssertEqual(sender.sent.count, 2)
    }
}
