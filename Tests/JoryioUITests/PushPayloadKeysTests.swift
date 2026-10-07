import XCTest
@testable import Joryio

/// The push data contract on iOS. The backend's push-payload.contract.ts is
/// the source; a rename there must fail here as well as in its parity spec.
final class PushPayloadKeysTests: XCTestCase {

    func testKeysMatchTheBackendContract() {
        XCTAssertEqual(PushPayloadKeys.marker, "joryio")
        XCTAssertEqual(PushPayloadKeys.markerValue, "true")
        XCTAssertEqual(PushPayloadKeys.trackingId, "trackingId")
        XCTAssertEqual(PushPayloadKeys.campaignId, "jry_campaign_id")
        XCTAssertEqual(PushPayloadKeys.deepLink, "jry_deep_link")
        XCTAssertEqual(PushPayloadKeys.imageUrl, "jry_image_url")
        XCTAssertEqual(PushPayloadKeys.sync, "jry_sync")
    }

    /// A campaign push as the backend now sends it: the receipt and click key
    /// off `trackingId` behind the marker - not off `jry_campaign_id`, which
    /// the receipt used to require and the backend never sent.
    func testCampaignPushYieldsItsTrackingId() {
        let campaign: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "T", "body": "B"]],
            "joryio": "true",
            "trackingId": "abc.def",
            "jry_deep_link": "myapp://sale",
        ]
        XCTAssertTrue(PushPayloadKeys.isJoryio(campaign))
        XCTAssertEqual(PushPayloadKeys.extractTrackingId(campaign), "abc.def")
    }

    func testForeignAndTestPushesYieldNoTrackingId() {
        // Someone else's push that happens to use the same key name.
        XCTAssertNil(PushPayloadKeys.extractTrackingId(["trackingId": "x"]))
        // The marker is a STRING on the wire; a boolean is not the contract.
        XCTAssertFalse(PushPayloadKeys.isJoryio(["joryio": true]))
        // A test send: ours, but nothing to report.
        XCTAssertNil(PushPayloadKeys.extractTrackingId(["joryio": "true"]))
        XCTAssertNil(PushPayloadKeys.extractTrackingId(["joryio": "true", "trackingId": ""]))
    }
}
