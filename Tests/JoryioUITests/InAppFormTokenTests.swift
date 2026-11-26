import XCTest
@testable import Joryio

/// The in-app form token (BACKLOG D371 item 4). The server serves a signed
/// `formToken` with a message that carries a form; the SDK sends it back,
/// unchanged, on POST /v1/in-app/form-submit. The token is looked up by
/// campaign id, so a host-rendered message (React Native, Unity, a custom
/// renderer) that submits with only the id sends it too.
final class InAppFormTokenTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func makeManager() -> InAppMessagingManager {
        let storage = TestSupport.storage()
        let logger = TestSupport.logger()
        let identity = IdentityManager(storage: storage, logger: logger)
        let session = SessionManager(storage: storage, logger: logger, sessionTimeout: 1800)
        return InAppMessagingManager(
            networkClient: TestSupport.network(),
            storage: storage,
            identityManager: identity,
            sessionManager: session,
            logger: logger
        )
    }

    func testTheCampaignDecodesItsFormToken() throws {
        let withToken = try TestSupport.campaign(["id": "c1", "name": "c1", "type": "modal", "formToken": "opaque.form.token"])
        XCTAssertEqual(withToken.formToken, "opaque.form.token")
        let without = try TestSupport.campaign(["id": "c2", "name": "c2", "type": "modal"])
        XCTAssertNil(without.formToken, "a server from before the token sends none")
    }

    func testTheManagerHandsTheSyncedTokenToTheSubmitByCampaignId() throws {
        let manager = makeManager()
        manager.setActiveCampaignsForTesting([
            try TestSupport.campaign(["id": "c1", "name": "c1", "type": "modal", "formToken": "opaque.form.token"]),
        ])
        XCTAssertEqual(manager.formToken(forCampaignId: "c1"), "opaque.form.token")
        XCTAssertNil(manager.formToken(forCampaignId: "other"))
    }

    func testAPresentedTokenSurvivesAnIdentifyAndGoesWithAReset() throws {
        // Same on every SDK (review L6): identify keeps the anonymousId the
        // token is bound to; reset() / wipeData() end that visitor.
        let manager = makeManager()
        manager.rememberFormToken(of: try TestSupport.campaign(["id": "r1", "name": "r1", "type": "modal", "formToken": "resolved.form.token"]))
        manager.invalidate() // identify, consent change
        XCTAssertEqual(manager.formToken(forCampaignId: "r1"), "resolved.form.token")
        manager.clear() // reset, wipeData
        XCTAssertNil(manager.formToken(forCampaignId: "r1"))
    }

    func testTheSubmitCarriesTheTokenAndOmitsItWhenThereIsNone() async throws {
        let network = TestSupport.network()
        _ = try? await network.submitInAppForm(InAppFormSubmitRequest(campaignId: "c1", userId: nil, anonymousId: "a", formToken: "opaque.form.token", values: ["email": .string("ada@example.com")]))
        _ = try? await network.submitInAppForm(InAppFormSubmitRequest(campaignId: "c2", userId: nil, anonymousId: "a", values: [:]))
        let sent = TestSupport.requests("/v1/in-app/form-submit")
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0].json?["formToken"] as? String, "opaque.form.token")
        XCTAssertEqual(sent[0].json?["campaignId"] as? String, "c1")
        XCTAssertNil(sent[1].json?["formToken"], "nil is omitted, not sent as null")
    }
}
