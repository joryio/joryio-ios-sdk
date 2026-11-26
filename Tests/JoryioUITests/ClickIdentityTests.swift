import XCTest
@testable import Joryio

/// Click-link identity: a tracked message link opens the app with `jr_t`, and
/// identifyFromLink sends it with the anonymous id to POST /v1/identify-link -
/// once, only while tracking is allowed and nobody is identified.
final class ClickIdentityTests: XCTestCase {

    private let token = "AbCdEfGhIjKlMnOp_qrstuv-0123456789" // gitleaks:allow - a fake jr_t test token
    private var link: URL { URL(string: "https://shop.example.com/sale?utm_source=joryio&jr_cid=c1&jr_t=\(token)#top")! }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func linkRequests() -> [StubURLProtocol.Captured] {
        TestSupport.requests("/v1/identify-link")
    }

    /// Long enough for a request that should NOT be made to have been made.
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    func testTheTokenIsReadFromTheQueryOnlyWhenWellFormed() {
        XCTAssertEqual(ClickIdentity.token(from: link), token)
        XCTAssertEqual(ClickIdentity.token(from: URL(string: "myapp://open?jr_t=\(token)")), token)
        XCTAssertNil(ClickIdentity.token(from: URL(string: "https://shop.example.com/sale?jr_cid=c1")))
        XCTAssertNil(ClickIdentity.token(from: URL(string: "https://shop.example.com/sale#jr_t=\(token)")))
        XCTAssertNil(ClickIdentity.token(from: URL(string: "https://x.example/?jr_t=short")), "too short")
        XCTAssertNil(ClickIdentity.token(from: URL(string: "https://x.example/?jr_t=abcdefghijklmnop%2Fq")), "bad characters")
        XCTAssertNil(ClickIdentity.token(from: nil))
    }

    func testSendsExactlyTokenAndAnonymousIdOncePerToken() {
        let sdk = TestSupport.sdk()
        sdk.identifyFromLink(link)
        sdk.identifyFromLink(link)
        waitUntil { !self.linkRequests().isEmpty }
        settle()
        XCTAssertEqual(linkRequests().count, 1)
        let json = linkRequests()[0].json ?? [:]
        XCTAssertEqual(Set(json.keys), ["token", "anonymousId"])
        XCTAssertEqual(json["token"] as? String, token)
        XCTAssertEqual(json["anonymousId"] as? String, sdk.getAnonymousId())
        XCTAssertEqual(linkRequests()[0].method, "POST")
    }

    func testAUrlWithoutTheTokenSendsNothing() {
        let sdk = TestSupport.sdk()
        sdk.identifyFromLink(URL(string: "https://shop.example.com/sale?jr_cid=c1")!)
        settle()
        XCTAssertTrue(linkRequests().isEmpty)
    }

    func testAnIdentifiedUserIsNeverReattachedByALink() {
        let sdk = TestSupport.sdk()
        sdk.identify("user-1")
        sdk.identifyFromLink(link)
        settle()
        XCTAssertTrue(linkRequests().isEmpty)
    }

    func testOptedOutOrDeniedDropsTheToken() {
        let sdk = TestSupport.sdk()
        sdk.optOut()
        sdk.identifyFromLink(link)
        sdk.optIn()
        settle()
        XCTAssertTrue(linkRequests().isEmpty)

        sdk.updateConsent(.denied)
        sdk.identifyFromLink(link)
        sdk.updateConsent(.granted)
        settle()
        XCTAssertTrue(linkRequests().isEmpty)
    }

    func testConsentPendingHoldsInMemoryAndSendsOnGrant() {
        let sdk = TestSupport.sdk(config: TestSupport.sdkConfig(trackingConsent: .pending))
        sdk.identifyFromLink(link)
        settle()
        XCTAssertTrue(linkRequests().isEmpty)
        sdk.updateConsent(.granted)
        waitUntil { self.linkRequests().count == 1 }
    }

    func testConsentPendingThenDeniedDropsTheHeldToken() {
        let sdk = TestSupport.sdk(config: TestSupport.sdkConfig(trackingConsent: .pending))
        sdk.identifyFromLink(link)
        sdk.updateConsent(.denied)
        sdk.updateConsent(.granted)
        settle()
        XCTAssertTrue(linkRequests().isEmpty)
    }

    func testBeforeInitializeHeldAndHandledAtInit() {
        let sdk = TestSupport.sdk(initialize: false)
        sdk.identifyFromLink(link)
        settle()
        XCTAssertTrue(linkRequests().isEmpty)
        sdk.initialize(sdkKey: "jry_sdk_ios_test", apiHost: "api-eu1.joryio.test", config: TestSupport.sdkConfig()) // gitleaks:allow - test host
        waitUntil { self.linkRequests().count == 1 }
    }

    func testA4xxIsNotRetried() {
        StubURLProtocol.responder = { request in
            request.url?.path.hasSuffix("/v1/identify-link") == true
                ? (400, Data("{\"success\":false}".utf8))
                : (200, Data("{\"success\":true}".utf8))
        }
        let config = JoryioConfig(flushInterval: 3600, trackSessionStart: false, inApp: InAppConfig(enabled: false), maxRetries: 3)
        let sdk = TestSupport.sdk(config: config)
        sdk.identifyFromLink(link)
        waitUntil { !self.linkRequests().isEmpty }
        settle()
        XCTAssertEqual(linkRequests().count, 1)
    }
}
