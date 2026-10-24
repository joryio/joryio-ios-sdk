import Foundation
import UIKit
import WebKit
import XCTest
@testable import Joryio
@testable import JoryioUI

/// SDK contract v5, 57 - the in-app HTML web view loads the message and
/// nothing else (scan 5 S1, probe P6), and a message reports `dismissed`
/// once (N4).
final class ReleaseRound5WebTests: XCTestCase {

    private func breakoutCampaign() throws -> InAppCampaign {
        try TestSupport.campaign([
            "id": "c-web", "name": "n", "type": "modal",
            "content": [
                "kind": "html",
                "html": "<p>Hello</p>",
                "css": "p{color:red}</style><meta http-equiv=\"refresh\" content=\"0;url=https://example.com/scan5-escaped\"><style>",
            ],
        ])
    }

    /// P6: CSS that closes <style> and adds a meta refresh used to navigate
    /// the message to a remote page with the bridge attached.
    @MainActor
    func testCssCannotNavigateTheMessageAway() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.makeKeyAndVisible()
        let view = try XCTUnwrap(InAppWebMessageView.make(campaign: try breakoutCampaign(), delegate: nil))
        window.addSubview(view)
        let webView = try XCTUnwrap(Mirror(reflecting: view).children.first { $0.label == "webView" }?.value as? WKWebView)
        // Watched on every turn of the run loop, from the first load to the end.
        var escapedTo: String?
        func watch() {
            if webView.url?.host == "example.com" { escapedTo = webView.url?.absoluteString }
        }

        // 1. The message renders. Polled with a generous limit: on a cold CI
        // simulator the WebContent process can take many seconds to start, and
        // the old fixed 6-second watch could end before the document - and the
        // meta refresh it carries - had even loaded (dry run 2026-10-07). The
        // window is required: without one the web view never renders here.
        var text = ""
        let until = Date().addingTimeInterval(90)
        while text != "Hello" && escapedTo == nil && Date() < until {
            var answer: String?
            webView.evaluateJavaScript("document.body ? document.body.textContent : ''") { value, _ in answer = (value as? String) ?? "" }
            let step = Date().addingTimeInterval(2)
            while answer == nil && Date() < step {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                watch()
            }
            text = (answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text != "Hello" { RunLoop.current.run(until: Date().addingTimeInterval(0.2)); watch() }
        }
        XCTAssertNil(escapedTo, "the message web view navigated to \(escapedTo ?? "?")")
        XCTAssertEqual(text, "Hello", "the message document did not render")

        // 2. The refresh (content=0) fires as soon as the document has loaded,
        // so keep watching for a while AFTER it rendered: it must not navigate.
        let settle = Date().addingTimeInterval(3)
        while escapedTo == nil && Date() < settle {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            watch()
        }
        XCTAssertNil(escapedTo, "the message web view navigated to \(escapedTo ?? "?") after it rendered")
        XCTAssertNotEqual(webView.url?.host, "example.com")
    }

    func testCssCannotCloseTheStyleElement() {
        let safe = InAppWebMessageView.styleSafe("a{}</style><script>x</script></STYLE >")
        XCTAssertFalse(safe.contains("</"))
        XCTAssertTrue(safe.contains("<\\/style>"))
    }

    final class Recorder: InAppMessageViewDelegate {
        var appeared = 0, dismissed = 0
        var clicks: [String] = []
        func messageViewDidAppear(_ campaignId: String) { appeared += 1 }
        func messageViewDidDismiss(_ campaignId: String) { dismissed += 1 }
        func messageViewClicked(_ campaignId: String, action: String, url: String?) { clicks.append(url ?? action) }
    }

    /// Only the first about:blank load is allowed; a user's link tap opens
    /// outside the message; every other navigation is cancelled.
    @MainActor
    func testOnlyTheMessageDocumentIsLoaded() throws {
        let recorder = Recorder()
        let view = try XCTUnwrap(InAppWebMessageView.make(campaign: try breakoutCampaign(), delegate: recorder))
        let blank = URL(string: "about:blank")
        let remote = URL(string: "https://example.com/x")
        XCTAssertEqual(view.decide(url: blank, isMainFrame: true, isLinkActivated: false), .allow)
        XCTAssertEqual(view.decide(url: blank, isMainFrame: true, isLinkActivated: false), .cancel, "a second load was allowed")
        XCTAssertEqual(view.decide(url: remote, isMainFrame: true, isLinkActivated: false), .cancel, "a redirect / meta refresh was allowed")
        XCTAssertEqual(view.decide(url: remote, isMainFrame: false, isLinkActivated: false), .cancel, "a frame load was allowed")
        XCTAssertEqual(recorder.clicks, [])
        XCTAssertEqual(view.decide(url: remote, isMainFrame: true, isLinkActivated: true), .cancel)
        XCTAssertEqual(recorder.clicks, ["https://example.com/x"], "a tapped link opens outside the message")
        XCTAssertEqual(view.decide(url: URL(string: "javascript:alert(1)"), isMainFrame: true, isLinkActivated: true), .cancel)
        XCTAssertEqual(recorder.clicks.count, 1)
    }

    /// N4: a close from the script and a backdrop tap within the animation
    /// reported `dismissed` twice.
    @MainActor
    func testDismissIsReportedOnce() throws {
        let recorder = Recorder()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.makeKeyAndVisible()
        let view = try XCTUnwrap(InAppWebMessageView.make(campaign: try breakoutCampaign(), delegate: recorder))
        window.addSubview(view)
        view.dismiss()
        view.dismiss()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(recorder.dismissed, 1)
    }
}
