import XCTest
@testable import Joryio

/// resetTo(anonymousId) (BACKLOG D366): reset(), then the caller's anonymous
/// id instead of a random one. Same rule on all five SDKs.
final class ResetToTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    func testTheRuleAcceptsTrackerIdsAndRefusesBadShapesProfileIdsAndUserIds() {
        XCTAssertNil(ResetTo.refusal("0b9c6c1e-6f43-4f7a-9d2a-6f0b2c4d5e6f", knownUserIds: []))
        XCTAssertNil(ResetTo.refusal("jry_0b9c6c1e-6f43-4f7a-9d2a-6f0b2c4d5e6f", knownUserIds: []))
        XCTAssertNil(ResetTo.refusal(String(repeating: "a", count: 255), knownUserIds: []))
        XCTAssertNotNil(ResetTo.refusal("short", knownUserIds: []))
        XCTAssertNotNil(ResetTo.refusal(String(repeating: "a", count: 256), knownUserIds: []))
        XCTAssertNotNil(ResetTo.refusal("ada@example.com", knownUserIds: []))
        XCTAssertNotNil(ResetTo.refusal(nil, knownUserIds: []))
        XCTAssertNotNil(ResetTo.refusal("65f1a2b3c4d5e6f708192a3b", knownUserIds: []))
        XCTAssertNotNil(ResetTo.refusal("customer-1042", knownUserIds: [nil, "customer-1042"]))
        // The anonymous id held while a user is signed in.
        XCTAssertNotNil(ResetTo.refusal("jry_alice-device-0001", knownUserIds: ["alice"], signedInAnonymousId: "jry_alice-device-0001"))
        XCTAssertNil(ResetTo.refusal("jry_alice-device-0001", knownUserIds: [nil], signedInAnonymousId: nil))
    }

    func testResetToLogsOutAndAdoptsTheIdSynchronously() {
        let sdk = TestSupport.sdk()
        sdk.identify("user-a")
        var adopted: Bool?
        sdk.resetTo("jry_tracker-visitor-0001") { adopted = $0 }
        XCTAssertEqual(adopted, true)
        XCTAssertNil(sdk.getUserId())
        XCTAssertEqual(sdk.getAnonymousId(), "jry_tracker-visitor-0001")
    }

    func testAnAdoptedIdIsPersisted() {
        let storage = TestSupport.storage()
        let sdk = TestSupport.sdk(storage: storage)
        sdk.resetTo("hp_abcdef0123456789")
        XCTAssertEqual(storage.getAnonymousId(), "hp_abcdef0123456789")
    }

    func testARefusedIdIsAPlainReset() {
        let sdk = TestSupport.sdk()
        sdk.identify("customer-1042")
        let before = sdk.getAnonymousId()
        var adopted: Bool?
        sdk.resetTo("customer-1042") { adopted = $0 }
        XCTAssertEqual(adopted, false)
        XCTAssertNil(sdk.getUserId())
        XCTAssertNotEqual(sdk.getAnonymousId(), "customer-1042")
        XCTAssertNotEqual(sdk.getAnonymousId(), before)
    }

    func testTheAnonymousIdTheSignedInUserHadIsRefused() {
        // Shared device: the next person must not inherit the signed-in user's profile.
        let sdk = TestSupport.sdk()
        sdk.resetTo("jry_alice-device-0001")
        sdk.identify("alice")
        var adopted: Bool?
        sdk.resetTo("jry_alice-device-0001") { adopted = $0 }
        XCTAssertEqual(adopted, false)
        XCTAssertNil(sdk.getUserId())
        XCTAssertNotEqual(sdk.getAnonymousId(), "jry_alice-device-0001")
    }

    func testAnAnonymousIdASignedInUserHeldBeforeAnEarlierResetIsRefused() {
        let sdk = TestSupport.sdk()
        sdk.resetTo("jry_alice-device-0001")
        sdk.identify("alice")
        sdk.reset()
        var adopted: Bool?
        sdk.resetTo("jry_alice-device-0001") { adopted = $0 }
        XCTAssertEqual(adopted, false)
        XCTAssertNotEqual(sdk.getAnonymousId(), "jry_alice-device-0001")
    }

    func testTheRememberedListKeepsTheNewest20AndWipeDataForgetsIt() {
        var list: [String] = []
        for i in 1...25 { list = ResetTo.remember(list, String(format: "jry_device-%04d", i)) }
        XCTAssertEqual(list.count, ResetTo.signedInAnonymousIdsMax)
        XCTAssertEqual(ResetTo.signedInAnonymousIdsMax, 20)
        XCTAssertEqual(list.first, "jry_device-0006")
        XCTAssertEqual(list.last, "jry_device-0025")
        XCTAssertEqual(ResetTo.remember(["jry_device-b", "jry_device-a"], "jry_device-b"), ["jry_device-a", "jry_device-b"])

        let sdk = TestSupport.sdk()
        sdk.resetTo("jry_alice-device-0002")
        sdk.identify("alice")
        sdk.reset()
        sdk.wipeData()
        var adopted: Bool?
        sdk.resetTo("jry_alice-device-0002") { adopted = $0 }
        XCTAssertEqual(adopted, true)
    }

    func testAHeldResetToDiscardedBeforeInitializeAnswersFalseOnce() {
        let sdk = TestSupport.sdk(initialize: false)
        var answers: [Bool] = []
        sdk.resetTo("hp_abcdef0123456789") { answers.append($0) }
        // A full buffer of calls that are not data pushes the oldest out.
        for _ in 0..<Joryio.maxPreInitCalls { sdk.reset() }
        XCTAssertEqual(answers, [false])
        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: TestSupport.sdkConfig()) // gitleaks:allow - fake test key, the .test host
        XCTAssertEqual(answers, [false], "answered once, never again")
    }

    func testAHeldResetToAnswersWhenItRuns() {
        let sdk = TestSupport.sdk(initialize: false)
        var answers: [Bool] = []
        sdk.resetTo("hp_abcdef0123456789") { answers.append($0) }
        XCTAssertEqual(answers, [])
        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: TestSupport.sdkConfig()) // gitleaks:allow - fake test key, the .test host
        XCTAssertEqual(answers, [true])
    }
}
