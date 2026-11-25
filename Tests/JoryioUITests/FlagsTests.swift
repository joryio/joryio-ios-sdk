import XCTest
@testable import Joryio

/// Feature flags (BACKLOG D446): the same behaviour as the web SDK's flags.spec.ts.
final class FlagsTests: XCTestCase {

    /// A fake backend for FlagsManager: records every POST and answers /evaluate with `answer`.
    final class FakeServer {
        private let lock = NSLock()
        private var _calls: [(path: String, body: [String: Any])] = []
        var answer: [String: Any] = [:]
        var delay: TimeInterval = 0

        var calls: [(path: String, body: [String: Any])] { lock.lock(); defer { lock.unlock() }; return _calls }
        func calls(_ path: String) -> [[String: Any]] { calls.filter { $0.path == path }.map { $0.body } }

        func post(_ path: String, _ body: Data) async -> [String: Any]? {
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            lock.lock(); _calls.append((path, json)); let a = answer; let d = delay; lock.unlock()
            if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000)) }
            return path == "/v1/flags/evaluate" ? a : ["success": true]
        }
    }

    final class State {
        var canSend = true
        var userId: String?
        var anonymousId = "anon-1"
        var sessionId = "s-1"
        var stored: String?
        var storedExposures: String?
        var now = Date()
    }

    static func flag(_ value: Any, _ type: String, variant: String = "on", log: Bool = true) -> [String: Any] {
        ["value": value, "variant": variant, "valueType": type, "reason": "rule", "version": 1, "logExposure": log]
    }

    static let answer: [String: Any] = [
        "etag": "e1",
        "ttlSeconds": 300,
        "flags": [
            "new_checkout": flag(true, "boolean"),
            "headline": flag("Hello", "string", variant: "b"),
            "limit": flag(5, "number"),
            "theme": flag(["color": "teal"], "json"),
            "quiet": flag(true, "boolean", log: false),
        ],
    ]

    private func manager(_ server: FakeServer, _ state: State) -> FlagsManager {
        FlagsManager(FlagsManager.Dependencies(
            post: { await server.post($0, $1) },
            canSend: { state.canSend },
            userId: { state.userId },
            anonymousId: { state.anonymousId },
            sessionId: { state.sessionId },
            attributes: { ["plan": "pro"] },
            context: { ["platform": "ios"] },
            load: { state.stored },
            save: { state.stored = $0 },
            callbackQueue: DispatchQueue.global(),
            now: { state.now },
            exposureFlushDelay: 0.05,
            loadExposures: { state.storedExposures },
            saveExposures: { state.storedExposures = $0 }
        ))
    }

    private func ready(_ server: FakeServer = FakeServer(), _ state: State = State()) async -> (FlagsManager, FakeServer, State) {
        server.answer = Self.answer
        let m = manager(server, state)
        await m.refreshFlags()
        return (m, server, state)
    }

    /// The cached answer is per workspace (security review 2026-11-21): the kv
    /// table is one database per app, so the key carries the SDK key.
    func testStorageKeyIsPerSdkKey() {
        XCTAssertEqual(FlagsManager.storageKey(sdkKey: "jry_live_a"), "jry_jry_live_a_flags_cache")
        XCTAssertNotEqual(FlagsManager.storageKey(sdkKey: "jry_live_a"), FlagsManager.storageKey(sdkKey: "jry_live_b"))
        XCTAssertNotEqual(FlagsManager.storageKey(sdkKey: "jry_live_a"), FlagsManager.legacyStorageKey)
    }

    /// The placements cache is per workspace in the same way (same review, after #787).
    func testPlacementsStorageKeyIsPerSdkKey() {
        XCTAssertEqual(Joryio.placementsStorageKey(sdkKey: "jry_live_a"), "jry_jry_live_a_placements_cache")
        XCTAssertNotEqual(Joryio.placementsStorageKey(sdkKey: "jry_live_a"), Joryio.placementsStorageKey(sdkKey: "jry_live_b"))
        XCTAssertNotEqual(Joryio.placementsStorageKey(sdkKey: "jry_live_a"), Joryio.legacyPlacementsStorageKey)
    }

    func testNothingIsFetchedUntilTheAppUsesFlags() {
        let server = FakeServer()
        let m = manager(server, State())
        m.start()
        m.onForeground()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(server.calls.isEmpty)
        _ = m.getBoolFlag("new_checkout", default: false)
        waitUntil(timeout: 2) { server.calls("/v1/flags/evaluate").count == 1 }
    }

    func testTheGettersReturnTheServerValueOrTheDefault() async {
        let (m, server, _) = await ready()
        XCTAssertEqual(m.getBoolFlag("new_checkout", default: false), true)
        XCTAssertEqual(m.getStringFlag("headline", default: "x"), "Hello")
        XCTAssertEqual(m.getNumberFlag("limit", default: 1), 5)
        XCTAssertEqual((m.getJsonFlag("theme", default: nil) as? [String: Any])?["color"] as? String, "teal")
        XCTAssertEqual(m.getFlag("headline", default: "x") as? String, "Hello")
        // Missing, or another type: the in-code default.
        XCTAssertEqual(m.getBoolFlag("missing", default: true), true)
        XCTAssertEqual(m.getBoolFlag("headline", default: false), false)
        XCTAssertEqual(m.getNumberFlag("new_checkout", default: 7), 7, "a boolean is not a number")
        struct Theme: Decodable { let color: String }
        XCTAssertEqual(m.getJsonFlag("theme", as: Theme.self, default: Theme(color: "x")).color, "teal")
        // The request: wire names identical to web.
        let body = server.calls("/v1/flags/evaluate")[0]
        XCTAssertEqual(body["anonymousId"] as? String, "anon-1")
        XCTAssertEqual(body["sessionId"] as? String, "s-1")
        XCTAssertEqual((body["context"] as? [String: Any])?["platform"] as? String, "ios")
        XCTAssertEqual((body["attributes"] as? [String: Any])?["plan"] as? String, "pro")
        XCTAssertNil(body["etag"])
    }

    func testTheEtagIsSentBackAndNotModifiedKeepsTheFlags() async {
        let (m, server, _) = await ready()
        server.answer = ["notModified": true, "etag": "e1", "flags": [:]]
        await m.refreshFlags()
        XCTAssertEqual(server.calls("/v1/flags/evaluate").last?["etag"] as? String, "e1")
        XCTAssertEqual(m.getStringFlag("headline", default: "x"), "Hello")
    }

    func testForegroundRefreshesAtMostOncePerMinute() async {
        let (m, server, state) = await ready()
        await m.refresh(force: false)
        XCTAssertEqual(server.calls("/v1/flags/evaluate").count, 1)
        state.now = state.now.addingTimeInterval(JoryioFlags.FLAGS_MIN_REFRESH_SECONDS + 1)
        await m.refresh(force: false)
        XCTAssertEqual(server.calls("/v1/flags/evaluate").count, 2)
    }

    func testOneExposurePerFlagAndVariantPerSessionHonouringLogExposure() async {
        let (m, server, state) = await ready()
        _ = m.getBoolFlag("new_checkout", default: false)
        _ = m.getBoolFlag("new_checkout", default: false)
        _ = m.getStringFlag("headline", default: "")
        _ = m.getBoolFlag("quiet", default: false) // logExposure: false
        _ = m.getAllFlags() // logs nothing
        waitUntil(timeout: 2) { server.calls("/v1/flags/exposures").count == 1 }
        let body = server.calls("/v1/flags/exposures")[0]
        let exposures = body["exposures"] as? [[String: String]] ?? []
        XCTAssertEqual(exposures.map { $0["key"]! }.sorted(), ["headline", "new_checkout"])
        XCTAssertEqual(exposures.first { $0["key"] == "headline" }?["variant"], "b")
        XCTAssertEqual(body["anonymousId"] as? String, "anon-1")
        // A new session reports again.
        state.sessionId = "s-2"
        _ = m.getBoolFlag("new_checkout", default: false)
        waitUntil(timeout: 2) { server.calls("/v1/flags/exposures").count == 2 }
        // 1.4.0-beta.12: one idempotencyKey (a lowercase UUID) per batch, the same wire value as Android and the web.
        let keys = server.calls("/v1/flags/exposures").compactMap { $0["idempotencyKey"] as? String }
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(Set(keys).count, 2, "one key per batch")
        for k in keys { XCTAssertNotNil(k.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression), k) }
    }

    func testGetAllFlagsLogsNoExposure() async {
        let (m, server, _) = await ready()
        let all = m.getAllFlags()
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(all["headline"] as? String, "Hello")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(server.calls("/v1/flags/exposures").isEmpty)
    }

    func testAnExposureBatchIsSentAsThePersonWhoReadIt() async {
        let (m, server, state) = await ready()
        _ = m.getBoolFlag("new_checkout", default: false) // read as anon-1
        state.userId = "user-b"
        state.anonymousId = "anon-2"
        m.onIdentityChanged()
        waitUntil(timeout: 2) { server.calls("/v1/flags/exposures").count == 1 }
        let body = server.calls("/v1/flags/exposures")[0]
        XCTAssertNil(body["userId"], "never sent as the next person")
        XCTAssertEqual(body["anonymousId"] as? String, "anon-1")
        // The next person's evaluation names them.
        waitUntil(timeout: 2) { server.calls("/v1/flags/evaluate").count == 2 }
        XCTAssertEqual(server.calls("/v1/flags/evaluate")[1]["userId"] as? String, "user-b")
    }

    func testTheSamePersonAfterAnAccountSwitchInOneSessionIsReportedAgain() async {
        let (m, server, state) = await ready()
        _ = m.getBoolFlag("new_checkout", default: false)
        state.userId = "user-b"
        m.onIdentityChanged()
        await m.refreshFlags()
        _ = m.getBoolFlag("new_checkout", default: false)
        waitUntil(timeout: 2) { server.calls("/v1/flags/exposures").count == 2 }
        XCTAssertEqual(server.calls("/v1/flags/exposures")[1]["userId"] as? String, "user-b")
    }

    func testWithdrawnConsentDropsTheBatchAndTheGettersReturnTheDefault() async {
        let (m, server, state) = await ready()
        _ = m.getBoolFlag("new_checkout", default: false)
        state.canSend = false
        m.onIdentityChanged()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(server.calls("/v1/flags/exposures").isEmpty)
        XCTAssertEqual(m.getBoolFlag("new_checkout", default: false), false)
        XCTAssertTrue(m.getAllFlags().isEmpty)
        await m.refreshFlags()
        XCTAssertEqual(server.calls("/v1/flags/evaluate").count, 1, "nothing is sent without consent")
    }

    func testTheCacheIsKeptOnDiskForTheSamePersonOnly() async {
        let (_, server, state) = await ready()
        XCTAssertNotNil(state.stored)
        // The next launch: readable at once, before any answer.
        let again = manager(server, state)
        XCTAssertEqual(again.getStringFlag("headline", default: "x"), "Hello")
        // Another person on the same device: never their answer.
        state.anonymousId = "someone-else"
        let other = manager(server, state)
        XCTAssertEqual(other.getStringFlag("headline", default: "x"), "x")
    }

    func testAnAnswerForAPreviousPersonIsDiscardedAndTheNewPersonIsFetched() async {
        let server = FakeServer()
        server.answer = Self.answer
        server.delay = 0.3
        let state = State()
        let m = manager(server, state)
        let first = Task { await m.refreshFlags() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        state.userId = "user-b"
        m.onIdentityChanged()
        await first.value
        waitUntil(timeout: 3) { server.calls("/v1/flags/evaluate").count == 2 }
        waitUntil(timeout: 3) { m.getStringFlag("headline", default: "x") == "Hello" }
        XCTAssertEqual(server.calls("/v1/flags/evaluate")[1]["userId"] as? String, "user-b")
    }

    func testOnFlagsUpdatedGetsTheChangedKeysAndCancelStops() async {
        let server = FakeServer()
        let state = State()
        let m = manager(server, state)
        server.answer = Self.answer
        let lock = NSLock()
        var received: [[String]] = []
        let sub: JoryioSubscription = m.onFlagsUpdated { keys in lock.lock(); received.append(keys); lock.unlock() }
        waitUntil(timeout: 2) { lock.lock(); defer { lock.unlock() }; return received.count == 1 }
        lock.lock(); XCTAssertEqual(received.first?.count, 5); lock.unlock()
        var next = Self.answer
        var flags = next["flags"] as! [String: Any]
        flags["headline"] = Self.flag("Bye", "string", variant: "c")
        next["flags"] = flags
        next["etag"] = "e2"
        server.answer = next
        await m.refreshFlags()
        waitUntil(timeout: 2) { lock.lock(); defer { lock.unlock() }; return received.count == 2 }
        lock.lock(); XCTAssertEqual(received.last, ["headline"]); lock.unlock()
        sub.cancel()
        server.answer = Self.answer
        await m.refreshFlags()
        Thread.sleep(forTimeInterval: 0.2)
        lock.lock(); XCTAssertEqual(received.count, 2); lock.unlock()
    }

    // MARK: - Exposure marks kept for the session (BACKLOG D479)

    /// A relaunch: a new FlagsManager over the same store, the session resumed.
    private func relaunch(_ server: FakeServer, _ state: State) async -> FlagsManager {
        let m = manager(server, state)
        await m.refreshFlags()
        return m
    }

    func testARelaunchInTheSameSessionSendsNoDuplicateExposure() async {
        let (m, server, state) = await ready()
        _ = m.getBoolFlag("new_checkout", default: false)
        waitUntil(timeout: 2) { server.calls("/v1/flags/exposures").count == 1 && state.storedExposures != nil }
        XCTAssertNotNil(state.storedExposures)
        let m2 = await relaunch(server, state)
        _ = m2.getBoolFlag("new_checkout", default: false)
        _ = m2.getStringFlag("headline", default: "")
        waitUntil(timeout: 2) { server.calls("/v1/flags/exposures").count == 2 }
        Thread.sleep(forTimeInterval: 0.2)
        let second = server.calls("/v1/flags/exposures")[1]["exposures"] as? [[String: String]] ?? []
        XCTAssertEqual(second.map { $0["key"]! }, ["headline"], "new_checkout was already sent this session")
        XCTAssertEqual(server.calls("/v1/flags/exposures").count, 2)
        _ = m
    }

    func testAMarkIsStoredOnlyOnceItsBatchIsSentSoAKilledAppSendsItAfterTheRelaunch() async {
        let server = FakeServer()
        server.answer = Self.answer
        let state = State()
        let m = FlagsManager(FlagsManager.Dependencies(
            post: { await server.post($0, $1) },
            canSend: { state.canSend },
            userId: { state.userId },
            anonymousId: { state.anonymousId },
            sessionId: { state.sessionId },
            attributes: { [:] },
            context: { [:] },
            load: { state.stored },
            save: { state.stored = $0 },
            callbackQueue: DispatchQueue.global(),
            now: { state.now },
            exposureFlushDelay: 60, // the app is killed before the batch goes
            loadExposures: { state.storedExposures },
            saveExposures: { state.storedExposures = $0 }
        ))
        await m.refreshFlags()
        _ = m.getBoolFlag("new_checkout", default: false)
        _ = m.getBoolFlag("new_checkout", default: false) // no duplicate within the process
        XCTAssertNil(state.storedExposures, "not stored before the batch is sent")
        let m2 = await relaunch(server, state)
        _ = m2.getBoolFlag("new_checkout", default: false)
        waitUntil(timeout: 2) { server.calls("/v1/flags/exposures").count == 1 }
        let sent = server.calls("/v1/flags/exposures")[0]["exposures"] as? [[String: String]] ?? []
        XCTAssertEqual(sent.map { $0["key"]! }, ["new_checkout"], "the exposure the killed app never sent goes after the relaunch")
        XCTAssertTrue(state.storedExposures?.contains("|new_checkout|on") ?? false)
        _ = m
    }

    func testARelaunchInANewSessionSendsAgainAndDropsTheOldMarks() async {
        let (m, server, state) = await ready()
        _ = m.getBoolFlag("new_checkout", default: false)
        waitUntil(timeout: 2) { server.calls("/v1/flags/exposures").count == 1 }
        state.sessionId = "s-2"
        let m2 = await relaunch(server, state)
        _ = m2.getBoolFlag("new_checkout", default: false)
        waitUntil(timeout: 2) { state.storedExposures?.contains("s-2|") ?? false }
        XCTAssertFalse(state.storedExposures?.contains("s-1|") ?? true, "only the current session's marks are kept")
        XCTAssertTrue(state.storedExposures?.contains("s-2|") ?? false)
        _ = m
    }

    func testResetAndAUserSwitchClearTheMarksButSignInDoesNot() async {
        let (m, server, state) = await ready()
        _ = m.getBoolFlag("new_checkout", default: false)
        waitUntil(timeout: 2) { server.calls("/v1/flags/exposures").count == 1 && state.storedExposures != nil }
        // Anonymous -> signed in: the marks stay (the beta.11 rule clears only on a different user).
        m.onIdentityChanged(clearExposureMarks: false)
        XCTAssertNotNil(state.storedExposures)
        // A different user (or reset()): cleared on disk and in memory.
        m.onIdentityChanged(clearExposureMarks: true)
        XCTAssertNil(state.storedExposures)
        await m.refreshFlags()
        _ = m.getBoolFlag("new_checkout", default: false)
        waitUntil(timeout: 2) { server.calls("/v1/flags/exposures").count == 2 }
        // wipeData() clears them too.
        m.wipe()
        XCTAssertNil(state.storedExposures)
    }

    func testTheStoredMarksAreCappedOldestFirst() async {
        XCTAssertEqual(JoryioFlags.FLAG_EXPOSURE_MARKS_MAX, 500)
        let server = FakeServer()
        var flags: [String: Any] = [:]
        for i in 0..<(JoryioFlags.FLAG_EXPOSURE_MARKS_MAX + 5) { flags["f\(i)"] = Self.flag(true, "boolean") }
        server.answer = ["etag": "e", "ttlSeconds": 300, "flags": flags]
        let state = State()
        let m = manager(server, state)
        await m.refreshFlags()
        for i in 0..<(JoryioFlags.FLAG_EXPOSURE_MARKS_MAX + 5) { _ = m.getBoolFlag("f\(i)", default: false) }
        m.flush()
        let obj = (try? JSONSerialization.jsonObject(with: Data((state.storedExposures ?? "").utf8))) as? [String: Any]
        let marks = obj?["marks"] as? [String] ?? []
        XCTAssertEqual(obj?["sessionId"] as? String, "s-1")
        XCTAssertEqual(marks.count, JoryioFlags.FLAG_EXPOSURE_MARKS_MAX)
        XCTAssertFalse(marks.contains("s-1|anon-1|f0|on") || marks.contains("s-1||anon-1|f0|on"), "the oldest went first")
        XCTAssertTrue(marks.contains { $0.hasSuffix("|f504|on") })
    }

    func testWipeForgetsTheAnswerOnDisk() async {
        let (m, server, state) = await ready()
        server.delay = 1 // the refetch the next read starts is still on the wire
        m.wipe()
        XCTAssertNil(state.stored)
        XCTAssertEqual(m.getStringFlag("headline", default: "x"), "x")
    }

    // MARK: - Through the SDK (stub transport)

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func answerFlags() {
        let data = try! JSONSerialization.data(withJSONObject: Self.answer)
        StubURLProtocol.responder = { req in
            req.url!.path.hasSuffix("/v1/flags/evaluate") ? (200, data) : (200, Data("{\"success\":true}".utf8))
        }
    }

    func testTheSdkFetchesWithTheSdkKeyAndRefetchesOnIdentify() async {
        answerFlags()
        let sdk = TestSupport.sdk()
        XCTAssertEqual(sdk.getBoolFlag("new_checkout", default: false), false, "before the first answer")
        await sdk.refreshFlags()
        XCTAssertEqual(sdk.getBoolFlag("new_checkout", default: false), true)
        let first = TestSupport.requests("/v1/flags/evaluate")
        XCTAssertEqual(first.first?.headers["X-App-Key"], "jry_sdk_ios_test")
        XCTAssertEqual(first.first?.json?["anonymousId"] as? String, sdk.getAnonymousId())
        sdk.identify("user-42")
        waitUntil(timeout: 5) { TestSupport.requests("/v1/flags/evaluate").contains { $0.json?["userId"] as? String == "user-42" } }
        waitUntil(timeout: 5) { TestSupport.requests("/v1/flags/exposures").count == 1 }
        XCTAssertNil(TestSupport.requests("/v1/flags/exposures")[0].json?["userId"], "read before identify: sent as the anonymous visitor")
    }

    func testWithoutConsentTheSdkSendsNothingAndReturnsTheDefault() async {
        answerFlags()
        let sdk = TestSupport.sdk(config: TestSupport.sdkConfig(trackingConsent: .pending))
        XCTAssertEqual(sdk.getStringFlag("headline", default: "d"), "d")
        await sdk.refreshFlags()
        XCTAssertEqual(sdk.getStringFlag("headline", default: "d"), "d")
        XCTAssertTrue(TestSupport.requests("/v1/flags/evaluate").isEmpty)
        sdk.updateConsent(.granted)
        waitUntil(timeout: 5) { sdk.getStringFlag("headline", default: "d") == "Hello" }
        sdk.updateConsent(.denied)
        XCTAssertEqual(sdk.getStringFlag("headline", default: "d"), "d")
    }

    func testTheSilentPushValueIsPinned() {
        XCTAssertEqual(JoryioFlags.FLAG_SYNC_PUSH_VALUE, "flags")
        XCTAssertEqual(JoryioFlags.FLAGS_MIN_REFRESH_SECONDS, 60)
    }
}
