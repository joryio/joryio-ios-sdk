import XCTest
import UIKit
@testable import Joryio

/// The fifth 1.3.0 review (scan 5, iOS), the iOS items of the other scans,
/// and contract addendum v5 (owner decisions D-a..D-c, rules 49-60). Each
/// test names what it pins; the scan's probes (P1-P7) are lifted here and
/// failed on 44379f8e1.
final class ReleaseRound5Tests: XCTestCase {

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

    private func sdk(
        config: JoryioConfig = TestSupport.sdkConfig(),
        storage: StorageManager = TestSupport.storage(),
        initialize: Bool = true
    ) -> Joryio {
        TestSupport.sdk(config: config, storage: storage, initialize: initialize)
    }

    private func bodies(_ suffix: String) -> [[String: Any]] {
        TestSupport.requests(suffix).compactMap(\.json)
    }

    private func authConfig(token: String) -> JoryioConfig {
        JoryioConfig(
            flushInterval: 3600, trackSessionStart: false, inApp: InAppConfig(enabled: false), maxRetries: 0,
            sdkAuthenticationToken: token, trackingConsent: .granted
        )
    }

    // MARK: N4 (integration) - withdrawals before a pre-init wipe keep their identity

    /// An unsubscribe and an unregisterPush() made before a wipeData() made
    /// before init go out under the identity the wipe erases. The wipe used to
    /// run inside initialize() before the buffer replayed, so they were sent
    /// under the fresh anonymous id - a profile that never received anything.
    func testWithdrawalsMadeBeforeAPreInitWipeKeepTheErasedIdentity() {
        let defaults = TestSupport.defaults()
        let storage = TestSupport.storage(defaults: defaults)
        let original = storage.getAnonymousId()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let sdk = Joryio(environment: Joryio.Environment(
            storage: { _, _ in storage },
            sessionConfiguration: configuration,
            defaults: defaults,
            systemIntegration: false,
            secItemCalls: TestSupport.unlockedKeychain
        ))
        sdk.setSubscription(channel: "email", status: "unsubscribed")
        sdk.wipeData()
        sdk.setSubscription(channel: "sms", status: "unsubscribed")
        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: TestSupport.sdkConfig())
        waitUntil { TestSupport.requests("/v1/subscriptions/channel").count >= 2 }
        let sent = bodies("/v1/subscriptions/channel")
        let email = sent.first { ($0["channel"] as? String) == "email" }
        let sms = sent.first { ($0["channel"] as? String) == "sms" }
        XCTAssertEqual(email?["anonymousId"] as? String, original, "the unsubscribe made before the wipe went out under the new identity")
        XCTAssertNotNil(sms?["anonymousId"] as? String)
        XCTAssertNotEqual(sms?["anonymousId"] as? String, original, "the unsubscribe made after the wipe belongs to the new identity")
        XCTAssertNotEqual(storage.getAnonymousId(), original, "the wipe still ran")
    }

    // MARK: S2 / v5 58 - enableDebug alone logs at debug (P1)

    func testEnableDebugAloneLogsAtDebugUnlessALevelIsGiven() {
        XCTAssertEqual(JoryioConfig(enableDebug: true).logLevel, .debug, "enableDebug: true left the level at .error")
        XCTAssertEqual(JoryioConfig().logLevel, .error)
        XCTAssertEqual(JoryioConfig(enableDebug: true, logLevel: .warn).logLevel, .warn, "an explicit level wins")
    }

    // MARK: S3 / v5 59 - no client $identify (P2)

    func testIdentifyQueuesNoClientSideIdentifyEvent() {
        let sdk = sdk()
        let before = sdk.getQueueSize()
        sdk.identify("user-1")
        XCTAssertEqual(sdk.getQueueSize(), before, "identify() queued a client $identify besides /v1/identify")
    }

    // MARK: S4 / v5 55 - milliseconds on the wire (P5)

    func testEventTimestampsCarryMilliseconds() throws {
        let storage = TestSupport.storage()
        try storage.enqueueEvent(Event(type: "A", timestamp: Date(timeIntervalSince1970: 1_791_000_000.5), userId: nil, anonymousId: "anon", sessionId: "s"))
        let row = try storage.dequeueQueuedEvents(limit: 1)[0]
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(row.json.utf8)) as? [String: Any])
        XCTAssertEqual(json["timestamp"] as? String, "2026-10-03T04:00:00.500Z")
        // The decoder still reads rows written with whole seconds.
        XCTAssertNotNil(WireJSON.date(from: "2026-10-03T03:20:00Z"))
        XCTAssertEqual(try storage.dequeueEvents(limit: 1).first?.type, "A")
    }

    // MARK: S5 / v5 51 - a full outbox keeps withdrawals (P3)

    func testAFullOutboxEvictsTheOldestNonWithdrawal() {
        let outbox = WriteOutbox(
            logger: TestSupport.logger(), maxEntries: 2,
            load: { .value(nil) }, save: { _ in },
            sender: { _, _, _ in .retry(retryAfter: nil, answered: false) }
        )
        outbox.add(OutboxEntry(kind: .subscription, path: "/v1/subscriptions/channel", body: #"{"status":"unsubscribed"}"#, userId: nil, withdrawal: true, supersedeKey: "channel:email"))
        outbox.add(OutboxEntry(kind: .identify, path: "/v1/identify", body: "{}", userId: "a"))
        outbox.add(OutboxEntry(kind: .alias, path: "/v1/alias/add", body: "{}", userId: "a"))
        let kinds = outbox.snapshot().map(\.kind)
        XCTAssertEqual(kinds, [.subscription, .alias], "the unsubscribe was evicted by newer collection writes")
    }

    /// v5 51: the pre-init buffer drops data calls before a withdrawal.
    func testAPreInitBurstNeverPushesOutAnUnsubscribe() {
        let sdk = sdk(initialize: false)
        sdk.setSubscription(channel: "email", status: "unsubscribed")
        for i in 0..<(Joryio.maxPreInitCalls + 5) { sdk.track("burst-\(i)") }
        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: TestSupport.sdkConfig())
        waitUntil { self.bodies("/v1/subscriptions/channel").contains { $0["status"] as? String == "unsubscribed" } }
    }

    // MARK: v5 50 - a 402 at the head never blocks withdrawals

    func testA402OnAnIdentifyDoesNotHoldBackTheUnsubscribeBehindIt() async {
        var sent: [String] = []
        let outbox = WriteOutbox(
            logger: TestSupport.logger(), load: { .value(nil) }, save: { _ in },
            sender: { path, _, _ in
                sent.append(path)
                // The paused account refuses the identify; withdrawals pass.
                let status = path == "/v1/identify" ? 402 : 200
                return NetworkClient.classifyWriteResponse(status: status, body: Data(#"{"success":true}"#.utf8), retryAfterHeader: nil)
            }
        )
        outbox.add(OutboxEntry(kind: .identify, path: "/v1/identify", body: "{}", userId: "u"))
        outbox.add(OutboxEntry(kind: .subscription, path: "/v1/subscriptions/channel", body: #"{"status":"unsubscribed"}"#, userId: "u", withdrawal: true))
        await outbox.drain()
        XCTAssertEqual(sent, ["/v1/identify", "/v1/subscriptions/channel"], "the unsubscribe waited behind a 402")
        XCTAssertEqual(outbox.snapshot().map(\.kind), [.identify], "the identify is kept")
        XCTAssertEqual(outbox.snapshot().first?.attempts, 0, "a 402 never counts")
        // Parked: the next (unforced) drain does not hammer the paused account.
        await outbox.drain()
        XCTAssertEqual(sent.count, 2)
    }

    // MARK: v5 52 - supersede key carries the identity

    func testTheNextPersonsSubscribeDoesNotReplaceAQueuedUnsubscribe() {
        StubURLProtocol.responder = { [ok] request in
            request.url!.path.hasSuffix("/v1/subscriptions/channel") ? (503, Data()) : (200, ok)
        }
        let sdk = sdk()
        sdk.identify("user-a")
        sdk.setSubscription(channel: "email", status: "unsubscribed")
        sdk.reset()
        sdk.setSubscription(channel: "email", status: "subscribed")
        let queued = sdk.writeOutboxForTesting?.snapshot().filter { $0.kind == .subscription } ?? []
        XCTAssertEqual(queued.count, 2, "the next person's subscribe replaced user-a's unsubscribe")
        XCTAssertTrue(queued.contains { $0.body.contains("\"unsubscribed\"") && $0.userId == "user-a" })
    }

    // MARK: S6 / v5 53 - identify(B) without reset (P4)

    func testAPreviousUsersUnsentAttributesAreSentUnderThatUser() async {
        let sdk = sdk()
        sdk.identify("user-A")
        sdk.setAttributes(["plan": "pro-of-A"])
        sdk.identify("user-B")
        await sdk.flushPendingAttributes()
        waitUntil { self.bodies("/v1/attributes").contains { $0["userId"] as? String == "user-A" } }
        let writes = bodies("/v1/attributes")
        let underB = writes.filter { $0["userId"] as? String == "user-B" && (($0["attributes"] as? [String: Any])?["plan"] as? String) == "pro-of-A" }
        XCTAssertTrue(underB.isEmpty, "A's attribute was sent with user-B: \(writes)")
        let underA = writes.first { $0["userId"] as? String == "user-A" }
        XCTAssertEqual((underA?["attributes"] as? [String: Any])?["plan"] as? String, "pro-of-A")
    }

    func testAnAccountSwitchRetiresThePreviousUsersToken() {
        StubURLProtocol.responder = { [ok] _ in (200, ok) }
        let sdk = sdk(config: authConfig(token: "token-of-a"))
        sdk.identify("user-a")
        sdk.setAttributes(["plan": "a"])
        sdk.identify("user-b")
        waitUntil { TestSupport.requests("/v1/identify").contains { $0.json?["userId"] as? String == "user-b" } }
        let identifyB = TestSupport.requests("/v1/identify").first { $0.json?["userId"] as? String == "user-b" }
        XCTAssertNil(identifyB?.headers["X-Joryio-Auth"], "user-b's request carried user-a's token")
        waitUntil { TestSupport.requests("/v1/attributes").contains { $0.json?["userId"] as? String == "user-a" } }
        let aWrite = TestSupport.requests("/v1/attributes").first { $0.json?["userId"] as? String == "user-a" }
        XCTAssertEqual(aWrite?.headers["X-Joryio-Auth"], "token-of-a")
    }

    /// The app set the NEXT user's token before identify(): it stays current.
    func testTheNextUsersTokenSetBeforeIdentifyIsKept() {
        func jwt(sub: String) -> String {
            func b64(_ s: String) -> String {
                Data(s.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            }
            return b64(#"{"alg":"HS256"}"#) + "." + b64("{\"sub\":\"\(sub)\"}") + ".sig"
        }
        XCTAssertEqual(SdkAuthTokenStore.subject(ofJWT: jwt(sub: "user-b")), "user-b")
        let sdk = sdk(config: authConfig(token: jwt(sub: "user-a")))
        sdk.identify("user-a")
        sdk.setSdkAuthenticationToken(jwt(sub: "user-b"))
        sdk.identify("user-b")
        waitUntil { TestSupport.requests("/v1/identify").contains { $0.json?["userId"] as? String == "user-b" } }
        let identifyB = TestSupport.requests("/v1/identify").first { $0.json?["userId"] as? String == "user-b" }
        XCTAssertEqual(identifyB?.headers["X-Joryio-Auth"], jwt(sub: "user-b"))
    }

    // MARK: D-a - a retired token is persisted until its user's items settle

    func testARetiredTokenIsPersistedAndForgottenOnceItsUsersItemsAreGone() throws {
        var down = true
        StubURLProtocol.responder = { [ok] _ in down ? (503, Data()) : (200, ok) }
        let storage = TestSupport.storage()
        let sdk = sdk(config: authConfig(token: "token-of-a"), storage: storage)
        sdk.identify("user-a")
        sdk.track("a-event")
        sdk.reset()
        let persisted = try XCTUnwrap(storage.getRetiredAuthTokens(), "the retired token was memory-only")
        XCTAssertTrue(persisted.contains("token-of-a"))

        // A restart reads it back, bound to user-a.
        let restored = SdkAuthTokenStore(enabled: true, initialToken: nil, persistedRetired: persisted)
        XCTAssertEqual(restored.token(forSubject: "user-a", currentUserId: nil), "token-of-a")
        XCTAssertNil(restored.token(forSubject: nil, currentUserId: nil))

        down = false
        sdk.flush()
        sdk.writeOutboxForTesting?.kick(force: true)
        waitUntil(timeout: 20) { storage.getRetiredAuthTokens() == nil }
    }

    // MARK: D-b - identify while opted out only serves withdrawals

    func testIdentifyWhileOptedOutIsHeldForWithdrawalsOnly() {
        let sdk = sdk(config: TestSupport.sdkConfig(optOut: true))
        sdk.identify("held-user")
        XCTAssertNil(sdk.getUserId())
        sdk.setSubscription(channel: "email", status: "unsubscribed")
        waitUntil { !self.bodies("/v1/subscriptions/channel").isEmpty }
        XCTAssertEqual(bodies("/v1/subscriptions/channel").first?["userId"] as? String, "held-user")
        XCTAssertFalse(bodies("/v1/identify").contains { $0["userId"] as? String == "held-user" }, "identify reached the server while opted out")

        sdk.optIn()
        waitUntil { self.bodies("/v1/identify").contains { $0["userId"] as? String == "held-user" } }
        XCTAssertEqual(sdk.getUserId(), "held-user")
    }

    func testResetForgetsAHeldUserId() {
        let storage = TestSupport.storage()
        let sdk = sdk(config: TestSupport.sdkConfig(optOut: true), storage: storage)
        sdk.identify("held-user")
        sdk.reset()
        XCTAssertNil(storage.getHeldUserId())
    }

    // MARK: v5 49 - non-finite numbers

    func testANonFiniteEventPropertyIsDroppedAndTheEventKept() throws {
        let storage = TestSupport.storage()
        let sdk = sdk(storage: storage)
        sdk.track("n", properties: ["ok": 1, "bad": Double.nan, "nested": ["inf": Double.infinity, "y": 2], "list": [1.0, -Double.infinity]])
        let rows = try storage.dequeueQueuedEvents(limit: 10)
        XCTAssertEqual(rows.count, 1, "the event was lost")
        let props = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(rows[0].json.utf8)) as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertNil(props["bad"])
        XCTAssertEqual(props["ok"] as? Int, 1)
        XCTAssertEqual((props["nested"] as? [String: Any])?.keys.sorted(), ["y"])
        XCTAssertEqual((props["list"] as? [Double]), [1.0])
    }

    func testANonFiniteAttributeIsDroppedAndTheRestSent() async {
        let sdk = sdk()
        sdk.setAttributes(["plan": "pro", "score": Double.nan])
        sdk.incrementAttribute("visits", by: .infinity)
        await sdk.flushPendingAttributes()
        waitUntil { !self.bodies("/v1/attributes").isEmpty }
        let attrs = bodies("/v1/attributes").first?["attributes"] as? [String: Any]
        XCTAssertEqual(attrs?["plan"] as? String, "pro")
        XCTAssertNil(attrs?["score"])
        XCTAssertNil(bodies("/v1/attributes").first?["increment"])
    }

    // MARK: v5 59 - an iOS push token must be an APNs (hex) token

    func testAnFcmTokenIsRefused() {
        let sdk = sdk()
        var result: PushRegistrationResult?
        sdk.registerPushToken("fGx7:APA91bHPRgkF3JUikC4ENAHEeMrd41Zxv3hVZjC9KtT8OvPVGJ-hQMRKRrZuJAEcl7B338qju59zJMjw2DELjzEvxwYv7hH5Ynpc1ODQ0aT4U4OFEeBHWsext") { result = $0 }
        XCTAssertEqual(result?.success, false)
        XCTAssertEqual(result?.isRetryable, false)
        XCTAssertTrue(Joryio.isAPNsToken(String(repeating: "0a", count: 32)))
        XCTAssertFalse(Joryio.isAPNsToken(String(repeating: "0a", count: 31)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(TestSupport.requests("/v1/push/register").isEmpty)
    }

    // MARK: v5 57 - a host-held slot has a fallback after `displayed`

    func testAHostThatNeverReportsDismissedReleasesTheSlotEventually() async throws {
        let savedReport = InAppMessagingManager.hostReportTimeoutSeconds
        let savedDisplayed = InAppMessagingManager.hostDisplayedTimeoutSeconds
        InAppMessagingManager.hostReportTimeoutSeconds = 0.1
        InAppMessagingManager.hostDisplayedTimeoutSeconds = 0.4
        defer {
            InAppMessagingManager.hostReportTimeoutSeconds = savedReport
            InAppMessagingManager.hostDisplayedTimeoutSeconds = savedDisplayed
        }
        let storage = TestSupport.storage()
        let logger = TestSupport.logger()
        let manager = InAppMessagingManager(
            networkClient: TestSupport.network(), storage: storage,
            identityManager: IdentityManager(storage: storage, logger: logger),
            sessionManager: SessionManager(storage: storage, logger: logger, sessionTimeout: 1800), logger: logger
        )
        manager.onMessageReady = { _ in }
        manager.setActiveCampaignsForTesting([try TestSupport.campaign([
            "id": "held", "name": "held", "type": "modal", "priority": 1,
            "content": ["kind": "native", "title": "Hello", "body": "Body"],
        ])])
        await manager.evaluateCampaigns()
        manager.trackHostImpression(campaignId: "held", action: "displayed")
        manager.trackHostImpression(campaignId: "held", action: "clicked")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(manager.isDisplayingForTesting, "released before the displayed bound")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(manager.isDisplayingForTesting, "a host that never reported dismissed held the slot for good")
    }

    // MARK: N1 - undecodable triggers fail closed (P7)

    func testUndecodableTriggersDoNotDisplayOnSync() throws {
        let missingType = try TestSupport.campaign(["id": "c1", "name": "n", "type": "modal", "triggers": [["event": "Purchase"]]])
        XCTAssertFalse(InAppMessagingManager.displaysOnSync(missingType))
        let notAList = try TestSupport.campaign(["id": "c2", "name": "n", "type": "modal", "triggers": ["type": "immediate"]])
        XCTAssertFalse(InAppMessagingManager.displaysOnSync(notAList))
        let immediate = try TestSupport.campaign(["id": "c3", "name": "n", "type": "modal", "triggers": [["type": "immediate"], ["event": "x"]]])
        XCTAssertTrue(InAppMessagingManager.displaysOnSync(immediate))
        let none = try TestSupport.campaign(["id": "c4", "name": "n", "type": "modal"])
        XCTAssertTrue(InAppMessagingManager.displaysOnSync(none))
    }

    // MARK: N3 - server waits cannot trap

    func testHugeServerDelaysAreClamped() {
        XCTAssertEqual(InAppMessagingManager.nanoseconds(seconds: 1e12), 86_400 * 1_000_000_000)
        XCTAssertEqual(InAppMessagingManager.nanoseconds(seconds: .infinity), 0)
        XCTAssertEqual(InAppMessagingManager.nanoseconds(seconds: -5), 0)
    }

    // MARK: N5 - background push work finishes before the completion handler

    func testTheDeliveryReceiptIsSentBeforeTheCompletionHandler() {
        StubURLProtocol.delayFor = { _ in 0.3 }
        let sdk = sdk()
        let done = expectation(description: "completion")
        var receiptsAtCompletion = -1
        sdk.didReceiveRemoteNotification(["joryio": "true", "trackingId": "t-55"]) { _ in
            receiptsAtCompletion = StubURLProtocol.requests.filter { $0.url.path.contains("/track/push/delivered/t-55") }.count
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(receiptsAtCompletion, 1, "the handler was called before the receipt was sent")
    }

    // MARK: N6 - push_permission is reported again after a discard

    func testADiscardForgetsTheReportedPushPermission() {
        let storage = TestSupport.storage()
        let sdk = sdk(storage: storage)
        storage.setReportedPushPermission("granted")
        sdk.optOut()
        XCTAssertNil(storage.getReportedPushPermission())
    }

    // MARK: S8 - privacy manifest ships with the SDK

    func testThePrivacyManifestIsBundled() throws {
        let fm = FileManager.default
        var roots = Bundle.allBundles.map(\.bundleURL) + Bundle.allFrameworks.map(\.bundleURL)
        roots.append(Bundle(for: Self.self).bundleURL.deletingLastPathComponent())
        var found: URL?
        for root in roots where found == nil {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.lastPathComponent == "PrivacyInfo.xcprivacy"
                && url.deletingLastPathComponent().lastPathComponent.hasPrefix("Joryio_") {
                found = url
                break
            }
        }
        let url = try XCTUnwrap(found, "no PrivacyInfo.xcprivacy in the Joryio resource bundle")
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        let apis = plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        let defaults = apis.first { $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults" }
        XCTAssertEqual(defaults?["NSPrivacyAccessedAPITypeReasons"] as? [String], ["CA92.1"])
        let collected = (plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []).compactMap { $0["NSPrivacyCollectedDataType"] as? String }
        XCTAssertTrue(collected.contains("NSPrivacyCollectedDataTypeDeviceID"))
        XCTAssertTrue(collected.contains("NSPrivacyCollectedDataTypeUserID"))
        // Owner decision 2026-10-07: no location
        // is declared (the IP-derived country is not data the SDK collects),
        // and every declared type carries the App Functionality purpose.
        XCTAssertFalse(collected.contains("NSPrivacyCollectedDataTypeCoarseLocation"))
        let types = plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []
        for entry in types {
            let purposes = entry["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? []
            XCTAssertTrue(purposes.contains("NSPrivacyCollectedDataTypePurposeAppFunctionality"),
                          "\(entry["NSPrivacyCollectedDataType"] ?? "?") lacks App Functionality")
        }
    }
}
