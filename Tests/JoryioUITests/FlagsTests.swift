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

        /// What the next exposures requests answer: an HTTP status, or 0 for no answer. Then 200.
        var exposureAnswers: [Int] = []
        /// The request whose first exposure is this flag answers 503 once.
        var failOnceStartingAt: String?

        func postExposures(_ body: Data) async -> FlagsPostStatus {
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            lock.lock()
            _calls.append(("/v1/flags/exposures", json))
            let first = (json["exposures"] as? [[String: Any]])?.first?["key"] as? String
            var status = exposureAnswers.isEmpty ? 200 : exposureAnswers.removeFirst()
            if let first, first == failOnceStartingAt { failOnceStartingAt = nil; status = 503 }
            let d = delay
            lock.unlock()
            if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000)) }
            return FlagsPostStatus(status: status)
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
        /// The fake write outbox: the bodies handed to it.
        private let lock = NSLock()
        private var _outbox: [String] = []
        var outboxBodies: [String] { lock.lock(); defer { lock.unlock() }; return _outbox }
        func addToOutbox(_ body: String) { lock.lock(); _outbox.append(body); lock.unlock() }
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
            saveExposures: { state.storedExposures = $0 },
            postExposures: { await server.postExposures($0) },
            enqueueExposures: { state.addToOutbox($0) },
            pendingExposures: { state.outboxBodies }
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
        // Stored once the server took each request of at most 100 (1.4.0-beta.13), not when it went.
        waitUntil(timeout: 3) { self.storedMarks(state).count == JoryioFlags.FLAG_EXPOSURE_MARKS_MAX && self.storedMarks(state).contains { $0.hasSuffix("|f504|on") } }
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

    // MARK: - 1.4.0-beta.13: a mark is "sent" only once the server took its batch;
    // one it did not take goes to the write outbox (here a fake one)

    private func storedMarks(_ state: State) -> [String] {
        guard let raw = state.storedExposures, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return obj["marks"] as? [String] ?? []
    }

    private func json(_ body: String) -> NSDictionary {
        ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? NSDictionary) ?? [:]
    }

    func testTheRuleTwoHundredsAndPermanentFourHundredsSettleABatch() {
        for status in [200, 202, 400, 401, 403, 404, 413, 422] { XCTAssertTrue(exposureBatchSettled(status), "\(status)") }
        for status in [0, 408, 429, 500, 502, 503] { XCTAssertFalse(exposureBatchSettled(status), "\(status)") }
    }

    private func assertFailedGoesToTheOutbox(_ failure: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let (m, server, state) = await ready()
        server.exposureAnswers = [failure]
        _ = m.getBoolFlag("new_checkout", default: false)
        waitUntil(timeout: 2) { state.outboxBodies.count == 1 }
        let sent = server.calls("/v1/flags/exposures")
        XCTAssertEqual(sent.count, 1, file: file, line: line)
        XCTAssertEqual(json(state.outboxBodies[0]), sent[0] as NSDictionary, "the same body and key", file: file, line: line)
        XCTAssertTrue(storedMarks(state).isEmpty, "not marked before the server took it", file: file, line: line)
        // A read meanwhile, and a relaunch with it still waiting: no second copy.
        _ = m.getBoolFlag("new_checkout", default: false)
        let again = await relaunch(server, state)
        _ = again.getBoolFlag("new_checkout", default: false)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(server.calls("/v1/flags/exposures").count, 1, file: file, line: line)
        XCTAssertEqual(state.outboxBodies.count, 1, file: file, line: line)
        // The outbox delivered it.
        again.exposuresSettled(state.outboxBodies[0])
        XCTAssertEqual(storedMarks(state), ["s-1||anon-1|new_checkout|on"], file: file, line: line)
    }

    func testAfterANetworkErrorTheBatchGoesToTheOutboxCountsAsExposedAndIsMarkedWhenSettled() async {
        await assertFailedGoesToTheOutbox(0)
    }

    func testAfterA503TheBatchGoesToTheOutboxCountsAsExposedAndIsMarkedWhenSettled() async {
        await assertFailedGoesToTheOutbox(503)
    }

    func testAfterA429TheBatchGoesToTheOutboxCountsAsExposedAndIsMarkedWhenSettled() async {
        await assertFailedGoesToTheOutbox(429)
    }

    func testA2xxMarksTheBatchAndNothingGoesToTheOutbox() async {
        let (m, server, state) = await ready()
        _ = m.getBoolFlag("new_checkout", default: false)
        waitUntil(timeout: 2) { state.storedExposures != nil }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(server.calls("/v1/flags/exposures").count, 1)
        XCTAssertTrue(state.outboxBodies.isEmpty)
        XCTAssertEqual(storedMarks(state), ["s-1||anon-1|new_checkout|on"])
    }

    func testAPermanent4xxMarksTheBatchAndNothingGoesToTheOutbox() async {
        let (m, server, state) = await ready()
        server.exposureAnswers = [400]
        _ = m.getBoolFlag("new_checkout", default: false)
        waitUntil(timeout: 2) { state.storedExposures != nil }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(server.calls("/v1/flags/exposures").count, 1)
        XCTAssertTrue(state.outboxBodies.isEmpty)
    }

    func test150ExposuresGoAsTwoRequestsAndAFailedSecondOneAloneGoesToTheOutbox() async {
        let server = FakeServer()
        var flags: [String: Any] = [:]
        for i in 0..<150 { flags["f\(i)"] = Self.flag(true, "boolean") }
        server.answer = ["etag": "m", "ttlSeconds": 300, "flags": flags]
        server.failOnceStartingAt = "f100"
        let state = State()
        let m = manager(server, state)
        await m.refreshFlags()
        for i in 0..<150 { _ = m.getBoolFlag("f\(i)", default: false) }
        waitUntil(timeout: 3) { server.calls("/v1/flags/exposures").count == 2 && state.outboxBodies.count == 1 && self.storedMarks(state).count == 100 }
        let sent = server.calls("/v1/flags/exposures")
        XCTAssertEqual(sent.map { ($0["exposures"] as? [Any])?.count ?? 0 }, [100, 50])
        XCTAssertNotEqual(sent[0]["idempotencyKey"] as? String, sent[1]["idempotencyKey"] as? String)
        let keys = sent.flatMap { ($0["exposures"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String } }
        XCTAssertEqual(keys, (0..<150).map { "f\($0)" })
        XCTAssertEqual(json(state.outboxBodies[0]), sent[1] as NSDictionary)
        m.exposuresSettled(state.outboxBodies[0])
        XCTAssertEqual(storedMarks(state).count, 150)
    }

    func testWipeAQueuedBatchIsNeverSentAndOneFailingAfterItIsNotHandedToTheOutbox() async {
        let (m, server, state) = await ready()
        _ = m.getBoolFlag("new_checkout", default: false)
        m.wipe() // wipeData()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(server.calls("/v1/flags/exposures").count, 0)
        let again = manager(server, state)
        await again.refreshFlags()
        server.delay = 0.2
        server.exposureAnswers = [503]
        _ = again.getStringFlag("headline", default: "")
        waitUntil(timeout: 2) { server.calls("/v1/flags/exposures").count == 1 }
        again.wipe()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(state.outboxBodies.isEmpty)
        XCTAssertNil(state.storedExposures)
    }

    func testAFailedBatchIsNotHandedToTheOutboxOnceSendingStopped() async {
        let (m, server, state) = await ready()
        server.delay = 0.2
        server.exposureAnswers = [503]
        _ = m.getBoolFlag("new_checkout", default: false)
        waitUntil(timeout: 2) { server.calls("/v1/flags/exposures").count == 1 }
        state.canSend = false // opted out while it was on the wire
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(state.outboxBodies.isEmpty)
    }

    // MARK: through the SDK's real write outbox

    private var exposuresFail = true
    private let failLock = NSLock()

    private func answerFlagsFailingExposures() {
        exposuresFail = true
        let data = try! JSONSerialization.data(withJSONObject: Self.answer)
        StubURLProtocol.responder = { [unowned self] req in
            if req.url!.path.hasSuffix("/v1/flags/evaluate") { return (200, data) }
            if req.url!.path.hasSuffix("/v1/flags/exposures") {
                self.failLock.lock(); defer { self.failLock.unlock() }
                return self.exposuresFail ? (503, Data("{}".utf8)) : (200, Data("{\"success\":true}".utf8))
            }
            return (200, Data("{\"success\":true}".utf8))
        }
    }

    private func setExposuresFail(_ value: Bool) {
        failLock.lock(); exposuresFail = value; failLock.unlock()
    }

    /// Where exposure batches wait: their own key, never inside `write_outbox`.
    private func outboxOnDisk(_ storage: StorageManager) -> String {
        XCTAssertFalse((storage.getValue(forKey: Joryio.outboxStorageKey) ?? "").contains("flagExposures"), "never in the write outbox")
        return storage.getValue(forKey: Joryio.flagExposuresOutboxStorageKey) ?? ""
    }

    func testAFailedSendSurvivesARelaunchAndTheOutboxSendsItOnceWithTheSameKey() async {
        answerFlagsFailingExposures()
        let key = TestSupport.uniqueKey()
        let defaults = TestSupport.defaults()
        let dir = TestSupport.tempDirectory()
        func launch() -> (Joryio, StorageManager) {
            let storage = TestSupport.storage(sdkKey: key, defaults: defaults, directory: dir)
            return (TestSupport.sdk(storage: storage, defaults: defaults), storage)
        }
        var (first, storage1): (Joryio?, StorageManager) = launch()
        await first?.refreshFlags()
        _ = first?.getBoolFlag("new_checkout", default: false)
        waitUntil(timeout: 3) { self.outboxOnDisk(storage1).contains("flagExposures") }
        let idempotencyKey = TestSupport.requests("/v1/flags/exposures").first?.json?["idempotencyKey"] as? String
        XCTAssertNotNil(idempotencyKey)
        first = nil // the app is killed before the outbox got it through

        // Relaunch, still failing: reading the flag again adds no copy.
        var (second, _): (Joryio?, StorageManager) = launch()
        await second?.refreshFlags()
        _ = second?.getBoolFlag("new_checkout", default: false)
        Thread.sleep(forTimeInterval: 1.5)
        second = nil

        // Relaunch, the server back: the outbox sends it, once, with its key.
        setExposuresFail(false)
        let (third, storage3) = launch()
        waitUntil(timeout: 3) { !self.outboxOnDisk(storage3).contains("flagExposures") }
        let keys = Set(TestSupport.requests("/v1/flags/exposures").compactMap { $0.json?["idempotencyKey"] as? String })
        XCTAssertEqual(keys, [idempotencyKey!], "one batch, one key")
        let sent = TestSupport.requests("/v1/flags/exposures").count
        await third.refreshFlags()
        _ = third.getBoolFlag("new_checkout", default: false)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(TestSupport.requests("/v1/flags/exposures").count, sent,
                       "marked once the outbox got it through")
    }

    /// An SDK before 1.4.0-beta.13 decodes `write_outbox` as one list of its
    /// own entry kinds: a kind it does not know fails the WHOLE list, which it
    /// then discards. Exposure batches therefore wait under their own key; the
    /// write outbox stays decodable by the 1.3.x entry shape.
    private struct EntryBefore140: Decodable {
        enum Kind: String, Decodable { case identify, alias, subscription, optOutMarker, pushUnregister, attributes }
        let id: String
        let kind: Kind
        let path: String
        let body: String
    }

    func testTheWriteOutboxStaysReadableByAnOlderSdkWhileAnExposureBatchWaits() async {
        let data = try! JSONSerialization.data(withJSONObject: Self.answer)
        StubURLProtocol.responder = { req in
            let path = req.url!.path
            if path.hasSuffix("/v1/flags/evaluate") { return (200, data) }
            // The identify and the exposures both wait in their outboxes.
            if path.hasSuffix("/v1/flags/exposures") || path.hasSuffix("/v1/identify") { return (503, Data("{}".utf8)) }
            return (200, Data("{\"success\":true}".utf8))
        }
        let storage = TestSupport.storage()
        let sdk = TestSupport.sdk(storage: storage)
        await sdk.refreshFlags()
        _ = sdk.getBoolFlag("new_checkout", default: false)
        sdk.identify("user-1")
        waitUntil(timeout: 3) {
            (storage.getValue(forKey: Joryio.flagExposuresOutboxStorageKey) ?? "").contains("flagExposures")
                && (storage.getValue(forKey: Joryio.outboxStorageKey) ?? "").contains("identify")
        }
        let writes = storage.getValue(forKey: Joryio.outboxStorageKey) ?? ""
        let decoded = try? JSONDecoder().decode([EntryBefore140].self, from: Data(writes.utf8))
        XCTAssertNotNil(decoded, "an SDK before 1.4.0-beta.13 decodes the write outbox: \(writes.prefix(300))")
        XCTAssertEqual(decoded?.map(\.kind), [.identify])
        _ = sdk
    }

    func testAfterWipeDataAFailedBatchIsNeverSentAndNothingIsLeftOnDisk() async {
        answerFlagsFailingExposures()
        let storage = TestSupport.storage()
        let sdk = TestSupport.sdk(storage: storage)
        await sdk.refreshFlags()
        _ = sdk.getBoolFlag("new_checkout", default: false)
        waitUntil(timeout: 3) { self.outboxOnDisk(storage).contains("flagExposures") && TestSupport.requests("/v1/flags/exposures").count >= 2 }
        Thread.sleep(forTimeInterval: 0.3)
        let before = TestSupport.requests("/v1/flags/exposures").count
        sdk.wipeData()
        XCTAssertFalse(outboxOnDisk(storage).contains("flagExposures"))
        setExposuresFail(false)
        sdk.flush()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(TestSupport.requests("/v1/flags/exposures").count, before)
    }

    func testOptOutPurgesItFromTheOutboxAndAnOptInLaterDoesNotSendIt() async {
        answerFlagsFailingExposures()
        let storage = TestSupport.storage()
        let sdk = TestSupport.sdk(storage: storage)
        await sdk.refreshFlags()
        _ = sdk.getBoolFlag("new_checkout", default: false)
        waitUntil(timeout: 3) { self.outboxOnDisk(storage).contains("flagExposures") && TestSupport.requests("/v1/flags/exposures").count >= 2 }
        Thread.sleep(forTimeInterval: 0.3)
        let before = TestSupport.requests("/v1/flags/exposures").count
        sdk.optOut()
        XCTAssertFalse(outboxOnDisk(storage).contains("flagExposures"))
        sdk.optIn()
        setExposuresFail(false)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(TestSupport.requests("/v1/flags/exposures").count, before)
    }

    func testTheSilentPushValueIsPinned() {
        XCTAssertEqual(JoryioFlags.FLAG_SYNC_PUSH_VALUE, "flags")
        XCTAssertEqual(JoryioFlags.FLAGS_MIN_REFRESH_SECONDS, 60)
    }
}
