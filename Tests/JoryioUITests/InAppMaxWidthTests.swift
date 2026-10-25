import Foundation
import UIKit
import XCTest
@testable import Joryio
@testable import JoryioUI

/// Responsive HTML in-app messages: a modal or slide-up is
/// min(maxWidth, screen width - margins) wide, as on web and Android. Before
/// this an HTML modal spanned an iPad edge to edge.
final class InAppMaxWidthTests: XCTestCase {

    private func campaign(_ type: String, maxWidth: Double? = nil, kind: String = "html") throws -> InAppCampaign {
        var content: [String: Any] = ["kind": kind, "html": "<p>Hi</p>", "css": "", "body": "Hi"]
        if let maxWidth { content["maxWidth"] = maxWidth }
        return try TestSupport.campaign(["id": "c-\(type)", "name": "n", "type": type, "content": content])
    }

    func testMaxWidthComesFromThePayloadWithTheSameDefaultsAsEverySdk() throws {
        XCTAssertEqual(try campaign("modal", maxWidth: 680).maxWidth, 680)
        XCTAssertEqual(try campaign("modal").maxWidth, 600)
        XCTAssertEqual(try campaign("slideup").maxWidth, 400)
        XCTAssertNil(try campaign("banner", maxWidth: 680).maxWidth)
        XCTAssertNil(try campaign("fullscreen", maxWidth: 680).maxWidth)
        XCTAssertNil(try campaign("modal", maxWidth: 680, kind: "native").maxWidth)
    }

    func testFrameWidthIsTheSmallerOfMaxWidthAndTheScreen() {
        XCTAssertEqual(InAppSizing.frameWidth(maxWidth: 680, available: 1024, margin: 24), 680)
        XCTAssertEqual(InAppSizing.frameWidth(maxWidth: 600, available: 390, margin: 24), 342)
        XCTAssertEqual(InAppSizing.frameWidth(maxWidth: 600, available: 10, margin: 24), 0)
    }

    @MainActor
    private func containerWidth(_ c: InAppCampaign, screen: CGFloat) throws -> CGFloat {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: screen, height: 800))
        let view = try XCTUnwrap(InAppWebMessageView.make(campaign: c, delegate: nil))
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        host.layoutIfNeeded()
        let container = try XCTUnwrap(Mirror(reflecting: view).children.first { $0.label == "container" }?.value as? UIView)
        return container.bounds.width
    }

    @MainActor
    func testModalIsCappedOnATabletAndFitsAPhone() throws {
        XCTAssertEqual(try containerWidth(try campaign("modal", maxWidth: 680), screen: 1024), 680)
        XCTAssertEqual(try containerWidth(try campaign("modal", maxWidth: 680), screen: 390), 390 - 48)
    }

    @MainActor
    func testSlideupDefaultsTo400() throws {
        XCTAssertEqual(try containerWidth(try campaign("slideup"), screen: 1024), 400)
        XCTAssertEqual(try containerWidth(try campaign("slideup"), screen: 390), 390 - 24)
    }

    @MainActor
    func testBannerStillSpansTheScreen() throws {
        XCTAssertEqual(try containerWidth(try campaign("banner", maxWidth: 680), screen: 1024), 1024 - 24)
    }
}
