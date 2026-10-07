import XCTest
@testable import Joryio

/// Round 8 (SDK contract v8, rules 81, 82 and 85). R1-R4 are the scan 8
/// probes, lifted as regression tests: each failed on dc70d92d9.
final class ReleaseRound8Tests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private let ok = Data(#"{"success":true}"#.utf8)
    private let missing = Data(#"{"error":"sdk_authentication_error","reason":"missing"}"#.utf8)

    private func jwt(_ sub: String) -> String {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        return b64(#"{"alg":"HS256"}"#) + "." + b64("{\"sub\":\"\(sub)\"}") + ".sig"
    }

    private func batch(containing type: String) -> StubURLProtocol.Captured? {
        TestSupport.requests("/v1/track/batch").first { r in
            ((r.json?["events"] as? [[String: Any]]) ?? []).contains { $0["type"] as? String == type }
        }
    }

    /// R1: an app that turns SDK authentication on only by setting a token
    /// (no `enableSdkAuthentication` in the config - the documented way).
    /// Launch 1: token, identify(A), reset(). Launch 2: identify(A) again
    /// before the app sets a token. Round 7's adoptRetired() moves A's kept
    /// token into the session and empties `retired`, so `enabled`
    /// (`isEnabled || !retired.isEmpty`) turns FALSE: no token is attached
    /// and the 401 never reaches the app's handler.
    func testR1_adoptingTheOnlyKeptTokenAfterARestartKeepsAuthenticationOn() {
        let tokenA = jwt("user-a")
        StubURLProtocol.responder = { [ok, missing] request in
            if request.url!.path.hasSuffix("/v1/track/batch") || request.url!.path.hasSuffix("/v1/identify") {
                let json = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                let identified = json?["userId"] != nil
                    || ((json?["events"] as? [[String: Any]]) ?? []).contains { $0["userId"] != nil }
                if identified, request.value(forHTTPHeaderField: "X-Joryio-Auth") == nil { return (401, missing) }
            }
            return (200, ok)
        }
        let defaults = TestSupport.defaults()
        let storage = TestSupport.storage(defaults: defaults)
        let first = TestSupport.sdk(config: TestSupport.sdkConfig(), storage: storage, defaults: defaults, retiredTokenSettleGrace: 3600)
        first.setSdkAuthenticationToken(tokenA)
        first.identify("user-a")
        first.track("a1")
        first.flush()
        waitUntil { self.batch(containing: "a1") != nil }
        first.reset()
        XCTAssertNotNil(storage.getRetiredAuthTokens(), "precondition: A's token is kept")

        // Next launch: same config (no flag), A signs in again.
        StubURLProtocol.reset()
        StubURLProtocol.responder = { [ok, missing] request in
            let json = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let identified = json?["userId"] != nil
                || ((json?["events"] as? [[String: Any]]) ?? []).contains { $0["userId"] != nil }
            if identified, request.value(forHTTPHeaderField: "X-Joryio-Auth") == nil { return (401, missing) }
            return (200, ok)
        }
        let second = TestSupport.sdk(config: TestSupport.sdkConfig(), storage: storage, defaults: defaults, retiredTokenSettleGrace: 3600)
        var asked = 0
        let lock = NSLock()
        second.setSdkAuthenticationErrorHandler { _ in lock.lock(); asked += 1; lock.unlock() }
        second.identify("user-a")
        second.track("a2")
        second.flush()
        waitUntil(timeout: 8) { self.batch(containing: "a2") != nil }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        lock.lock(); let calls = asked; lock.unlock()
        let header = batch(containing: "a2")?.headers["X-Joryio-Auth"]
        XCTAssertTrue(header == tokenA || calls > 0,
                      "A's events went out with no token AND the app's handler was never asked (header \(String(describing: header)), handler calls \(calls))")
    }

    /// R2: the standby rule needs an IDENTIFIED outgoing user. An anonymous
    /// session that sets B's token, calls reset() (a "fresh start" at
    /// login) and identifies B after the grace minute (or after a relaunch)
    /// loses B's token: it was filed under B as an ordinary retired token,
    /// with nothing queued for B, and pruned. Tests run with grace 0.
    func testR2_tokenSetWhileAnonymousSurvivesResetUntilIdentify() {
        let tokenB = jwt("user-b")
        StubURLProtocol.responder = { [ok] _ in (200, ok) }
        let sdk = TestSupport.sdk(config: TestSupport.sdkConfig())
        sdk.setSdkAuthenticationToken(tokenB)
        sdk.reset()
        sdk.track("anon")
        sdk.flush()
        waitUntil { self.batch(containing: "anon") != nil }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        sdk.identify("user-b")
        sdk.track("b")
        sdk.flush()
        waitUntil { self.batch(containing: "b") != nil }
        XCTAssertEqual(batch(containing: "b")?.headers["X-Joryio-Auth"], tokenB, "B's events went out without B's token")
    }

    /// R3: wipeData() keeps a standby token (another person's JWT, nothing
    /// queued for them) in the Keychain for up to 30 days.
    func testR3_wipeDataDoesNotKeepAStandbyTokenForSomeoneNotSignedIn() {
        StubURLProtocol.responder = { [ok] _ in (200, ok) }
        let storage = TestSupport.storage()
        let sdk = TestSupport.sdk(
            config: JoryioConfig(flushInterval: 3600, trackSessionStart: false, inApp: InAppConfig(enabled: false), maxRetries: 0,
                                 sdkAuthenticationToken: jwt("user-a"), trackingConsent: .granted),
            storage: storage
        )
        sdk.identify("user-a")
        sdk.setSdkAuthenticationToken(jwt("user-b"))
        sdk.wipeData()
        sdk.track("after")
        sdk.flush()
        waitUntil { self.batch(containing: "after") != nil }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let kept = storage.getRetiredAuthTokens() ?? ""
        XCTAssertFalse(kept.contains("user-b") || kept.contains(jwt("user-b")), "after an erasure the Keychain still holds: \(kept)")
    }

    /// R4: the push-click beacon attaches the session token whatever its
    /// `sub` (contract v7 72: a token naming someone else is never attached).
    func testR4_pushClickNeverCarriesAnotherUsersToken() {
        StubURLProtocol.responder = { [ok] _ in (200, ok) }
        let sdk = TestSupport.sdk(config: JoryioConfig(
            flushInterval: 3600, trackSessionStart: false, inApp: InAppConfig(enabled: false), maxRetries: 0,
            sdkAuthenticationToken: jwt("user-a"), trackingConsent: .granted))
        sdk.identify("user-a")
        sdk.setSdkAuthenticationToken(jwt("user-b")) // B's, before identify(B)
        sdk.trackPushClick(trackingId: "tid")
        waitUntil { !TestSupport.requests("/track/push/click/tid").isEmpty }
        let header = TestSupport.requests("/track/push/click/tid").first?.headers["X-Joryio-Auth"]
        XCTAssertNotEqual(header, jwt("user-b"), "user-a's push click carried user-b's token")
    }

    private func sentEvents() -> [[String: Any]] {
        TestSupport.requests("/v1/track/batch").flatMap { ($0.json?["events"] as? [[String: Any]]) ?? [] }
    }

    /// R2 with the D-b held user: a token whose `sub` is the HELD user (no
    /// one identified, tracking off) is that user's, not a standby token -
    /// wipeData() keeps it for the withdrawal it queued, and the
    /// withdrawal still carries it.
    func testAHeldUsersTokenIsKeptThroughAWipeForTheirWithdrawal() {
        let tokenB = jwt("user-b")
        let lock = NSLock()
        var accept = false
        StubURLProtocol.responder = { [ok] request in
            lock.lock(); defer { lock.unlock() }
            return request.url!.path.hasSuffix("/v1/subscriptions/channel") && !accept ? (503, Data()) : (200, ok)
        }
        let sdk = TestSupport.sdk(config: JoryioConfig(
            flushInterval: 3600, trackSessionStart: false, inApp: InAppConfig(enabled: false), maxRetries: 0,
            sdkAuthenticationToken: tokenB, trackingConsent: .granted))
        sdk.updateConsent(.denied)
        sdk.identify("user-b") // held (D-b); B's token stays the session's
        sdk.setSubscription(channel: "email", status: "unsubscribed")
        waitUntil { !TestSupport.requests("/v1/subscriptions/channel").isEmpty }
        sdk.wipeData()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let refused = TestSupport.requests("/v1/subscriptions/channel").count
        lock.lock(); accept = true; lock.unlock()
        sdk.flush()
        waitUntil(timeout: 20) { TestSupport.requests("/v1/subscriptions/channel").count > refused }
        let r = TestSupport.requests("/v1/subscriptions/channel").dropFirst(refused).first
        XCTAssertEqual(r?.json?["userId"] as? String, "user-b")
        XCTAssertEqual(r?.headers["X-Joryio-Auth"], tokenB, "the held user's withdrawal lost their token at the wipe")
    }

    /// Unit (v8 82): a readable `sub` that is not the outgoing user - with
    /// or without anyone identified - is kept on standby, and a wipe drops
    /// every standby token.
    func testStandbyRuleAndWipeDropUnit() {
        let store = SdkAuthTokenStore(enabled: false, initialToken: jwt("user-b"), settleGrace: 0)
        store.retireToken(forUser: nil)
        store.pruneRetired { _ in false }
        XCTAssertEqual(store.retiredUserIds, ["user-b"], "a token set while anonymous was pruned before its user signed in")
        store.dropStandby()
        XCTAssertEqual(store.retiredUserIds, [])
        // Its own user's token is not standby: kept only while needed.
        let own = SdkAuthTokenStore(enabled: false, initialToken: jwt("user-a"), settleGrace: 0)
        own.retireToken(forUser: "user-a")
        own.dropStandby()
        XCTAssertEqual(own.retiredUserIds, ["user-a"])
    }

    /// Unit (v8 81): adopting the only kept token keeps authentication on.
    func testAdoptingTheOnlyKeptTokenKeepsAuthenticationOnUnit() {
        var kept: String?
        let writer = SdkAuthTokenStore(enabled: false, initialToken: jwt("user-a"), persistRetired: { kept = $0 })
        writer.retireToken(forUser: "user-a")
        let next = SdkAuthTokenStore(enabled: false, initialToken: nil, persistedRetired: kept)
        XCTAssertTrue(next.enabled)
        next.adoptRetired(forUser: "user-a")
        XCTAssertTrue(next.enabled, "adopting the kept token switched SDK authentication off")
        XCTAssertEqual(next.token(forSubject: "user-a", currentUserId: "user-a"), jwt("user-a"))
    }

    // MARK: v8 85 - a Session Start owed by a denial survives a restart

    /// Launch 1 starts with consent denied: its session is never announced
    /// (owed). Launch 2, within the session timeout, starts with consent
    /// granted and resumes that session - which must be announced now.
    func testSessionOwedByADenialIsAnnouncedOnTheNextAllowedLaunch() {
        let defaults = TestSupport.defaults()
        let storage = TestSupport.storage(defaults: defaults)
        let first = TestSupport.sdk(config: TestSupport.sdkConfig(trackSessionStart: true, trackingConsent: .denied),
                                    storage: storage, defaults: defaults)
        first.track("while-denied")
        first.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(sentEvents().isEmpty)

        // Process killed; the next launch grants consent.
        let second = TestSupport.sdk(config: TestSupport.sdkConfig(trackSessionStart: true, trackingConsent: .granted),
                                     storage: storage, defaults: defaults)
        second.track("after")
        second.flush()
        waitUntil { self.sentEvents().contains { $0["type"] as? String == "after" } }
        let events = sentEvents()
        let after = events.first { $0["type"] as? String == "after" }
        let starts = events.filter { $0["type"] as? String == "Session Start" }
        XCTAssertEqual(starts.count, 1, "the session owed by the denial was never announced: \(events.map { $0["type"] as? String ?? "" })")
        XCTAssertEqual(starts.first?["sessionId"] as? String, after?["sessionId"] as? String)

        // Announced once: a third launch in the same session does not repeat it.
        StubURLProtocol.reset()
        let third = TestSupport.sdk(config: TestSupport.sdkConfig(trackSessionStart: true), storage: storage, defaults: defaults)
        third.track("third")
        third.flush()
        waitUntil { self.sentEvents().contains { $0["type"] as? String == "third" } }
        XCTAssertFalse(sentEvents().contains { $0["type"] as? String == "Session Start" }, "the resumed session was announced twice")
    }

    /// The same after a runtime opt-out (whose session was already
    /// announced): the next launch, opted in before init, announces a NEW
    /// session - never a second Session Start for the old one.
    func testSessionOwedByARuntimeOptOutIsAnnouncedAsANewSessionNextLaunch() {
        let defaults = TestSupport.defaults()
        let storage = TestSupport.storage(defaults: defaults)
        let first = TestSupport.sdk(config: TestSupport.sdkConfig(trackSessionStart: true), storage: storage, defaults: defaults)
        first.track("before")
        first.flush()
        waitUntil { self.sentEvents().contains { $0["type"] as? String == "before" } }
        let firstSession = sentEvents().first { $0["type"] as? String == "Session Start" }?["sessionId"] as? String
        XCTAssertNotNil(firstSession)
        first.optOut()

        StubURLProtocol.reset()
        let second = TestSupport.sdk(storage: storage, defaults: defaults, initialize: false)
        second.optIn()
        second.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test",
                          config: TestSupport.sdkConfig(trackSessionStart: true))
        second.track("after")
        second.flush()
        waitUntil { self.sentEvents().contains { $0["type"] as? String == "after" } }
        let events = sentEvents()
        let after = events.first { $0["type"] as? String == "after" }
        let starts = events.filter { $0["type"] as? String == "Session Start" }
        XCTAssertEqual(starts.count, 1, "the session after the opt-out was never announced: \(events.map { $0["type"] as? String ?? "" })")
        XCTAssertEqual(starts.first?["sessionId"] as? String, after?["sessionId"] as? String)
        XCTAssertNotEqual(starts.first?["sessionId"] as? String, firstSession, "a second Session Start for the already-announced session")
    }
}
