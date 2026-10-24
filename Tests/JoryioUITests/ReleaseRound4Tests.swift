import XCTest
import UIKit
@testable import Joryio

/// The fourth 1.3.0 review (scan 4, iOS) and contract addendum v4 (items
/// 36-48). Each test names the finding or item it pins and failed against
/// the code before its fix (the reason is in the test's comment).
final class ReleaseRound4Tests: XCTestCase {

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

    private func paths(_ suffixes: [String]) -> [String] {
        StubURLProtocol.requests.map(\.url.path).filter { path in suffixes.contains { path.hasSuffix($0) } }
    }

    /// An SDK whose environment and storage share one UserDefaults, as in
    /// production (both `.standard`).
    private func sdk(
        config: JoryioConfig = TestSupport.sdkConfig(),
        defaults: UserDefaults = TestSupport.defaults(),
        initialize: Bool = true,
        secItemCalls: KeychainHelper.SecItemCalls? = nil
    ) -> (Joryio, StorageManager) {
        let storage = TestSupport.storage(defaults: defaults)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let sdk = Joryio(environment: Joryio.Environment(
            storage: { _, _ in storage },
            sessionConfiguration: configuration,
            defaults: defaults,
            systemIntegration: false,
            secItemCalls: secItemCalls ?? TestSupport.unlockedKeychain
        ))
        if initialize {
            sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: config)
        }
        return (sdk, storage)
    }

    private static func calls(read: @escaping () -> OSStatus, add: @escaping () -> OSStatus = { errSecSuccess }) -> KeychainHelper.SecItemCalls {
        KeychainHelper.SecItemCalls(copyMatching: { _ in read() }, add: { _ in add() })
    }

    // MARK: Finding 1 - locked is not "before the first unlock"

    /// The PRODUCTION decision, with the statuses the Keychain gives.
    func testTheProbeDefersOnlyBeforeTheFirstUnlock() {
        let service = "probe-test"
        // Unlocked since boot - screen locked or not: the probe item reads.
        XCTAssertTrue(KeychainHelper.probeProtectedData(service: service, calls: Self.calls(read: { errSecSuccess })))
        // Before the first unlock: AfterFirstUnlock items cannot be read.
        XCTAssertFalse(KeychainHelper.probeProtectedData(service: service, calls: Self.calls(read: { errSecInteractionNotAllowed })))
        // A fresh install before the first unlock (no probe item yet): the
        // write is refused too. The old probe read "no items" as available
        // and started on unreadable storage.
        XCTAssertFalse(KeychainHelper.probeProtectedData(service: service, calls: Self.calls(read: { errSecItemNotFound }, add: { errSecInteractionNotAllowed })))
        XCTAssertTrue(KeychainHelper.probeProtectedData(service: service, calls: Self.calls(read: { errSecItemNotFound }, add: { errSecSuccess })))
        // A probe that cannot answer never holds the SDK back for good.
        XCTAssertTrue(KeychainHelper.probeProtectedData(service: service, calls: Self.calls(read: { errSecMissingEntitlement })))
    }

    /// The SDK runs that probe on every thread. It used to ask
    /// `UIApplication.isProtectedDataAvailable` on the main thread - false
    /// whenever the screen is locked - so a silent push on a locked phone
    /// deferred the whole SDK: no receipt, no sync.
    func testALockedDeviceUnlockedSinceBootStartsAtOnceOnAnyThread() {
        let unlockedSinceBoot = Self.calls(read: { errSecSuccess })
        let (onMain, _) = sdk(secItemCalls: unlockedSinceBoot)
        XCTAssertFalse(onMain.isInitializationPending)
        XCTAssertFalse(onMain.getAnonymousId().isEmpty)

        let (onBackground, _) = sdk(initialize: false, secItemCalls: unlockedSinceBoot)
        let done = expectation(description: "background init")
        DispatchQueue.global().async {
            onBackground.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: TestSupport.sdkConfig())
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertFalse(onBackground.isInitializationPending)
        XCTAssertFalse(onBackground.getAnonymousId().isEmpty)
    }

    /// The real Keychain (no seam at all), from the main thread and from a
    /// background one: an unlocked simulator is never "before first unlock".
    func testTheSystemKeychainProbeAnswersOnEveryThread() {
        let key = TestSupport.uniqueKey()
        XCTAssertTrue(KeychainHelper(sdkKey: key).isProtectedDataAvailable())
        let done = expectation(description: "background probe")
        var background = false
        DispatchQueue.global().async {
            background = KeychainHelper(sdkKey: key).isProtectedDataAvailable()
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(background)
    }

    /// The unlock lands between the check and the observer: its notification
    /// is never seen. The SDK used to stay deferred for the whole process.
    func testAnUnlockBetweenTheCheckAndTheObserverIsNotMissed() {
        var reads = 0
        let unlocksAfterFirstLook = Self.calls(read: {
            reads += 1
            return reads == 1 ? errSecInteractionNotAllowed : errSecSuccess
        })
        let (sdk, _) = sdk(secItemCalls: unlocksAfterFirstLook)
        // No protectedDataDidBecomeAvailable is posted.
        XCTAssertFalse(sdk.isInitializationPending)
        XCTAssertFalse(sdk.getAnonymousId().isEmpty)
    }

    // MARK: Finding 2 - a pending unregister never lands after a re-register

    private func pushManager(_ storage: StorageManager) -> PushNotificationManager {
        let identity = IdentityManager(storage: storage, logger: TestSupport.logger())
        let push = PushNotificationManager(networkClient: TestSupport.network(), identityManager: identity, storage: storage, logger: TestSupport.logger())
        push.unregisterWithOS = {}
        return push
    }

    /// An explicit registration of the same token cancels the unregister
    /// still waiting. It used to be retried later and switch push off for
    /// good, with the app believing it was on.
    func testRegisteringTheSameTokenAgainCancelsItsPendingUnregister() {
        var unregisterFails = true
        StubURLProtocol.responder = { [ok] request in
            if request.url!.path.hasSuffix("/v1/push/unregister"), unregisterFails { return (503, Data()) }
            return (200, ok)
        }
        let storage = TestSupport.storage()
        let push = pushManager(storage)
        push.registerDeviceToken("tok-f2", explicit: true)
        waitUntil { TestSupport.requests("/v1/push/register").count == 1 }
        push.unregister()
        waitUntil { TestSupport.requests("/v1/push/unregister").count == 1 }
        waitUntil { storage.getPendingPushUnregisters() != nil }

        unregisterFails = false
        push.registerDeviceToken("tok-f2", explicit: true)
        waitUntil { TestSupport.requests("/v1/push/register").count == 2 }
        push.retryPendingUnregisters(force: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertEqual(TestSupport.requests("/v1/push/unregister").count, 1, "the cancelled unregister was sent after the registration")
        XCTAssertNil(storage.getPendingPushUnregisters())
    }

    /// Another token's pending unregister goes FIRST - confirmed before the
    /// registration is sent (Android parity).
    func testAPendingUnregisterIsSentBeforeAnyRegistration() {
        var unregisterFailures = 1
        StubURLProtocol.responder = { [ok] request in
            if request.url!.path.hasSuffix("/v1/push/unregister"), unregisterFailures > 0 {
                unregisterFailures -= 1
                return (503, Data())
            }
            return (200, ok)
        }
        let storage = TestSupport.storage()
        let push = pushManager(storage)
        push.registerDeviceToken("tok-old", explicit: true)
        waitUntil { TestSupport.requests("/v1/push/register").count == 1 }
        push.unregister()
        waitUntil { TestSupport.requests("/v1/push/unregister").count == 1 }
        waitUntil { storage.getPendingPushUnregisters() != nil }

        push.registerDeviceToken("tok-new", explicit: true)
        waitUntil { TestSupport.requests("/v1/push/register").count == 2 }

        let order = paths(["/v1/push/register", "/v1/push/unregister"])
        XCTAssertEqual(order.map { $0.hasSuffix("/unregister") ? "U" : "R" }, ["R", "U", "U", "R"],
                       "the pending unregister must be confirmed before the new registration")
        XCTAssertEqual(TestSupport.requests("/v1/push/register").last?.json?["token"] as? String, "tok-new")
        XCTAssertNil(storage.getPendingPushUnregisters())
    }

    func testARegistrationWaitsWhileAnUnregisterCannotBeConfirmed() {
        StubURLProtocol.responder = { [ok] request in
            request.url!.path.hasSuffix("/v1/push/unregister") ? (503, Data()) : (200, ok)
        }
        let storage = TestSupport.storage()
        let push = pushManager(storage)
        push.registerDeviceToken("tok-a", explicit: true)
        waitUntil { TestSupport.requests("/v1/push/register").count == 1 }
        push.unregister()
        waitUntil { storage.getPendingPushUnregisters() != nil }

        var result: PushRegistrationResult?
        push.registerDeviceToken("tok-b", explicit: true) { result = $0 }
        waitUntil { result != nil }
        XCTAssertEqual(result?.success, false)
        XCTAssertEqual(result?.isRetryable, true)
        XCTAssertEqual(TestSupport.requests("/v1/push/register").count, 1, "registered while an earlier unregister was still pending")
    }

    // MARK: Finding 3 / v4 36 - withdrawals are always delivered

    /// An opted-out person can still unsubscribe. The call used to be
    /// refused, and the marketing kept coming.
    func testAnOptedOutUserCanUnsubscribeButNotSubscribe() {
        let (sdk, _) = sdk()
        sdk.optOut()
        sdk.setSubscription(channel: "email", status: "subscribed")
        sdk.setSubscription(channel: "sms", status: "unsubscribed")
        sdk.removeFromSubscriptionGroup("weekly", channel: "email")
        sdk.addToSubscriptionGroup("daily", channel: "email")
        waitUntil { TestSupport.requests("/v1/subscriptions/channel").count == 1 && TestSupport.requests("/v1/subscriptions/group").count == 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let channel = TestSupport.requests("/v1/subscriptions/channel")
        XCTAssertEqual(channel.count, 1)
        XCTAssertEqual(channel.first?.json?["channel"] as? String, "sms")
        XCTAssertEqual(channel.first?.json?["status"] as? String, "unsubscribed")
        let group = TestSupport.requests("/v1/subscriptions/group")
        XCTAssertEqual(group.count, 1)
        XCTAssertEqual(group.first?.json?["action"] as? String, "unsubscribe")
    }

    /// A queued unsubscribe survives optOut(), consent denied and
    /// wipeData(), and is delivered when the server answers again. Each of
    /// the three used to discard it.
    func testAQueuedUnsubscribeSurvivesOptOutDenialAndWipe() {
        var fail = true
        StubURLProtocol.responder = { [ok] request in
            if request.url!.path.hasSuffix("/v1/subscriptions/channel"), fail { return (503, Data()) }
            return (200, ok)
        }
        let (sdk, _) = sdk()
        sdk.setSubscription(channel: "email", status: "unsubscribed")
        waitUntil { TestSupport.requests("/v1/subscriptions/channel").count == 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        sdk.optOut()
        sdk.updateConsent(.denied)
        sdk.wipeData()
        XCTAssertEqual(sdk.writeOutboxForTesting?.snapshot().filter { $0.kind == .subscription }.count, 1)

        fail = false
        sdk.writeOutboxForTesting?.kick(force: true)
        waitUntil { TestSupport.requests("/v1/subscriptions/channel").count >= 2 }
        waitUntil { sdk.writeOutboxForTesting?.snapshot().contains { $0.kind == .subscription } == false }
        XCTAssertEqual(TestSupport.requests("/v1/subscriptions/channel").last?.json?["status"] as? String, "unsubscribed")
    }

    /// An unsubscribe made before init survives an optOut() made before
    /// init. The opt-out used to purge it from the pre-init buffer.
    func testAnUnsubscribeBeforeInitSurvivesAnOptOutBeforeInit() {
        let (sdk, _) = sdk(initialize: false)
        sdk.setSubscription(channel: "email", status: "unsubscribed")
        sdk.optOut()
        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: TestSupport.sdkConfig())
        waitUntil { TestSupport.requests("/v1/subscriptions/channel").count == 1 }
        XCTAssertTrue(sdk.isUserOptedOut())
    }

    /// The opt-out record goes out while consent is pending (and denied).
    /// It used to wait for consent granted.
    func testTheOptOutRecordIsDeliveredWhileConsentIsPending() {
        let (sdk, _) = sdk(config: TestSupport.sdkConfig(trackingConsent: .pending))
        sdk.optOut()
        waitUntil {
            TestSupport.requests("/v1/attributes").contains {
                (($0.json?["attributes"] as? [String: Any])?["tracking_opted_out"] as? Bool) == true
            }
        }
    }

    // MARK: v4 37 - a newer write for the same subject replaces a queued one

    func testANewerSubscriptionChangeReplacesAQueuedOlderOne() {
        // Held: collection waits for consent, and the server refuses the
        // unsubscribe (which is sent at once) so it stays queued too.
        StubURLProtocol.responder = { [ok] request in
            request.url!.path.hasSuffix("/v1/subscriptions/channel") ? (503, Data()) : (200, ok)
        }
        let (sdk, _) = sdk(config: TestSupport.sdkConfig(trackingConsent: .pending))
        sdk.setSubscription(channel: "email", status: "subscribed")
        sdk.setSubscription(channel: "email", status: "unsubscribed")
        sdk.setSubscription(channel: "sms", status: "subscribed")
        let queued = sdk.writeOutboxForTesting?.snapshot().filter { $0.kind == .subscription } ?? []
        XCTAssertEqual(queued.count, 2, "the older email change stayed queued behind the newer one")
        XCTAssertTrue(queued.contains { $0.body.contains("\"unsubscribed\"") })
    }

    // MARK: v4 38 - ids are resolved when a write is sent

    /// A signup made while anonymous and sent after identify() goes out
    /// under the user. It used to carry the anonymous id only, which SDK
    /// authentication refuses for an identified profile (403).
    func testAWriteMadeAnonymouslyIsSentUnderTheUserIdentifiedSince() {
        var fail = true
        StubURLProtocol.responder = { [ok] request in
            if request.url!.path.hasSuffix("/v1/subscriptions/channel"), fail { return (503, Data()) }
            return (200, ok)
        }
        let (sdk, _) = sdk()
        sdk.setSubscription(channel: "email", status: "subscribed")
        waitUntil { TestSupport.requests("/v1/subscriptions/channel").count == 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotNil(TestSupport.requests("/v1/subscriptions/channel").first?.json?["anonymousId"])

        sdk.identify("user-38")
        fail = false
        sdk.writeOutboxForTesting?.kick(force: true)
        waitUntil { TestSupport.requests("/v1/subscriptions/channel").count >= 2 }
        let sent = TestSupport.requests("/v1/subscriptions/channel").last?.json
        XCTAssertEqual(sent?["userId"] as? String, "user-38")
        XCTAssertNil(sent?["anonymousId"], "a subscription carries one identifier")
    }

    /// A write of a previous identity keeps its own ids.
    func testAWriteOfAPreviousIdentityKeepsItsOwnIds() throws {
        var fail = true
        StubURLProtocol.responder = { [ok] request in
            if request.url!.path.hasSuffix("/v1/subscriptions/channel"), fail { return (503, Data()) }
            return (200, ok)
        }
        let (sdk, _) = sdk()
        let anonymous = sdk.getAnonymousId()
        sdk.setSubscription(channel: "email", status: "subscribed")
        waitUntil { TestSupport.requests("/v1/subscriptions/channel").count == 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        sdk.reset()
        sdk.identify("someone-else")
        fail = false
        sdk.writeOutboxForTesting?.kick(force: true)
        waitUntil { TestSupport.requests("/v1/subscriptions/channel").count >= 2 }
        let sent = TestSupport.requests("/v1/subscriptions/channel").last?.json
        XCTAssertNil(sent?["userId"])
        XCTAssertEqual(sent?["anonymousId"] as? String, anonymous)
    }

    // MARK: v4 39 - SDK authentication after logout

    final class AuthFailingSender: EventBatchSender {
        let reason: SdkAuthErrorReason
        init(reason: SdkAuthErrorReason) { self.reason = reason }
        func sendEventBatch(_ eventsJSON: [String], userId: String?) async -> NetworkClient.BatchOutcome {
            .authFailed(reason: reason)
        }
    }

    /// A previous user's events refused as `expired` (or `invalid`) are
    /// dropped. Only `sub_mismatch` / `missing` were, so an expired token of
    /// a user who logged out blocked the next user's events for good.
    func testAPreviousUsersEventsAreDroppedOnAnySdkAuthReason() async throws {
        for reason in [SdkAuthErrorReason.expired, .invalid] {
            let storage = TestSupport.storage()
            try storage.enqueueEvent(Event(type: "old", userId: "user-a", anonymousId: "anon", sessionId: "s"))
            let queue = QueueManager(
                storage: storage, sender: AuthFailingSender(reason: reason), logger: TestSupport.logger(),
                batchSize: 50, flushInterval: 3600, maxQueueSize: 1000, sendImmediately: false, startTimer: false
            )
            queue.currentUserId = { "user-b" }
            await queue.flush(force: true)
            XCTAssertEqual(try queuedTypes(storage), [], "reason \(reason.rawValue)")
        }
    }

    /// The auth-error handler hears only about the CURRENT user's requests:
    /// a previous user's leftover must never make the host sign out, or
    /// re-mint for, the person now signed in.
    func testTheAuthHandlerIsNotAskedAboutAPreviousUsersWrite() async {
        StubURLProtocol.responder = { _ in (401, Data(#"{"error":"sdk_authentication_error","reason":"expired"}"#.utf8)) }
        let authStore = SdkAuthTokenStore(enabled: true, initialToken: "tok")
        var calls = 0
        authStore.setHandler { _ in calls += 1 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let network = NetworkClient(
            sdkKey: "jry_sdk_ios_test", apiEndpoint: "https://api-eu1.joryio.test/api", logger: TestSupport.logger(),
            maxRetries: 0, retryBackoffMs: 1, requestTimeout: 5, authStore: authStore, sessionConfiguration: configuration
        )
        network.currentUserId = { "user-b" }

        let leftover = await network.sendWrite(path: "/v1/identify", body: Data("{}".utf8), userId: "user-a")
        XCTAssertEqual(leftover, .authRejected(reason: .expired))
        XCTAssertEqual(calls, 0, "the handler was asked about another user's write")

        _ = await network.sendWrite(path: "/v1/identify", body: Data("{}".utf8), userId: "user-b")
        XCTAssertGreaterThan(calls, 0, "the current user's refusal still reaches the handler")
    }

    /// reset() forgets the SDK-authentication token for the session; the
    /// next visitor's requests never carry it.
    func testResetClearsTheSdkAuthenticationToken() {
        let config = JoryioConfig(
            flushInterval: 3600, trackSessionStart: false, inApp: InAppConfig(enabled: false), maxRetries: 0,
            sdkAuthenticationToken: "token-of-a", trackingConsent: .granted
        )
        let (sdk, _) = sdk(config: config)
        sdk.identify("user-a")
        sdk.reset()
        StubURLProtocol.reset()
        sdk.track("after-logout")
        sdk.flush()
        waitUntil { TestSupport.requests("/v1/track/batch").contains { String(decoding: $0.body, as: UTF8.self).contains("after-logout") } }
        let request = TestSupport.requests("/v1/track/batch").first { String(decoding: $0.body, as: UTF8.self).contains("after-logout") }
        XCTAssertNil(request?.headers["X-Joryio-Auth"], "the previous user's token was still attached")
    }

    /// Round 4 integration: a NORMAL logout must not drop the outgoing
    /// user's last events. reset() used to clear the token outright, so
    /// user A's still-queued batch went out with no token, got a 401 and was
    /// dropped. A's leftovers now carry A's own token; the next visitor's
    /// requests still carry none.
    func testResetSendsTheOutgoingUsersLeftoversWithTheirOwnToken() {
        // The server's rule: an identified userId needs a token for that user.
        StubURLProtocol.responder = { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let token = request.value(forHTTPHeaderField: "X-Joryio-Auth")
            if body.contains("\"user-a\""), token != "token-of-a" {
                return (401, Data(#"{"error":"sdk_authentication_error","reason":"missing"}"#.utf8))
            }
            return (200, Data(#"{"success":true,"processed":1}"#.utf8))
        }
        let config = JoryioConfig(
            flushInterval: 3600, trackSessionStart: false, inApp: InAppConfig(enabled: false), maxRetries: 0,
            sdkAuthenticationToken: "token-of-a", trackingConsent: .granted
        )
        let (sdk, storage) = sdk(config: config)
        sdk.identify("user-a")
        sdk.track("a-last-purchase")
        sdk.reset()
        sdk.track("after-logout")
        sdk.flush()

        let batches = { TestSupport.requests("/v1/track/batch") }
        func batch(_ name: String) -> StubURLProtocol.Captured? {
            batches().first { String(decoding: $0.body, as: UTF8.self).contains(name) }
        }
        waitUntil { batch("a-last-purchase") != nil && batch("after-logout") != nil }
        XCTAssertEqual(batch("a-last-purchase")?.headers["X-Joryio-Auth"], "token-of-a",
                       "the outgoing user's last events went out without their token")
        XCTAssertNil(batch("after-logout")?.headers["X-Joryio-Auth"], "the next visitor carried the previous user's token")
        waitUntil { ((try? self.queuedTypes(storage)) ?? ["x"]).isEmpty }
    }

    func testSubjectUserIdReadsTheSameFieldsTheServerBindsTheTokenTo() {
        func subject(_ json: String) -> String? { NetworkClient.subjectUserId(of: Data(json.utf8)) }
        XCTAssertEqual(subject(#"{"userId":"a","anonymousId":"x"}"#), "a")
        XCTAssertEqual(subject(#"{"externalId":"a"}"#), "a")
        XCTAssertEqual(subject(#"{"identify":{"userId":"a"},"events":[]}"#), "a")
        XCTAssertEqual(subject(#"{"events":[{"anonymousId":"x"},{"userId":"a"}]}"#), "a")
        XCTAssertNil(subject(#"{"events":[{"anonymousId":"x"}]}"#))
        XCTAssertNil(subject(#"{"userId":""}"#))
    }

    /// Device info is built on background queues. It used to read
    /// `UIScreen.main` there, which can wait on the main queue - with the
    /// main thread blocked on the SDK (here: a semaphore) that never returns.
    func testDeviceInfoOffTheMainThreadNeverWaitsOnTheMainThread() {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = DeviceInfo.getDeviceInfo()
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "getDeviceInfo() waited on the blocked main thread")
    }

    func testTheScreenSizeReadOnTheMainThreadIsWhatBackgroundCallsReport() {
        let main = DeviceInfo.screenSize()
        XCTAssertNotNil(main)
        let done = expectation(description: "background read")
        DispatchQueue.global().async {
            let info = DeviceInfo.getDeviceInfo()
            XCTAssertEqual(info["screen_width"] as? Int, main.map { Int($0.width) })
            XCTAssertEqual(info["screen_height"] as? Int, main.map { Int($0.height) })
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    // MARK: v4 40 - one retry-counting rule

    func testOfflineTimeoutRateLimitAndServerErrorsNeverCountTowardTheCap() {
        func counts(_ status: Int, _ body: String = "") -> Bool? {
            if case .retry(_, let answered) = NetworkClient.classifyWriteResponse(status: status, body: Data(body.utf8), retryAfterHeader: nil) {
                return answered
            }
            return nil
        }
        XCTAssertEqual(counts(503), false)
        XCTAssertEqual(counts(500), false)
        XCTAssertEqual(counts(429), false)
        XCTAssertEqual(counts(408), false)
        // 402 is its own outcome since round 5 (contract v5, 50): parked,
        // never counted.
        if case .suspended = NetworkClient.classifyWriteResponse(status: 402, body: Data(), retryAfterHeader: nil) {} else {
            XCTFail("402 is not classified as suspended")
        }
        XCTAssertEqual(counts(200, #"{"success":false}"#), true)
    }

    /// Twelve 503s in a row: the write is still there. It used to be dropped
    /// after ten.
    func testAWriteSurvivesMoreThanTenServerErrors() async {
        var sends = 0
        let outbox = WriteOutbox(
            logger: TestSupport.logger(),
            load: { .value(nil) },
            save: { _ in },
            sender: { _, _, _ in
                sends += 1
                return NetworkClient.classifyWriteResponse(status: 503, body: Data(), retryAfterHeader: nil)
            }
        )
        outbox.add(OutboxEntry(kind: .identify, path: "/v1/identify", body: "{}", userId: "u"))
        for _ in 0..<12 { await outbox.drain(force: true) }
        XCTAssertGreaterThanOrEqual(sends, 12)
        XCTAssertEqual(outbox.count, 1)
        XCTAssertEqual(outbox.snapshot().first?.attempts, 0)
    }

    // MARK: v4 41 - sizes measured like the server

    /// `/` is not escaped: 40,000 slashes are 40,002 characters to the
    /// server. JSONEncoder wrote `\/`, measured 80,000+ and dropped it.
    func testSlashesDoNotInflateTheMeasuredSize() {
        XCTAssertNil(Joryio.eventRejectionReason(name: "links", properties: ["u": String(repeating: "/", count: 40_000)]))
        XCTAssertNotNil(Joryio.eventRejectionReason(name: "links", properties: ["u": String(repeating: "/", count: 52_000)]))
    }

    /// A name of spaces is stored by the server (isValidSdkEventName), so it
    /// is not dropped here. It used to be.
    func testAWhitespaceNameFollowsTheServerRule() throws {
        let (sdk, storage) = sdk()
        sdk.track("   ")
        sdk.track("")
        XCTAssertEqual(try queuedTypes(storage), ["   "])
    }

    // MARK: v4 42 - e-commerce never sends an empty order

    func testEcommerceWithoutRequiredValuesSendsNothing() throws {
        let (sdk, storage) = sdk()
        let ecommerce = sdk.ecommerce()
        let item = EcommerceCartItem(productId: "sku-1", name: "Shirt", price: 10, quantity: 1)
        ecommerce.purchase(order: EcommerceOrder(orderId: "", items: [item], value: 10))
        ecommerce.purchase(order: EcommerceOrder(orderId: "o-2", items: [item], value: .nan))
        ecommerce.purchase(order: EcommerceOrder(orderId: "o-3", items: [EcommerceCartItem(productId: " ", name: "x", price: 1, quantity: 1)], value: 1))
        ecommerce.viewProduct(EcommerceProduct(productId: "", name: "x", price: 1))
        ecommerce.addToCart(item: EcommerceCartItem(productId: "sku-2", name: "x", price: .infinity, quantity: 1))
        ecommerce.orderRefunded(orderId: "")
        XCTAssertEqual(try queuedTypes(storage), [], "an empty or zero order was tracked")

        ecommerce.purchase(order: EcommerceOrder(orderId: "o-ok", items: [item], value: 10))
        XCTAssertEqual(try queuedTypes(storage), ["Order Completed"])
    }

    /// Round 4 integration: ONE guard set on every SDK (the backend's
    /// ecommerce-guard-parity spec). Fails before: a blank category name,
    /// query, payment method, share method or coupon code, and a NaN
    /// discount, were all sent; an order with no items was refused here alone.
    func testOneEcommerceGuardSet() throws {
        let (sdk, storage) = sdk()
        let shop = sdk.ecommerce()
        let product = EcommerceProduct(productId: "p1", name: "Buds", price: 10)
        let line = EcommerceCartItem(productId: "p1", name: "Buds", price: 10, quantity: 1)
        shop.viewProduct(EcommerceProduct(productId: "   ", name: "Buds", price: 10))
        shop.viewProduct(EcommerceProduct(productId: "p1", name: "Buds", price: .nan))
        shop.addToCart(item: line, cartValue: .nan)
        shop.shareProduct(product: product, shareMethod: " ")
        shop.viewCategory(categoryId: "c1", categoryName: " ")
        shop.search(query: "  ")
        shop.addPaymentInfo(paymentMethod: "")
        shop.cartViewed(items: [EcommerceCartItem(productId: "", name: "x", price: 1, quantity: 1)], cartValue: 1)
        shop.startCheckout(items: [line], cartValue: .infinity)
        shop.purchase(order: EcommerceOrder(orderId: "o1", items: [line], value: 10, shipping: .nan))
        shop.orderRefunded(orderId: "o1", refundAmount: .nan)
        shop.applyCoupon(couponCode: "SAVE", discountAmount: .nan)
        shop.applyCoupon(couponCode: " ")
        shop.removeCoupon(couponCode: "")
        XCTAssertEqual(try queuedTypes(storage), [], "an incomplete e-commerce call was tracked")

        shop.viewProduct(product)
        shop.cartViewed(items: [line], cartValue: 10)
        shop.purchase(order: EcommerceOrder(orderId: "o2", items: [], value: 10))
        shop.applyCoupon(couponCode: "SAVE")
        XCTAssertEqual(try queuedTypes(storage), ["Product Viewed", "Cart Viewed", "Order Completed", "Coupon Applied"])
    }

    // MARK: v4 43 / M5 / M6 - in-app display follows the identity and consent

    private func inAppManager() -> InAppMessagingManager {
        let storage = TestSupport.storage()
        let logger = TestSupport.logger()
        let identity = IdentityManager(storage: storage, logger: logger)
        let session = SessionManager(storage: storage, logger: logger, sessionTimeout: 1800)
        return InAppMessagingManager(
            networkClient: TestSupport.network(), storage: storage, identityManager: identity,
            sessionManager: session, logger: logger
        )
    }

    private func campaign(id: String, delay: Int? = nil) throws -> InAppCampaign {
        var json: [String: Any] = [
            "id": id, "name": id, "type": "modal", "priority": 1,
            "content": ["kind": "native", "title": "Hello", "body": "Body"],
        ]
        if let delay { json["delay"] = delay }
        return try TestSupport.campaign(json)
    }

    /// identify() (no reset), an opt-out or a consent change while a message
    /// waits on its display delay: it is not shown, and the slot comes back.
    /// Only reset() used to stop it.
    func testADelayedMessageIsNotShownAfterTheIdentityChanges() async throws {
        let manager = inAppManager()
        var handed: [String] = []
        manager.onMessageReady = { handed.append($0.id) }
        manager.setActiveCampaignsForTesting([try campaign(id: "delayed", delay: 1)])

        let display = Task { await manager.evaluateCampaigns() }
        try await Task.sleep(nanoseconds: 200_000_000)
        manager.invalidate()
        await display.value

        XCTAssertEqual(handed, [])
        XCTAssertFalse(manager.isDisplayingForTesting)
    }

    /// Sending stopped (consent pending / denied, opted out) during the
    /// delay: not shown.
    func testADelayedMessageIsNotShownOnceSendingIsBlocked() async throws {
        let manager = inAppManager()
        var allowed = true
        manager.canSync = { allowed }
        var handed: [String] = []
        manager.onMessageReady = { handed.append($0.id) }
        manager.setActiveCampaignsForTesting([try campaign(id: "delayed", delay: 1)])

        let display = Task { await manager.evaluateCampaigns() }
        try await Task.sleep(nanoseconds: 200_000_000)
        allowed = false
        await display.value

        XCTAssertEqual(handed, [])
        XCTAssertFalse(manager.isDisplayingForTesting)
    }

    /// A host-rendered message holds the slot until it is DISMISSED. The
    /// host's `displayed` used to free it, and the next message could be
    /// drawn on top of one still on screen.
    func testAHostRenderedMessageHoldsTheSlotUntilDismissed() async throws {
        let manager = inAppManager()
        manager.onMessageReady = { _ in }
        manager.setActiveCampaignsForTesting([try campaign(id: "held")])
        await manager.evaluateCampaigns()
        XCTAssertTrue(manager.isDisplayingForTesting)

        manager.trackHostImpression(campaignId: "held", action: "displayed")
        XCTAssertTrue(manager.isDisplayingForTesting, "freed while still on screen")
        manager.trackHostImpression(campaignId: "held", action: "dismissed")
        XCTAssertFalse(manager.isDisplayingForTesting)
    }

    // MARK: v4 44 - getters before init answer from storage

    func testGettersBeforeInitAnswerFromWhatIsStored() {
        let defaults = TestSupport.defaults()
        defaults.set(true, forKey: StorageManager.optOutKey)
        defaults.set(true, forKey: StorageManager.consentDeniedKey)
        let (sdk, _) = sdk(defaults: defaults, initialize: false)
        XCTAssertTrue(sdk.isUserOptedOut(), "a stored opt-out read as false before init")
        XCTAssertEqual(sdk.getTrackingConsent(), .denied)
    }

    // MARK: v4 45 - pre-init sequences, one rule

    /// denied, then pending, before init: still denied. The pending used to
    /// replace the denial (Android has always kept it).
    func testPendingBeforeInitNeverReopensADenial() {
        let (sdk, storage) = sdk(initialize: false)
        sdk.updateConsent(.denied)
        sdk.updateConsent(.pending)
        XCTAssertEqual(sdk.getTrackingConsent(), .denied)

        let config = JoryioConfig(flushInterval: 3600, trackSessionStart: false, inApp: InAppConfig(enabled: false), maxRetries: 0)
        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: config)
        XCTAssertEqual(sdk.getTrackingConsent(), .denied)
        XCTAssertTrue(storage.getConsentDenied())
    }

    /// optIn() before init wins over `optOut: true` in the config: the call
    /// is explicit and later. The config used to win.
    func testAnOptInBeforeInitWinsOverTheConfig() {
        let (sdk, _) = sdk(initialize: false)
        sdk.optIn()
        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: TestSupport.sdkConfig(optOut: true))
        XCTAssertFalse(sdk.isUserOptedOut())
    }

    // MARK: M3 - pending -> denied -> granted still announces a session

    func testPendingDeniedGrantedStillSendsASessionStart() {
        let (sdk, _) = sdk(config: TestSupport.sdkConfig(trackSessionStart: true, trackingConsent: .pending))
        let firstSession = sdk.getSessionId()
        sdk.updateConsent(.denied)
        sdk.updateConsent(.granted)
        waitUntil {
            TestSupport.requests("/v1/track/batch").contains { String(decoding: $0.body, as: UTF8.self).contains("Session Start") }
        }
        XCTAssertNotEqual(sdk.getSessionId(), firstSession, "a new session begins with its own Session Start")
    }

    // MARK: M4 - an outbox that could not be read is merged, never overwritten

    func testAnUnreadableOutboxIsMergedWhenItCanBeRead() throws {
        let stored = OutboxEntry(kind: .identify, path: "/v1/identify", body: "{}", userId: "stored")
        let storedJSON = String(decoding: try JSONEncoder().encode([stored]), as: UTF8.self)
        var loads = 0
        var saved: [String?] = []
        let outbox = WriteOutbox(
            logger: TestSupport.logger(),
            load: {
                loads += 1
                return loads <= 2 ? .unavailable : .value(storedJSON)
            },
            save: { saved.append($0) },
            sender: { _, _, _ in .done }
        )
        outbox.add(OutboxEntry(kind: .alias, path: "/v1/alias/add", body: "{}", userId: "new"))
        XCTAssertTrue(saved.isEmpty, "saved over a stored outbox it could not read")

        XCTAssertEqual(outbox.snapshot().map(\.userId), ["stored", "new"])
        let last = try XCTUnwrap(saved.last ?? nil)
        XCTAssertTrue(last.contains("stored") && last.contains("new"))
    }

    // MARK: M7 - a server Retry-After is capped

    func testTheOutboxCapsAServerRetryAfter() async {
        let outbox = WriteOutbox(
            logger: TestSupport.logger(),
            load: { .value(nil) },
            save: { _ in },
            sender: { _, _, _ in .retry(retryAfter: 1_000_000, answered: false) }
        )
        outbox.add(OutboxEntry(kind: .identify, path: "/v1/identify", body: "{}", userId: "u"))
        await outbox.drain(force: true)
        let until = try? XCTUnwrap(outbox.retryAfterUntilForTesting)
        XCTAssertLessThanOrEqual(until?.timeIntervalSinceNow ?? .infinity, WriteOutbox.maxRetryAfterSeconds + 1)
    }

    // MARK: v4 48 - callbacks never hang after a failed initialize()

    func testRegisterPushTokenAnswersWhenInitializeFails() {
        let (sdk, _) = sdk(initialize: false)
        var buffered: PushRegistrationResult?
        sdk.registerPushToken("tok-48") { buffered = $0 }
        sdk.initialize(sdkKey: "not-a-key", apiHost: "api-eu1.joryio.test")
        XCTAssertEqual(buffered?.success, false, "the buffered call never answered")
        XCTAssertEqual(buffered?.isRetryable, false)

        var after: PushRegistrationResult?
        sdk.registerPushToken("tok-48") { after = $0 }
        XCTAssertEqual(after?.success, false)
        XCTAssertFalse(sdk.isInitializationPending)
    }
}
