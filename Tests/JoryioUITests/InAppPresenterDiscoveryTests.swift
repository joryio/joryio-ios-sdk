import XCTest
@testable import Joryio
@testable import JoryioUI

/**
 Guards the ONE link between the two products that no compiler checks.

 `Joryio.discoverInAppPresenter()` finds the presenter with
 `NSClassFromString("JoryioUI.DefaultInAppMessagePresenter")` and calls
 `init()`. Neither product references the other by type - that is the point of
 the split - so renaming the class, changing its module, dropping `@objc`, or
 removing the no-argument initialiser all compile perfectly and then display no
 in-app messages, forever.

 That is not hypothetical. While building this split, `discoverInAppPresenter()`
 was written and never called; iOS would have shipped with in-app messaging
 silently dead. It was the FIFTH instance of that pattern in this codebase.

 If this fails, do not edit the string here - change base's lookup and the class
 together, in one commit.
 */
final class InAppPresenterDiscoveryTests: XCTestCase {

    /// Must match Joryio.discoverInAppPresenter() exactly.
    private let lookupName = "JoryioUI.DefaultInAppMessagePresenter"

    func testBaseCanFindTheClassByTheNameItLooksUp() {
        let cls = NSClassFromString(lookupName)
        XCTAssertNotNil(
            cls,
            "\(lookupName) is not visible to the Objective-C runtime. It must be an @objc "
                + "NSObject subclass, or NSClassFromString returns nil and no message displays."
        )
    }

    func testTheDiscoveredClassProducesAPresenter() throws {
        let cls = try XCTUnwrap(NSClassFromString(lookupName) as? NSObject.Type)
        let instance = cls.init()
        XCTAssertTrue(
            instance is InAppMessagePresenter,
            "\(lookupName) must conform to InAppMessagePresenter - base casts to it."
        )
    }

    /// The lookup end to end: base's own discovery returns a usable presenter
    /// when JoryioUI is linked.
    ///
    /// This does NOT assert that `initialize()` calls it - that path needs a
    /// real application bundle (initialize reads the main bundle, which is nil
    /// in a host-less SPM test bundle) and fails with
    /// `bundleProxyForCurrentProcess is nil`. So the call site in initialize()
    /// remains unguarded by a test; it is asserted by review, and by the
    /// on-device run in docs/NATIVE_INAPP_ONDEVICE_TEST.md, which is the only
    /// place the whole chain is actually exercised.
    func testBaseDiscoveryReturnsAPresenter() {
        XCTAssertNotNil(
            Joryio.shared.discoverInAppPresenter(),
            "JoryioUI is linked in this test bundle, so discovery must find it. Nil means the "
                + "class name, its module, or its @objc visibility has drifted from base's lookup."
        )
    }
}
