import XCTest
@testable import Joryio

/// Release round 9 (SDK contract v9, 89): wipeData() keeps a held user's own
/// token that came through standby (scan 9, B1), and a pre-init wipe keeps
/// the token supplied for this launch (scan 9, S1). Lifted from the scan-9
/// probes; each failed on 56fefc54c.
final class ReleaseRound9Tests: XCTestCase {

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

    private final class Phase { var value = 1; let lock = NSLock()
        func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: Int) { lock.lock(); value = v; lock.unlock() } }

    /// Q1: the documented login flow (set B's token, reset(), identify(B)) on
    /// a device that has opted out: identify(B) is HELD (D-b) and does not
    /// adopt B's standby token. B unsubscribes (offline at first), then asks
    /// for erasure: wipeData() drops every standby token - B's own - and B's
    /// queued unsubscribe goes out with no token.
    func runHeldStandbyWipe(withReset: Bool, grace: TimeInterval = 0) -> (kept: String, header: String?, sawAfterWipe: Bool) {
        let tokenB = jwt("user-b")
        let phase = Phase()
        StubURLProtocol.responder = { [ok, missing] request in
            guard request.url!.path.hasSuffix("/v1/subscriptions/channel") else { return (200, ok) }
            if phase.get() == 1 { return (503, Data()) }
            if request.value(forHTTPHeaderField: "X-Joryio-Auth") == nil { return (401, missing) }
            return (200, ok)
        }
        let storage = TestSupport.storage()
        let sdk = TestSupport.sdk(
            config: JoryioConfig(flushInterval: 3600, trackSessionStart: false, inApp: InAppConfig(enabled: false), maxRetries: 0,
                                 enableSdkAuthentication: true, trackingConsent: .granted),
            storage: storage, retiredTokenSettleGrace: grace
        )
        sdk.optOut()
        sdk.setSdkAuthenticationToken(tokenB)
        if withReset { sdk.reset() }
        sdk.identify("user-b") // held: opted out
        sdk.setSubscription(channel: "email", status: "unsubscribed")
        waitUntil { !TestSupport.requests("/v1/subscriptions/channel").isEmpty }
        let before = TestSupport.requests("/v1/subscriptions/channel").count
        phase.set(2)
        sdk.wipeData()
        let kept = storage.getRetiredAuthTokens() ?? ""
        waitUntil(timeout: 12) { TestSupport.requests("/v1/subscriptions/channel").count > before }
        let after = TestSupport.requests("/v1/subscriptions/channel")
        let last = after.last
        return (kept, last?.headers["X-Joryio-Auth"], after.count > before && (last?.json?["userId"] as? String) == "user-b")
    }

    func testB1_heldUsersStandbyTokenSurvivesWipeForTheirUnsubscribe() {
        let r = runHeldStandbyWipe(withReset: true)
        XCTAssertTrue(r.sawAfterWipe, "precondition: B's unsubscribe was retried after the wipe")
        XCTAssertTrue(r.kept.contains("user-b"), "B's token was dropped by the wipe: \(r.kept)")
        XCTAssertEqual(r.header, jwt("user-b"), "B's unsubscribe went out without B's token after wipeData()")
    }


    func testB1_prodGrace() {
        let r = runHeldStandbyWipe(withReset: true, grace: 60)
        XCTAssertTrue(r.sawAfterWipe)
        XCTAssertEqual(r.header, jwt("user-b"), "G-Q1: B's unsubscribe without token (grace 60)")
    }
    func testS1_freshDevice_prodGrace() {
        XCTAssertEqual(runPreInitWipe(storedUser: nil, grace: 60), jwt("user-b"), "G-Q2a (grace 60)")
    }
    func testS1_previousUserStored_prodGrace() {
        XCTAssertEqual(runPreInitWipe(storedUser: "user-a", grace: 60), jwt("user-b"), "G-Q2b (grace 60)")
    }
    func testB1control_withoutResetTheTokenIsKept() {
        let r = runHeldStandbyWipe(withReset: false)
        XCTAssertTrue(r.sawAfterWipe)
        XCTAssertTrue(r.kept.contains("user-b"), "kept: \(r.kept)")
        XCTAssertEqual(r.header, jwt("user-b"))
    }

    private func batch(containing type: String) -> StubURLProtocol.Captured? {
        TestSupport.requests("/v1/track/batch").first { r in
            ((r.json?["events"] as? [[String: Any]]) ?? []).contains { $0["type"] as? String == type }
        }
    }

    /// Q2: a wipeData() made before initialize() runs inside initialize(),
    /// AFTER the session token from the config (or a pre-init
    /// setSdkAuthenticationToken) is seeded. Round 8's standby-while-anonymous
    /// rule files that token as standby and dropStandby() deletes it, so the
    /// user the app signs in right after init has no token.
    func runPreInitWipe(storedUser: String?, grace: TimeInterval = 0) -> String? {
        StubURLProtocol.responder = { [ok] _ in (200, ok) }
        let defaults = TestSupport.defaults()
        let storage = TestSupport.storage(defaults: defaults)
        if let storedUser {
            let first = TestSupport.sdk(config: TestSupport.sdkConfig(), storage: storage, defaults: defaults)
            first.identify(storedUser)
            first.track("prev")
            first.flush()
            waitUntil { self.batch(containing: "prev") != nil }
        }
        let sdk = TestSupport.sdk(storage: storage, defaults: defaults, initialize: false, retiredTokenSettleGrace: grace)
        sdk.wipeData()
        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: JoryioConfig(
            flushInterval: 3600, trackSessionStart: false, inApp: InAppConfig(enabled: false), maxRetries: 0,
            sdkAuthenticationToken: jwt("user-b"), trackingConsent: .granted))
        sdk.identify("user-b")
        sdk.track("b-event")
        sdk.flush()
        waitUntil { self.batch(containing: "b-event") != nil }
        return batch(containing: "b-event")?.headers["X-Joryio-Auth"]
    }

    func testS1_configTokenSurvivesAPreInitWipe_freshDevice() {
        XCTAssertEqual(runPreInitWipe(storedUser: nil), jwt("user-b"), "the config token was erased by the pre-init wipe")
    }

    func testS1_configTokenSurvivesAPreInitWipe_previousUserStored() {
        XCTAssertEqual(runPreInitWipe(storedUser: "user-a"), jwt("user-b"), "the config token was erased by the pre-init wipe")
    }

    /// Lead 1 (web B1 cross-check): standby adopted at identify, then an app
    /// RESTART with no token set yet, then unsubscribe + wipeData(). Compared
    /// with the plain flow (token set, identify, restart). Records the header
    /// the unsubscribe carried after the wipe; both are expected EQUAL.
    func runRestartWipe(viaStandby: Bool) -> String? {
        let tokenE = jwt("user-e")
        let phase = Phase()
        StubURLProtocol.responder = { [ok, missing] request in
            guard request.url!.path.hasSuffix("/v1/subscriptions/channel") else { return (200, ok) }
            if phase.get() == 1 { return (503, Data()) }
            if request.value(forHTTPHeaderField: "X-Joryio-Auth") == nil { return (401, missing) }
            return (200, ok)
        }
        let defaults = TestSupport.defaults()
        let storage = TestSupport.storage(defaults: defaults)
        let cfg = JoryioConfig(flushInterval: 3600, trackSessionStart: false, inApp: InAppConfig(enabled: false), maxRetries: 0, trackingConsent: .granted)
        let first = TestSupport.sdk(config: cfg, storage: storage, defaults: defaults)
        first.setSdkAuthenticationToken(tokenE)
        if viaStandby { first.reset() }
        first.identify("user-e")
        first.flush()
        waitUntil { !TestSupport.requests("/v1/identify").isEmpty }
        let second = TestSupport.sdk(config: cfg, storage: storage, defaults: defaults)
        XCTAssertEqual(second.getUserId(), "user-e")
        second.setSubscription(channel: "email", status: "unsubscribed")
        waitUntil { !TestSupport.requests("/v1/subscriptions/channel").isEmpty }
        let before = TestSupport.requests("/v1/subscriptions/channel").count
        phase.set(2)
        second.wipeData()
        waitUntil(timeout: 12) { TestSupport.requests("/v1/subscriptions/channel").count > before }
        return TestSupport.requests("/v1/subscriptions/channel").last?.headers["X-Joryio-Auth"]
    }

    func testL1_restartAfterAdoptionMatchesPlainFlow() {
        let viaStandby = runRestartWipe(viaStandby: true)
        StubURLProtocol.reset()
        let plain = runRestartWipe(viaStandby: false)
        XCTAssertEqual(viaStandby, plain)
    }
    /// A user held at the last launch whose token is still filed as standby
    /// (written by a build without the held-identify fix): restored as
    /// theirs at init, not dropped by the next wipe.
    func testB1_restoredHeldUsersStandbyTokenIsTheirsAtInit() {
        StubURLProtocol.responder = { [ok] _ in (200, ok) }
        let defaults = TestSupport.defaults()
        let storage = TestSupport.storage(defaults: defaults)
        let tokenB = jwt("user-b")
        storage.setHeldUserId("user-b")
        storage.setRetiredAuthTokens(#"[{"userId":"user-b","token":"\#(tokenB)","retiredAt":\#(Date().timeIntervalSince1970),"standby":true}]"#)
        let sdk = TestSupport.sdk(config: TestSupport.sdkConfig(optOut: true), storage: storage, defaults: defaults, retiredTokenSettleGrace: 60)
        let kept = storage.getRetiredAuthTokens() ?? ""
        XCTAssertTrue(kept.contains("user-b"), "kept: \(kept)")
        XCTAssertFalse(kept.contains("standby"), "the held user's token is still on standby: \(kept)")
        sdk.wipeData()
        XCTAssertTrue((storage.getRetiredAuthTokens() ?? "").contains("user-b"))
    }

    /// The store: a standby entry survives dropStandby() when it is the
    /// erased user's, when its user still has a withdrawal queued, or when
    /// it holds the token to keep; a true standby entry is dropped.
    func testDropStandbyKeepsErasedQueuedAndKeptTokens() {
        func entry(_ user: String) -> String {
            #"{"userId":"\#(user)","token":"\#(jwt(user))","retiredAt":\#(Date().timeIntervalSince1970),"standby":true}"#
        }
        let persisted = "[" + ["erased", "queued", "kept", "nobody"].map(entry).joined(separator: ",") + "]"
        let store = SdkAuthTokenStore(enabled: true, initialToken: nil, persistedRetired: persisted)
        store.dropStandby(keepingUser: "erased", keepingToken: jwt("kept")) { $0 == "queued" }
        XCTAssertEqual(store.retiredUserIds, ["erased", "queued", "kept"])
        store.dropStandby()
        XCTAssertEqual(store.retiredUserIds, [])
    }
}
