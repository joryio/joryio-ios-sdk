import XCTest
@testable import Joryio

/// The sixth 1.3.0 review (scan 6, iOS), the iOS items of the Unity scan, and
/// contract addendum v6 (rules 61-69). The scan's probes P1-P7 are lifted
/// here and failed on 011d4a88c; each test names what it pins.
final class ReleaseRound6Tests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private let ok = Data(#"{"success":true}"#.utf8)

    private func jwt(_ sub: String) -> String {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        return b64(#"{"alg":"HS256"}"#) + "." + b64("{\"sub\":\"\(sub)\"}") + ".sig"
    }

    private func authConfig(token: String) -> JoryioConfig {
        JoryioConfig(
            flushInterval: 3600, trackSessionStart: false, inApp: InAppConfig(enabled: false), maxRetries: 0,
            sdkAuthenticationToken: token, trackingConsent: .granted
        )
    }

    private func sentEvents() -> [[String: Any]] {
        TestSupport.requests("/v1/track/batch").flatMap { ($0.json?["events"] as? [[String: Any]]) ?? [] }
    }

    private func emailStatuses() -> [(String, String)] {
        TestSupport.requests("/v1/subscriptions/channel")
            .filter { $0.json?["channel"] as? String == "email" }
            .map { ($0.json?["status"] as? String ?? "", $0.json?["userId"] as? String ?? "anon") }
    }

    // MARK: B1 / v6 64 - an older subscribe never lands after a newer unsubscribe

    /// P6: consent pending lets the withdrawal skip ahead of the held
    /// anonymous subscribe; the subscribe is sent as the same user once
    /// consent is granted, so the unsubscribe must replace it.
    func testP6_pendingConsentSubscribeThenLoginThenUnsubscribeStaysUnsubscribed() {
        StubURLProtocol.responder = { [ok] _ in (200, ok) }
        let sdk = TestSupport.sdk(config: TestSupport.sdkConfig(trackingConsent: .pending))
        sdk.setSubscription(channel: "email", status: "subscribed")
        sdk.identify("user-a")
        sdk.setSubscription(channel: "email", status: "unsubscribed")
        waitUntil { TestSupport.requests("/v1/subscriptions/channel").contains { $0.json?["status"] as? String == "unsubscribed" } }
        sdk.updateConsent(.granted)
        waitUntil(timeout: 5) { sdk.writeOutboxForTesting?.count == 0 }
        let email = emailStatuses()
        XCTAssertEqual(email.last?.0, "unsubscribed", "the older subscribe landed after the unsubscribe: \(email)")
        XCTAssertFalse(email.contains { $0.0 == "subscribed" }, "the replaced subscribe was still sent: \(email)")
    }

    /// P3: the same through a 402 (billing pause) instead of pending consent.
    func testP3_parkedSubscribeDoesNotLandAfterANewerUnsubscribe() {
        var suspended = true
        StubURLProtocol.responder = { [ok] request in
            let json = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let isWithdrawal = (json?["status"] as? String) == "unsubscribed"
            if suspended, !isWithdrawal, request.url!.path.contains("/v1/"), !request.url!.path.hasSuffix("/track/batch") {
                return (402, Data())
            }
            return (200, ok)
        }
        let sdk = TestSupport.sdk()
        sdk.setSubscription(channel: "email", status: "subscribed")
        waitUntil { !TestSupport.requests("/v1/subscriptions/channel").isEmpty }
        sdk.identify("user-a")
        sdk.setSubscription(channel: "email", status: "unsubscribed")
        waitUntil { TestSupport.requests("/v1/subscriptions/channel").contains { $0.json?["status"] as? String == "unsubscribed" } }
        suspended = false
        sdk.writeOutboxForTesting?.kick(force: true)
        waitUntil(timeout: 5) { sdk.writeOutboxForTesting?.count == 0 }
        let email = emailStatuses()
        XCTAssertEqual(email.last?.0, "unsubscribed", "older subscribe landed after the newer unsubscribe: \(email)")
    }

    /// Group leave, same rule.
    func testAGroupLeaveReplacesTheSamePersonsAnonymousGroupJoin() {
        let sdk = TestSupport.sdk(config: TestSupport.sdkConfig(trackingConsent: .pending))
        sdk.addToSubscriptionGroup("news", channel: "email")
        sdk.identify("user-a")
        sdk.removeFromSubscriptionGroup("news", channel: "email")
        let queued = sdk.writeOutboxForTesting?.snapshot().filter { $0.path == "/v1/subscriptions/group" } ?? []
        XCTAssertFalse(queued.contains { $0.body.contains("\"subscribe\"") }, "the anonymous join is still queued behind the leave")
    }

    /// Rule 52 still holds: after reset() the anonymous id is new, so the
    /// next person's subscribe never replaces the previous one's unsubscribe.
    func testADifferentPersonsQueuedUnsubscribeIsNeverReplaced() {
        StubURLProtocol.responder = { _ in (503, Data()) }
        let sdk = TestSupport.sdk()
        sdk.identify("user-a")
        sdk.setSubscription(channel: "email", status: "unsubscribed")
        sdk.reset()
        sdk.identify("user-b")
        sdk.setSubscription(channel: "email", status: "subscribed")
        let queued = sdk.writeOutboxForTesting?.snapshot().filter { $0.kind == .subscription } ?? []
        XCTAssertTrue(queued.contains { $0.userId == "user-a" && $0.withdrawal == true }, "user-a's unsubscribe was replaced")
    }

    // MARK: S1 / v6 61 - a token set for the next user retires the previous one

    /// P1: the app sets user-b's token BEFORE identify(user-b). user-a's
    /// queued write still carries user-a's token.
    func testP1_tokenSetBeforeIdentifyKeepsThePreviousUsersTokenForTheirLeftovers() {
        var down = true
        StubURLProtocol.responder = { [ok] request in
            if down, request.url!.path.hasSuffix("/v1/subscriptions/channel") { return (503, Data()) }
            return (200, ok)
        }
        let sdk = TestSupport.sdk(config: authConfig(token: jwt("user-a")))
        sdk.identify("user-a")
        sdk.setSubscription(channel: "email", status: "unsubscribed")
        waitUntil { !TestSupport.requests("/v1/subscriptions/channel").isEmpty }
        sdk.setSdkAuthenticationToken(jwt("user-b"))
        sdk.identify("user-b")
        down = false
        sdk.writeOutboxForTesting?.resetBackoff()
        sdk.writeOutboxForTesting?.kick(force: true)
        waitUntil { TestSupport.requests("/v1/subscriptions/channel").count >= 2 }
        let last = TestSupport.requests("/v1/subscriptions/channel").last
        XCTAssertEqual(last?.json?["userId"] as? String, "user-a")
        XCTAssertEqual(last?.headers["X-Joryio-Auth"], jwt("user-a"), "user-a's unsubscribe went out with user-b's token")
        let identifyB = TestSupport.requests("/v1/identify").first { $0.json?["userId"] as? String == "user-b" }
        XCTAssertEqual(identifyB?.headers["X-Joryio-Auth"], jwt("user-b"))
    }

    func testARefreshForTheSameUserRetiresNothing() {
        let store = SdkAuthTokenStore(enabled: true, initialToken: jwt("user-a"))
        store.setToken(jwt("user-a") + "x")
        XCTAssertTrue(store.retiredUserIds.isEmpty)
        store.setToken(jwt("user-b"))
        XCTAssertEqual(store.retiredUserIds, ["user-a"])
        XCTAssertEqual(store.token(forSubject: "user-a", currentUserId: "user-b"), jwt("user-a") + "x")
    }

    /// reset() files a token under its own `sub`, not under the outgoing id.
    func testARetiredTokenIsFiledUnderItsOwnSubject() {
        let store = SdkAuthTokenStore(enabled: true, initialToken: jwt("user-b"))
        store.retireToken(forUser: "user-a")
        XCTAssertEqual(store.retiredUserIds, ["user-b"])
    }

    // MARK: S2 / v6 61 - retired tokens are used after a restart

    /// P7: SDK auth switched on only by setSdkAuthenticationToken; the next
    /// process starts with the flag off, and the retired token must still be
    /// attached to the logged-out user's leftovers.
    func testP7_persistedRetiredTokenIsUsedAfterARestartWithoutTheConfigFlag() async {
        var persisted: String?
        let first = SdkAuthTokenStore(enabled: false, initialToken: nil, persistRetired: { persisted = $0 })
        first.setToken(jwt("user-a"))
        first.retireToken(forUser: "user-a")
        XCTAssertNotNil(persisted)
        let store = SdkAuthTokenStore(enabled: false, initialToken: nil, persistedRetired: persisted)
        XCTAssertTrue(store.enabled)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let network = NetworkClient(
            sdkKey: "jry_sdk_ios_test", apiEndpoint: "https://api-eu1.joryio.test/api", logger: TestSupport.logger(),
            maxRetries: 0, retryBackoffMs: 1, requestTimeout: 5, authStore: store, sessionConfiguration: configuration
        )
        let body = Data(#"{"channel":"email","status":"unsubscribed","userId":"user-a"}"#.utf8)
        _ = await network.sendWrite(path: "/v1/subscriptions/channel", body: body, userId: "user-a")
        XCTAssertEqual(TestSupport.requests("/v1/subscriptions/channel").last?.headers["X-Joryio-Auth"], jwt("user-a"))
        // An anonymous request still carries nothing.
        _ = await network.sendWrite(path: "/v1/subscriptions/channel", body: Data(#"{"anonymousId":"x"}"#.utf8), userId: nil)
        XCTAssertNil(TestSupport.requests("/v1/subscriptions/channel").last?.headers["X-Joryio-Auth"])
    }

    // MARK: N3 / v6 61 - grace minute, 30-day cap, one bad row loses nothing

    func testARetiredTokenWaitsTheGraceMinuteAndNeverOutlivesThirtyDays() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var persisted: String?
        let store = SdkAuthTokenStore(
            enabled: true, initialToken: "tok-a", persistRetired: { persisted = $0 },
            settleGrace: 60, now: { clock }
        )
        store.retireToken(forUser: "user-a")
        clock += 30
        store.pruneRetired { _ in false }
        XCTAssertEqual(store.retiredUserIds, ["user-a"], "pruned inside the grace minute: an event built before the logout loses its token")
        clock += 31
        store.pruneRetired { _ in false }
        XCTAssertTrue(store.retiredUserIds.isEmpty)
        XCTAssertNil(persisted)

        store.setToken("tok-b")
        store.retireToken(forUser: "user-b")
        clock += 31 * 24 * 60 * 60
        store.pruneRetired { _ in true }
        XCTAssertTrue(store.retiredUserIds.isEmpty, "kept past the backend's 30-day window")
    }

    func testAnExpiredRowIsDroppedAtLoadAndAMalformedRowLosesNothing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-31 * 24 * 60 * 60).timeIntervalSince1970
        let json = """
        [{"userId":"old","token":"t-old","retiredAt":\(old)},
         {"userId":"bad","token":42},
         {"userId":"legacy","token":"t-legacy"},
         {"userId":"fresh","token":"t-fresh","retiredAt":\(now.timeIntervalSince1970)}]
        """
        let store = SdkAuthTokenStore(enabled: false, initialToken: nil, persistedRetired: json, now: { now })
        XCTAssertEqual(store.retiredUserIds, ["legacy", "fresh"])
        XCTAssertEqual(store.token(forSubject: "legacy", currentUserId: nil), "t-legacy")
    }

    /// N3: a re-retirement between the "still needed?" question and the
    /// removal is kept.
    func testAReRetirementDuringAPruneIsKept() {
        let store = SdkAuthTokenStore(enabled: true, initialToken: "tok-1", settleGrace: 0)
        store.retireToken(forUser: "user-a")
        store.pruneRetired { _ in
            store.setToken("tok-2")
            store.retireToken(forUser: "user-a")
            return false
        }
        XCTAssertEqual(store.token(forSubject: "user-a", currentUserId: nil), "tok-2")
    }

    // MARK: S3 / v6 63 - a held user's withdrawal under SDK auth

    /// P5: identify(B) while opted out, with A identified: B's withdrawal
    /// never carries A's token.
    func testP5_heldUserWithdrawalDoesNotCarryThePreviousUsersToken() {
        StubURLProtocol.responder = { [ok] _ in (200, ok) }
        let sdk = TestSupport.sdk(config: authConfig(token: jwt("user-a")))
        sdk.identify("user-a")
        sdk.optOut()
        sdk.identify("user-b")
        sdk.setSubscription(channel: "email", status: "unsubscribed")
        waitUntil { TestSupport.requests("/v1/subscriptions/channel").contains { $0.json?["userId"] as? String == "user-b" } }
        let r = TestSupport.requests("/v1/subscriptions/channel").first { $0.json?["userId"] as? String == "user-b" }
        XCTAssertNotEqual(r?.headers["X-Joryio-Auth"], jwt("user-a"))
    }

    /// The 401 for the held user's withdrawal asks the app for a token, and
    /// the write goes out with it instead of being dropped.
    func testAHeldUsersRefusedWithdrawalAsksTheHandlerAndIsKept() {
        let refusal = Data(#"{"error":"sdk_authentication_error","reason":"missing"}"#.utf8)
        StubURLProtocol.responder = { [ok] request in
            if request.url!.path.hasSuffix("/v1/subscriptions/channel"), request.value(forHTTPHeaderField: "X-Joryio-Auth") == nil {
                return (401, refusal)
            }
            return (200, ok)
        }
        let sdk = TestSupport.sdk(config: authConfig(token: jwt("user-a")))
        var asked: [SdkAuthErrorReason] = []
        let tokenB = jwt("user-b")
        sdk.setSdkAuthenticationErrorHandler { [weak sdk] error in
            asked.append(error.reason)
            sdk?.setSdkAuthenticationToken(tokenB)
        }
        sdk.identify("user-a")
        sdk.optOut()
        sdk.identify("user-b")
        sdk.setSubscription(channel: "email", status: "unsubscribed")
        waitUntil {
            TestSupport.requests("/v1/subscriptions/channel").contains {
                $0.json?["userId"] as? String == "user-b" && $0.headers["X-Joryio-Auth"] == tokenB
            }
        }
        XCTAssertEqual(asked.first, .missing, "the app was never asked for the held user's token")
        waitUntil(timeout: 5) { sdk.writeOutboxForTesting?.count == 0 }
    }

    // MARK: v6 63 - held user id at init

    /// An explicit userId at init wins over one kept while tracking was off.
    func testAnExplicitInitUserIdWinsOverAHeldOne() {
        let storage = TestSupport.storage()
        let first = TestSupport.sdk(config: TestSupport.sdkConfig(optOut: true), storage: storage)
        first.identify("held-user")
        XCTAssertEqual(storage.getHeldUserId(), "held-user")
        let config = JoryioConfig(
            userId: "config-user", flushInterval: 3600, trackSessionStart: false, inApp: InAppConfig(enabled: false), maxRetries: 0
        )
        let second = TestSupport.sdk(config: config, storage: storage)
        XCTAssertNil(storage.getHeldUserId())
        second.optIn()
        XCTAssertEqual(second.getUserId(), "config-user")
        XCTAssertFalse(TestSupport.requests("/v1/identify").contains { $0.json?["userId"] as? String == "held-user" })
    }

    /// Released at init when tracking is allowed there, BEFORE the Session
    /// Start, which then belongs to the released user.
    func testAHeldIdentifyReleasedAtInitPrecedesTheSessionStart() {
        let defaults = TestSupport.defaults()
        let storage = TestSupport.storage(defaults: defaults)
        let first = TestSupport.sdk(config: TestSupport.sdkConfig(), storage: storage, defaults: defaults)
        first.identify("user-a")
        first.updateConsent(.denied)
        first.identify("user-b")
        XCTAssertEqual(storage.getHeldUserId(), "user-b")
        storage.clearSession()
        let second = TestSupport.sdk(
            config: TestSupport.sdkConfig(trackSessionStart: true, trackingConsent: .granted),
            storage: storage, defaults: defaults
        )
        XCTAssertEqual(second.getUserId(), "user-b")
        second.flush()
        waitUntil { self.sentEvents().contains { $0["type"] as? String == "Session Start" } }
        let start = sentEvents().first { $0["type"] as? String == "Session Start" }
        XCTAssertEqual(start?["userId"] as? String, "user-b", "the Session Start went out under the previous identity")
    }

    // MARK: Unity S1 / v6 66 - a runtime wipe announces the next session

    func testAfterARuntimeWipeTheNextSessionHasExactlyOneSessionStart() {
        let sdk = TestSupport.sdk(config: TestSupport.sdkConfig(trackSessionStart: true, trackingConsent: .pending))
        sdk.wipeData()
        let anonymousId = sdk.getAnonymousId()
        sdk.updateConsent(.granted)
        sdk.track("after-wipe")
        sdk.track("second")
        sdk.flush()
        waitUntil { self.sentEvents().contains { $0["type"] as? String == "second" } }
        let starts = sentEvents().filter { $0["type"] as? String == "Session Start" }
        XCTAssertEqual(starts.count, 1, "\(sentEvents().map { $0["type"] as? String ?? "" })")
        XCTAssertEqual(starts.first?["anonymousId"] as? String, anonymousId)
        let types = sentEvents().map { $0["type"] as? String ?? "" }
        XCTAssertEqual(types.firstIndex(of: "Session Start"), types.firstIndex(of: "after-wipe").map { $0 - 1 })
    }

    func testAPreInitWipeStillSendsOneSessionStartOnly() {
        let defaults = TestSupport.defaults()
        let sdk = TestSupport.sdk(config: TestSupport.sdkConfig(trackSessionStart: true), defaults: defaults, initialize: false)
        sdk.wipeData()
        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: TestSupport.sdkConfig(trackSessionStart: true))
        sdk.track("after")
        sdk.flush()
        waitUntil { self.sentEvents().contains { $0["type"] as? String == "after" } }
        XCTAssertEqual(sentEvents().filter { $0["type"] as? String == "Session Start" }.count, 1)
    }

    // MARK: Unity S2 / v6 66 - pre-init grant, then pending, over a stored denial

    /// A pre-init grant lifts the stored denial for the pending check, as on
    /// Android: the later pending replaces it, and the start is quiet
    /// (pending over a stored denial resolves to denied).
    func testAPendingAfterAPreInitGrantIsTakenAsOnAndroid() {
        let defaults = TestSupport.defaults()
        let storage = TestSupport.storage(defaults: defaults)
        let first = TestSupport.sdk(config: TestSupport.sdkConfig(), storage: storage, defaults: defaults)
        first.updateConsent(.denied)
        XCTAssertTrue(defaults.bool(forKey: StorageManager.consentDeniedKey))

        let sdk = TestSupport.sdk(storage: storage, defaults: defaults, initialize: false)
        sdk.updateConsent(.granted)
        XCTAssertEqual(sdk.getTrackingConsent(), .granted)
        sdk.updateConsent(.pending)
        XCTAssertEqual(sdk.getTrackingConsent(), .denied, "pending replaced the grant, and never reopens the stored denial")
        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test",
                       config: TestSupport.sdkConfig(trackSessionStart: true, trackingConsent: .pending))
        XCTAssertEqual(sdk.getTrackingConsent(), .denied, "the quiet start was not quiet")
        sdk.updateConsent(.granted)
        XCTAssertEqual(sdk.getTrackingConsent(), .granted)
    }

    /// Without an in-process grant, pending still never reopens a denial.
    func testAPreInitPendingNeverReopensAStoredDenial() {
        let defaults = TestSupport.defaults()
        defaults.set(true, forKey: StorageManager.consentDeniedKey)
        let sdk = TestSupport.sdk(defaults: defaults, initialize: false)
        sdk.updateConsent(.pending)
        XCTAssertEqual(sdk.getTrackingConsent(), .denied)
        sdk.updateConsent(.granted) // leaves no pre-init state behind
        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: TestSupport.sdkConfig())
    }

    // MARK: v6 65 - the pre-init consent getter before any decision

    /// Nothing stored, nothing decided: `.granted` - the consent an app with
    /// no banner starts with. Android's getter answers the same (rule 65).
    func testThePreInitConsentGetterAnswersGrantedWhenNothingIsDecided() {
        let sdk = TestSupport.sdk(initialize: false)
        XCTAssertEqual(sdk.getTrackingConsent(), .granted)
        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: TestSupport.sdkConfig())
    }

    // MARK: N1 - a parked write comes back without an external kick

    func testP2_aParkedWriteIsRetriedWithoutAnExternalKick() async throws {
        var identifyCalls = 0
        var subCalls = 0
        let outbox = WriteOutbox(
            logger: TestSupport.logger(), load: { .value(nil) }, save: { _ in },
            sender: { path, _, _ in
                if path == "/v1/identify" {
                    identifyCalls += 1
                    if identifyCalls == 1 {
                        return NetworkClient.classifyWriteResponse(status: 402, body: Data(), retryAfterHeader: "1")
                    }
                    return .done
                }
                subCalls += 1
                if subCalls == 1 { return .retry(retryAfter: nil, answered: false) }
                return .done
            }
        )
        outbox.baseBackoff = 0.05
        outbox.add(OutboxEntry(kind: .identify, path: "/v1/identify", body: "{}", userId: "u"))
        outbox.add(OutboxEntry(kind: .subscription, path: "/v1/subscriptions/channel", body: #"{"status":"unsubscribed"}"#, userId: "u", withdrawal: true))
        await outbox.drain()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertEqual(subCalls, 2, "withdrawal retried")
        XCTAssertEqual(identifyCalls, 2, "the parked identify was never retried")
        XCTAssertTrue(outbox.snapshot().isEmpty)
    }

    // MARK: N2 / v6 69 - the trimmed token is the one registered

    func testP4_registeredTokenIsTheTrimmedOne() {
        let sdk = TestSupport.sdk()
        let hex = String(repeating: "ab", count: 32)
        sdk.registerPushToken(" \(hex.uppercased())\n")
        waitUntil { !TestSupport.requests("/v1/push/register").isEmpty }
        let sent = TestSupport.requests("/v1/push/register").first?.json?["token"] as? String
        XCTAssertEqual(sent, hex)
    }

    func testAnAPNsTokenLongerThanTheBackendTakesIsRefused() {
        XCTAssertTrue(Joryio.isAPNsToken(String(repeating: "ab", count: 100)))
        XCTAssertFalse(Joryio.isAPNsToken(String(repeating: "ab", count: 101)))
    }
}
