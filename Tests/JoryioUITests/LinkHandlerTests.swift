import XCTest
@testable @_spi(JoryioInternal) import Joryio
@testable import JoryioUI

/// The app-wide link handler (`setLinkHandler`) and `forwardUniversalLinks`:
/// the routing decision every surface shares, the refused schemes, and the
/// associated-domain matching. The same cases as Android's LinkRouterTest and
/// the web SDK's links.spec.ts.
final class LinkHandlerTests: XCTestCase {

    override func tearDown() {
        Joryio.shared.clearLinkHandler()
        super.tearDown()
    }

    private func route(_ raw: String, source: JoryioLinkSource = .placement, allowOtherSchemes: Bool = false) -> (routed: Bool, fallback: Int) {
        var fallback = 0
        let routed = LinkRouter.route(URL(string: raw)!, source: source, placementKey: "home_hero", itemId: "i1", allowOtherSchemes: allowOtherSchemes) { fallback += 1 }
        return (routed, fallback)
    }

    func testWithoutAHandlerTheFallbackRuns() {
        XCTAssertFalse(LinkRouter.hasHandler)
        for url in ["https://shop.example/sale", "myapp://cart"] {
            let r = route(url)
            XCTAssertTrue(r.routed, url)
            XCTAssertEqual(r.fallback, 1, url)
        }
    }

    func testAHandlerThatTakesTheLinkStopsTheFallback() {
        var seen: [JoryioLink] = []
        Joryio.shared.setLinkHandler { link in seen.append(link); return true }
        XCTAssertTrue(LinkRouter.hasHandler)
        let web = route("https://shop.example/sale")
        let app = route("myapp://cart")
        XCTAssertEqual(web.fallback, 0)
        XCTAssertEqual(app.fallback, 0)
        // Every link, http(s) included, with its context.
        XCTAssertEqual(seen.map(\.url.absoluteString), ["https://shop.example/sale", "myapp://cart"])
        XCTAssertEqual(seen.map(\.source), [.placement, .placement])
        XCTAssertEqual(seen.map(\.isAppDeepLink), [false, true])
        XCTAssertEqual(seen.first?.placementKey, "home_hero")
        XCTAssertEqual(seen.first?.itemId, "i1")
    }

    func testAHandlerThatDeclinesFallsBack() {
        var calls = 0
        Joryio.shared.setLinkHandler { _ in calls += 1; return false }
        let r = route("https://shop.example/sale")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(r.fallback, 1)
    }

    func testOpenDefaultLaterRunsTheFallbackOnce() {
        var held: JoryioLink?
        Joryio.shared.setLinkHandler { link in held = link; return true }
        let r = route("https://shop.example/sale")
        XCTAssertEqual(r.fallback, 0)
        var fallback = 0
        LinkRouter.route(URL(string: "myapp://cart")!, source: .card, cardId: "c1") { fallback += 1 }
        held?.openDefault()
        held?.openDefault()
        XCTAssertEqual(fallback, 1, "openDefault runs the default once")
        XCTAssertEqual(held?.cardId, "c1")
    }

    func testRefusedSchemesReachNeitherTheHandlerNorTheSystem() {
        var calls = 0
        Joryio.shared.setLinkHandler { _ in calls += 1; return false }
        for url in ["javascript:alert(1)", "data:text/html,x", "file:///etc/hosts", "vbscript:x", "blob:https://x/1", "about:blank", "content://x", "intent://x#Intent;end"] {
            for push in [false, true] {
                let r = route(url, source: push ? .push : .placement, allowOtherSchemes: push)
                XCTAssertFalse(r.routed, url)
                XCTAssertEqual(r.fallback, 0, url)
            }
        }
        // Outside push, only http(s) and app deep links are routed.
        XCTAssertFalse(route("mailto:a@b.example").routed)
        XCTAssertTrue(route("mailto:a@b.example", source: .push, allowOtherSchemes: true).routed)
        XCTAssertEqual(calls, 1)
    }

    func testSourceWireValues() {
        XCTAssertEqual([JoryioLinkSource.inApp, .placement, .card, .push].map(\.rawValue), ["in_app", "placement", "card", "push"])
    }

    func testPlacementLinkRouteCountsTheAppWideHandler() {
        // No view handler, an app-wide one: a deep link is routed, not dropped.
        Joryio.shared.setLinkHandler { _ in true }
        XCTAssertEqual(
            PlacementView.linkRoute(action: "deep_link", url: "myapp://cart", hasDeepLinkHandler: LinkRouter.hasHandler),
            .deepLink(URL(string: "myapp://cart")!)
        )
    }

    // MARK: forwardUniversalLinks

    func testForwardUniversalLinksIsOffByDefault() {
        XCTAssertFalse(JoryioConfig().forwardUniversalLinks)
        XCTAssertTrue(JoryioConfig(forwardUniversalLinks: true).forwardUniversalLinks)
    }

    func testAssociatedDomainMatching() {
        let domains = UniversalLinks.applinkHosts(fromEntitlements: [
            "com.apple.developer.associated-domains": [
                "applinks:shop.example", "applinks:*.brand.example", "applinks:dev.example?mode=developer",
                "webcredentials:login.example", "APPLINKS:Upper.Example",
            ],
        ])
        XCTAssertEqual(domains, ["shop.example", "*.brand.example", "dev.example", "Upper.Example"])
        XCTAssertTrue(UniversalLinks.matches(host: "shop.example", domains: domains))
        XCTAssertTrue(UniversalLinks.matches(host: "SHOP.example", domains: domains))
        XCTAssertTrue(UniversalLinks.matches(host: "upper.example", domains: domains))
        XCTAssertTrue(UniversalLinks.matches(host: "dev.example", domains: domains))
        XCTAssertTrue(UniversalLinks.matches(host: "www.brand.example", domains: domains))
        XCTAssertTrue(UniversalLinks.matches(host: "a.b.brand.example", domains: domains))
        // The wildcard is subdomains only; the apex is its own entry.
        XCTAssertFalse(UniversalLinks.matches(host: "brand.example", domains: domains))
        XCTAssertFalse(UniversalLinks.matches(host: "evilbrand.example", domains: domains))
        XCTAssertFalse(UniversalLinks.matches(host: "www.shop.example", domains: domains))
        XCTAssertFalse(UniversalLinks.matches(host: "shop.example.evil", domains: domains))
        XCTAssertFalse(UniversalLinks.matches(host: "login.example", domains: domains), "webcredentials is not a universal link")
        XCTAssertFalse(UniversalLinks.matches(host: "", domains: domains))
        XCTAssertEqual(UniversalLinks.applinkHosts(fromEntitlements: [:]), [])
    }

    func testEntitlementsAreReadFromACodeSignature() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>com.apple.developer.associated-domains</key><array><string>applinks:shop.example</string></array>
        </dict></plist>
        """.data(using: .utf8)!
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        // SuperBlob: magic, length, count=2 (a code directory slot, then the entitlements slot).
        let entitlementsBlob = be(0xfade7171) + be(UInt32(8 + plist.count)) + [UInt8](plist)
        let directory = be(0xfade0c02) + be(8)
        let headerSize = 12 + 2 * 8
        var blob = be(0xfade0cc0) + be(UInt32(headerSize + directory.count + entitlementsBlob.count)) + be(2)
        blob += be(0) + be(UInt32(headerSize))
        blob += be(5) + be(UInt32(headerSize + directory.count))
        blob += directory + entitlementsBlob
        let extracted = UniversalLinks.entitlementsPlist(fromCodeSignature: Data(blob))
        XCTAssertEqual(extracted, plist)
        let dict = UniversalLinks.entitlements(fromPlist: extracted!)!
        XCTAssertEqual(UniversalLinks.applinkHosts(fromEntitlements: dict), ["shop.example"])
        // Not a SuperBlob, or a truncated one: nothing.
        XCTAssertNil(UniversalLinks.entitlementsPlist(fromCodeSignature: Data([1, 2, 3, 4])))
        XCTAssertNil(UniversalLinks.entitlementsPlist(fromCodeSignature: Data(blob.prefix(blob.count - 10))))
    }

    func testANonHttpsLinkIsNeverAUniversalLink() {
        let logger = Logger(enabled: false, logLevel: .error)
        XCTAssertFalse(UniversalLinks.isOwnUniversalLink(URL(string: "http://shop.example/sale")!, logger: logger))
        XCTAssertFalse(UniversalLinks.isOwnUniversalLink(URL(string: "myapp://cart")!, logger: logger))
    }
}
