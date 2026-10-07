import UIKit
#if SWIFT_PACKAGE
// SwiftPM: JoryioUI is its own module. CocoaPods: Joryio/UI is a subspec
// compiled INTO the Joryio module, where this import is a warning that
// fails `pod lib lint` (and so `pod trunk push`).
import Joryio
#endif

/**
 The presenter the base SDK finds when `JoryioUI` is linked.

 Base looks this class up BY NAME (`JoryioUI.DefaultInAppMessagePresenter`) via
 `NSClassFromString` and calls the no-argument initialiser, so **the module
 name, the class name and `init()` are public API between the two products**.
 Renaming any of them is a breaking change no compiler will catch - it would
 simply stop displaying messages, in silence. Change base's lookup in the same
 commit, or not at all.

 `@objc` and the `NSObject` base are required for that lookup: Swift-only types
 are invisible to the Objective-C runtime, and `NSClassFromString` would return
 nil for them.
 */
@objc(DefaultInAppMessagePresenter)
public final class DefaultInAppMessagePresenter: NSObject, InAppMessagePresenter {

    @objc public override init() {
        super.init()
    }

    public func present(
        campaign: InAppCampaign,
        in window: UIWindow,
        delegate: InAppMessageViewDelegate
    ) -> Bool {
        // Native renders with UIKit views; HTML renders in a web view. Both
        // share placement and dismissal semantics, because those belong to the
        // message TYPE rather than to its content.
        //
        // Base has already refused HTML when the app did not opt in, so
        // reaching the web-view branch here means the app allows it.
        let view: BaseMessageView? = {
            if case .native = campaign.content {
                return InAppNativeMessageView.make(campaign: campaign, delegate: delegate)
            }
            return InAppWebMessageView.make(campaign: campaign, delegate: delegate)
        }()

        // `make` returns nil when the campaign carries nothing renderable. Say
        // so rather than showing an empty container the user has to dismiss -
        // and rather than letting the caller count an impression for it.
        guard let messageView = view else { return false }

        window.addSubview(messageView)

        // CONSTRAINTS, not a frame. Both message views set
        // `translatesAutoresizingMaskIntoConstraints = false` on themselves, so
        // Auto Layout DISCARDS any frame assigned to them - and nothing pinned
        // them to the window. The result was a 0x0 view that attached
        // successfully, animated its alpha from 0 to 1, reported success, and
        // occupied no pixels.
        //
        // That is why an in-app message could sync, be selected, count an
        // impression and still be invisible, with every log line saying it
        // worked. Setting .frame here looked like the fix and was a no-op.
        NSLayoutConstraint.activate([
            messageView.topAnchor.constraint(equalTo: window.topAnchor),
            messageView.bottomAnchor.constraint(equalTo: window.bottomAnchor),
            messageView.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            messageView.trailingAnchor.constraint(equalTo: window.trailingAnchor),
        ])
        window.layoutIfNeeded()


        messageView.show()
        return true
    }
}
