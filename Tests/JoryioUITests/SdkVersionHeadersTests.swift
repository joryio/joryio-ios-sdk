import XCTest
@testable import Joryio

/// D427: every request names the SDK and its version, so Settings > Apps can
/// show which version an app runs. Same wire names on all five SDKs (the
/// backend's sdk-version-parity spec greps them).
final class SdkVersionHeadersTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        SdkIdentity.resetForTesting()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        SdkIdentity.resetForTesting()
        super.tearDown()
    }

    func testEveryRequestCarriesPlatformAndVersion() {
        let sdk = TestSupport.sdk()
        sdk.track("Viewed")
        sdk.flush()
        waitUntil { !TestSupport.requests("/v1/track/batch").isEmpty }
        XCTAssertFalse(StubURLProtocol.requests.isEmpty)
        for req in StubURLProtocol.requests {
            XCTAssertEqual(req.headers["X-Joryio-SDK"], "ios")
            XCTAssertEqual(req.headers["X-Joryio-SDK-Version"], SDK_VERSION)
            XCTAssertNil(req.headers["X-Joryio-SDK-Wrapper"])
        }
    }

    func testABridgeNamesItself() {
        XCTAssertTrue(Joryio.setSdkWrapper(name: "unity", version: "1.3.3"))
        XCTAssertFalse(Joryio.setSdkWrapper(name: "react native", version: "1.3.3"))
        XCTAssertFalse(Joryio.setSdkWrapper(name: "unity", version: "1.3.3\r\nX-Evil: 1"))
        let sdk = TestSupport.sdk()
        sdk.track("Viewed")
        sdk.flush()
        waitUntil { !TestSupport.requests("/v1/track/batch").isEmpty }
        for req in StubURLProtocol.requests {
            XCTAssertEqual(req.headers["X-Joryio-SDK"], "ios")
            XCTAssertEqual(req.headers["X-Joryio-SDK-Version"], SDK_VERSION)
            XCTAssertEqual(req.headers["X-Joryio-SDK-Wrapper"], "unity")
            XCTAssertEqual(req.headers["X-Joryio-SDK-Wrapper-Version"], "1.3.3")
        }
    }
}
