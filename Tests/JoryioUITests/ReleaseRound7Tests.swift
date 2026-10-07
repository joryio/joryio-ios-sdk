import XCTest
@testable import Joryio

/// Round 7 (SDK contract v7, rules 72-75). Q1-Q3 are the scan 7 probes,
/// lifted as regression tests: each failed on f31cd0f96.
final class ReleaseRound7Tests: XCTestCase {

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

    private func sentEvents() -> [[String: Any]] {
        TestSupport.requests("/v1/track/batch").flatMap { ($0.json?["events"] as? [[String: Any]]) ?? [] }
    }

    private func authConfig(token: String) -> JoryioConfig {
        JoryioConfig(
            flushInterval: 3600, trackSessionStart: false, inApp: InAppConfig(enabled: false), maxRetries: 0,
            sdkAuthenticationToken: token, trackingConsent: .granted
        )
    }

    // MARK: S1 / v7 75 - Session Start after a runtime wipe survives a restart

    /// Q1: wipeData() at runtime, then the app is closed before any event or
    /// foreground. The next launch, within the session timeout, resumes the
    /// wiped install's NEW session - which must still be announced.
    func testQ1_runtimeWipeThenRestartStillAnnouncesTheNewSession() {
        let defaults = TestSupport.defaults()
        let storage = TestSupport.storage(defaults: defaults)
        let first = TestSupport.sdk(config: TestSupport.sdkConfig(trackSessionStart: true), storage: storage, defaults: defaults)
        first.track("before")
        first.flush()
        waitUntil { self.sentEvents().contains { $0["type"] as? String == "before" } }
        first.wipeData()
        let anonymousId = first.getAnonymousId()

        // Process killed; next launch.
        let second = TestSupport.sdk(config: TestSupport.sdkConfig(trackSessionStart: true), storage: storage, defaults: defaults)
        XCTAssertEqual(second.getAnonymousId(), anonymousId)
        second.track("after")
        second.flush()
        waitUntil { self.sentEvents().contains { $0["type"] as? String == "after" } }
        let starts = sentEvents().filter { $0["type"] as? String == "Session Start" && $0["anonymousId"] as? String == anonymousId }
        XCTAssertEqual(starts.count, 1, "the wiped install's session was never announced: \(sentEvents().map { ($0["type"] as? String ?? "", $0["anonymousId"] as? String ?? "") })")

        // Announced once: a third launch in the same session does not repeat it.
        StubURLProtocol.reset()
        let third = TestSupport.sdk(config: TestSupport.sdkConfig(trackSessionStart: true), storage: storage, defaults: defaults)
        third.track("third")
        third.flush()
        waitUntil { self.sentEvents().contains { $0["type"] as? String == "third" } }
        XCTAssertFalse(sentEvents().contains { $0["type"] as? String == "Session Start" }, "the resumed session was announced twice")
    }

    // MARK: S2 / v7 72 - a token goes only to the user its `sub` names

    /// Q2: a flush between setSdkAuthenticationToken(B) and identify(B) sends
    /// A's events with A's own token, and never asks the app's handler about
    /// A's leftovers.
    func testQ2_aFlushBetweenSetTokenAndIdentifyUsesTheOutgoingUsersToken() {
        let tokenA = jwt("user-a")
        let tokenB = jwt("user-b")
        let mismatch = Data(#"{"error":"sdk_authentication_error","reason":"sub_mismatch"}"#.utf8)
        StubURLProtocol.responder = { [ok] request in
            if request.url!.path.hasSuffix("/v1/track/batch") {
                let json = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                let events = json?["events"] as? [[String: Any]] ?? []
                let header = request.value(forHTTPHeaderField: "X-Joryio-Auth")
                if events.contains(where: { $0["userId"] as? String == "user-a" }), header != tokenA {
                    return (401, mismatch)
                }
            }
            return (200, ok)
        }
        let sdk = TestSupport.sdk(config: authConfig(token: tokenA))
        var asked: [SdkAuthError] = []
        let lock = NSLock()
        sdk.setSdkAuthenticationErrorHandler { error in lock.lock(); asked.append(error); lock.unlock() }
        sdk.identify("user-a")
        sdk.track("a-event")
        sdk.setSdkAuthenticationToken(tokenB)
        sdk.flush() // a timer / sendImmediately flush in between
        waitUntil(timeout: 8) { !TestSupport.requests("/v1/track/batch").isEmpty }
        let first = TestSupport.requests("/v1/track/batch").first
        sdk.identify("user-b")
        RunLoop.current.run(until: Date().addingTimeInterval(6))
        lock.lock(); let calls = asked; lock.unlock()
        XCTAssertEqual(first?.headers["X-Joryio-Auth"], tokenA, "user-a's events went out with user-b's token")
        XCTAssertTrue(calls.isEmpty, "the app's auth handler was asked about user-a's leftovers: \(calls.map { "\($0.reason) exhausted=\($0.refreshExhausted)" })")
    }

    /// Q3 (N1): "set B's token, reset(), identify(B)" - B's own token is kept
    /// and B's requests carry it.
    func testQ3_tokenSetBeforeResetStillServesTheNextUser() {
        let tokenA = jwt("user-a")
        let tokenB = jwt("user-b")
        StubURLProtocol.responder = { [ok] _ in (200, ok) }
        let sdk = TestSupport.sdk(config: authConfig(token: tokenA))
        sdk.identify("user-a")
        sdk.setSdkAuthenticationToken(tokenB)
        sdk.reset()
        sdk.identify("user-b")
        sdk.track("b-event")
        sdk.flush()
        waitUntil { TestSupport.requests("/v1/track/batch").contains { r in
            ((r.json?["events"] as? [[String: Any]]) ?? []).contains { $0["type"] as? String == "b-event" } } }
        let r = TestSupport.requests("/v1/track/batch").first { r in
            ((r.json?["events"] as? [[String: Any]]) ?? []).contains { $0["type"] as? String == "b-event" } }
        XCTAssertEqual(r?.headers["X-Joryio-Auth"], tokenB, "user-b's own event went out without user-b's token")
    }

    /// A user held while tracking is off (D-b): their withdrawal carries
    /// their own kept token, not a session token set for someone else.
    func testHeldUsersWithdrawalCarriesTheirOwnKeptToken() {
        let tokenB = jwt("user-b")
        let tokenC = jwt("user-c")
        StubURLProtocol.responder = { [ok] _ in (200, ok) }
        let sdk = TestSupport.sdk(config: authConfig(token: tokenB))
        sdk.updateConsent(.denied)
        sdk.identify("user-b") // held; B's token stays the session's
        sdk.setSdkAuthenticationToken(tokenC) // B's token retired under B
        sdk.setSubscription(channel: "email", status: "unsubscribed")
        waitUntil { !TestSupport.requests("/v1/subscriptions/channel").isEmpty }
        let r = TestSupport.requests("/v1/subscriptions/channel").first
        XCTAssertEqual(r?.json?["userId"] as? String, "user-b")
        XCTAssertEqual(r?.headers["X-Joryio-Auth"], tokenB, "the held user's withdrawal carried another user's token")
    }

    /// Routing unit: a session token whose `sub` names someone else is never
    /// attached; a readable one goes to its own user even when not current.
    func testTokenRoutingBySubject() {
        let store = SdkAuthTokenStore(enabled: true, initialToken: jwt("user-a"))
        store.setToken(jwt("user-b")) // retires A's
        XCTAssertEqual(store.token(forSubject: "user-a", currentUserId: "user-a"), jwt("user-a"))
        XCTAssertEqual(store.token(forSubject: "user-b", currentUserId: "user-a"), jwt("user-b"))
        XCTAssertNil(store.token(forSubject: "user-z", currentUserId: "user-z"), "a token naming someone else was attached")
        // Opaque (unreadable) session token: the current user only.
        let opaque = SdkAuthTokenStore(enabled: true, initialToken: "opaque")
        XCTAssertEqual(opaque.token(forSubject: "user-a", currentUserId: "user-a"), "opaque")
        XCTAssertNil(opaque.token(forSubject: "user-x", currentUserId: "user-a"))
        // An anonymous request carries no token (contract v7 72, same on web
        // and Android): the server checks none, and none names the visitor.
        XCTAssertNil(opaque.token(forSubject: nil, currentUserId: "user-a"))
        XCTAssertNil(store.token(forSubject: nil, currentUserId: "user-a"))
    }

    /// v7 74: optOut(), reset(), optIn() - the logged-out user's queued
    /// opt-out record keeps its own ids and is still delivered; the re-sync
    /// for the NEXT person used to remove it.
    func testALoggedOutUsersQueuedOptOutRecordIsStillDelivered() {
        let lock = NSLock()
        var accept = false
        StubURLProtocol.responder = { [ok] request in
            lock.lock(); defer { lock.unlock() }
            return request.url!.path.hasSuffix("/v1/attributes") && !accept ? (503, Data()) : (200, ok)
        }
        let sdk = TestSupport.sdk(config: TestSupport.sdkConfig())
        sdk.identify("user-a")
        sdk.optOut()
        waitUntil { !TestSupport.requests("/v1/attributes").isEmpty }
        sdk.reset()
        sdk.optIn()
        // Let a retry still in flight for the refused attempt settle first.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let refused = TestSupport.requests("/v1/attributes").count
        lock.lock(); accept = true; lock.unlock()
        sdk.flush()
        waitUntil(timeout: 20) {
            TestSupport.requests("/v1/attributes").dropFirst(refused).contains {
                $0.json?["userId"] as? String == "user-a"
                    && (($0.json?["attributes"] as? [String: Any])?["tracking_opted_out"] as? Bool) == true
            }
        }
    }

    func testAnAnonymousRequestBodyCarriesNoToken() {
        let anonymous = Data(#"{"anonymousId":"anon-1","events":[{"event":"x","anonymousId":"anon-1"}]}"#.utf8)
        let identified = Data(#"{"userId":"user-a","anonymousId":"anon-1"}"#.utf8)
        XCTAssertNil(NetworkClient.subjectUserId(of: anonymous))
        XCTAssertEqual(NetworkClient.subjectUserId(of: identified), "user-a")
        let store = SdkAuthTokenStore(enabled: true, initialToken: jwt("user-a"))
        XCTAssertNil(store.token(forSubject: NetworkClient.subjectUserId(of: anonymous), currentUserId: "user-a"))
        XCTAssertEqual(store.token(forSubject: NetworkClient.subjectUserId(of: identified), currentUserId: "user-a"), jwt("user-a"))
    }

    // MARK: N2 / v7 74 - a forced drain never overrides a 402's Retry-After

    func testForcedDrainHonoursTheRetryAfterOfA402() async throws {
        var calls = 0
        let outbox = WriteOutbox(
            logger: TestSupport.logger(), load: { .value(nil) }, save: { _ in },
            sender: { _, _, _ in
                calls += 1
                return NetworkClient.classifyWriteResponse(status: 402, body: Data(), retryAfterHeader: "60")
            }
        )
        outbox.baseBackoff = 0.01
        outbox.add(OutboxEntry(kind: .identify, path: "/v1/identify", body: "{}", userId: "u"))
        await outbox.drain()
        XCTAssertEqual(calls, 1)
        await outbox.drain(force: true)
        XCTAssertEqual(calls, 1, "a forced drain resent a parked write before the server's Retry-After")
        // The outbox's own backoff alone (no Retry-After) is still lifted by force.
        var ownCalls = 0
        let own = WriteOutbox(
            logger: TestSupport.logger(), load: { .value(nil) }, save: { _ in },
            sender: { _, _, _ in
                ownCalls += 1
                return NetworkClient.classifyWriteResponse(status: 402, body: Data(), retryAfterHeader: nil)
            }
        )
        own.baseBackoff = 30
        own.add(OutboxEntry(kind: .identify, path: "/v1/identify", body: "{}", userId: "u"))
        await own.drain()
        await own.drain(force: true)
        XCTAssertEqual(ownCalls, 2)
    }

    // MARK: N3 - the held user id is not a Keychain read per request

    func testWithdrawalUserIdIsCachedButNeverCachesALockedKeychain() {
        let keychain = CountingSecureStore()
        let storage = TestSupport.storage(secureStore: keychain)
        storage.setHeldUserId("held-u")
        keychain.locked = true
        let identity = IdentityManager(storage: storage, logger: TestSupport.logger())
        XCTAssertNil(identity.withdrawalUserId(), "a locked Keychain reads as nothing")
        keychain.locked = false
        XCTAssertEqual(identity.withdrawalUserId(), "held-u", "an unreadable answer was cached as 'no held user'")
        let reads = keychain.heldReads
        for _ in 0..<100 { _ = identity.withdrawalUserId() }
        XCTAssertEqual(keychain.heldReads, reads, "every withdrawalUserId() was a Keychain read")
        identity.clearHeldUserId()
        XCTAssertNil(identity.withdrawalUserId())
        identity.holdUserId("next")
        XCTAssertEqual(identity.withdrawalUserId(), "next")
        XCTAssertEqual(storage.getHeldUserId(), "next")
    }

    // MARK: v7 73 - data calls made while opted out / denied are dropped at call time

    func testTrackWhileOptedOutBeforeInitIsNotSentAfterOptIn() {
        let defaults = TestSupport.defaults()
        let storage = TestSupport.storage(defaults: defaults)
        let sdk = TestSupport.sdk(storage: storage, defaults: defaults, initialize: false)
        sdk.optOut()
        sdk.track("while-opted-out")
        sdk.setAttributes(["plan": "pro"])
        sdk.optIn()
        sdk.track("after-opt-in")
        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: TestSupport.sdkConfig())
        sdk.flush()
        waitUntil { self.sentEvents().contains { $0["type"] as? String == "after-opt-in" } }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(sentEvents().contains { $0["type"] as? String == "while-opted-out" }, "an event tracked while opted out was sent after optIn()")
        XCTAssertTrue(TestSupport.requests("/v1/attributes").allSatisfy { r in
            (r.json?["attributes"] as? [String: Any])?["plan"] == nil }, "an attribute set while opted out was sent")
    }

    func testTrackWhileDeniedBeforeInitIsNotSentAfterGrant() {
        let defaults = TestSupport.defaults()
        let storage = TestSupport.storage(defaults: defaults)
        let sdk = TestSupport.sdk(storage: storage, defaults: defaults, initialize: false)
        sdk.updateConsent(.denied)
        sdk.track("while-denied")
        sdk.updateConsent(.granted)
        sdk.track("after-grant")
        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: TestSupport.sdkConfig())
        sdk.flush()
        waitUntil { self.sentEvents().contains { $0["type"] as? String == "after-grant" } }
        XCTAssertFalse(sentEvents().contains { $0["type"] as? String == "while-denied" }, "an event tracked while consent was denied was sent after the grant")
    }

    /// identify() is not dropped: its user id is still held for withdrawals (D-b).
    func testIdentifyWhileOptedOutBeforeInitIsStillHeldForWithdrawals() {
        let defaults = TestSupport.defaults()
        let storage = TestSupport.storage(defaults: defaults)
        let sdk = TestSupport.sdk(storage: storage, defaults: defaults, initialize: false)
        sdk.optOut()
        sdk.identify("held-user")
        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: TestSupport.sdkConfig())
        sdk.setSubscription(channel: "email", status: "unsubscribed")
        waitUntil { !TestSupport.requests("/v1/subscriptions/channel").isEmpty }
        XCTAssertEqual(TestSupport.requests("/v1/subscriptions/channel").first?.json?["userId"] as? String, "held-user")
    }
}

/// A Keychain stand-in that counts reads of the held user id.
private final class CountingSecureStore: SecureStore {
    private var items: [String: String] = [:]
    private let lock = NSLock()
    var locked = false
    private(set) var heldReads = 0

    func isProtectedDataAvailable() -> Bool { !locked }

    @discardableResult
    func setString(_ value: String, forKey account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        items[account] = value
        return true
    }

    func getString(forKey account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if account == "held_user_id" { heldReads += 1 }
        return locked ? nil : items[account]
    }

    func removeItem(forKey account: String) {
        lock.lock(); defer { lock.unlock() }
        items.removeValue(forKey: account)
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        items.removeAll()
    }
}
