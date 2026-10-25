import Foundation
import UIKit
import WebKit
import XCTest
@testable import Joryio
@testable import JoryioUI

/// D204: an HTML message's height follows its content in BOTH directions.
/// The shim used to report max(body, root) scrollHeight, and the root's is
/// never below the web view's own height - so a modal started at 240pt never
/// got shorter than 240pt, and a message that shrank kept its old height.
final class InAppContentHeightTests: XCTestCase {

    func testContentHeightFollowsTheContentUpToTheCap() {
        XCTAssertEqual(InAppSizing.contentHeight(reported: 80, cap: 700), 80)
        XCTAssertEqual(InAppSizing.contentHeight(reported: 2000, cap: 700), 700)
        XCTAssertEqual(InAppSizing.contentHeight(reported: 0, cap: 700), 1)
    }

    @MainActor
    private func show(_ html: String) throws -> (InAppWebMessageView, WKWebView, NSLayoutConstraint?, UIWindow) {
        let c = try TestSupport.campaign(["id": "c-h", "name": "n", "type": "modal",
                                          "content": ["kind": "html", "html": html, "css": ""]])
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.makeKeyAndVisible()
        let view = try XCTUnwrap(InAppWebMessageView.make(campaign: c, delegate: nil))
        window.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: window.topAnchor),
            view.bottomAnchor.constraint(equalTo: window.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: window.trailingAnchor),
        ])
        window.layoutIfNeeded()
        let webView = try XCTUnwrap(Mirror(reflecting: view).children.first { $0.label == "webView" }?.value as? WKWebView)
        return (view, webView, nil, window)
    }

    @MainActor
    private func height(_ view: InAppWebMessageView) -> CGFloat {
        (Mirror(reflecting: view).children.first { $0.label == "heightConstraint" }?.value as? NSLayoutConstraint)?.constant ?? -1
    }

    /// Runs the loop until `pred` holds or the (cold-simulator-generous) limit passes.
    @MainActor
    private func waitFor(_ limit: TimeInterval = 60, _ pred: () -> Bool) {
        let until = Date().addingTimeInterval(limit)
        while !pred() && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }

    @MainActor
    func testAShortMessageGetsAShortFrame() throws {
        let (view, _, _, window) = try show(#"<div style="height:80px;background:#fff">Short</div>"#)
        XCTAssertEqual(height(view), 240, "starts at the placeholder")
        waitFor { self.height(view) == 80 }
        XCTAssertEqual(height(view), 80, "a short message is as short as its content, not 240")
        _ = window
    }

    @MainActor
    func testAMessageThatShrinksReFits() throws {
        let (view, webView, _, window) = try show(#"<div id="form" style="height:300px">Form</div><div style="height:50px">Footer</div>"#)
        waitFor { self.height(view) == 350 }
        XCTAssertEqual(height(view), 350)
        webView.evaluateJavaScript("document.getElementById('form').remove()", completionHandler: nil)
        waitFor { self.height(view) == 50 }
        XCTAssertEqual(height(view), 50, "the message re-fits after shrinking")
        _ = window
    }
}
