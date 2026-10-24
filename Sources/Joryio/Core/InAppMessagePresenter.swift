#if canImport(UIKit)
import UIKit

/**
 How an in-app message gets DRAWN.

 The base module decides *whether* and *when* to show a message - sync,
 eligibility, targeting, frequency capping, and the
 `allowHtmlJsInAppMessages` policy - then hands it to a presenter. It never
 names a view class, which is what lets the rendering layer ship as a separate
 product (`JoryioUI`) an app can leave out.

 The common split among in-app SDKs, and the one Firebase ships as
 `firebase-inappmessaging` / `-display`. The argument is not bytes: an app
 taking only analytics and push should not link a web view at all, which is a
 procurement question for some security teams rather than a size preference.

 Base ships no implementation. It looks one up by name at initialise time when
 `JoryioUI` is linked, so adding the product is the whole integration step -
 there is no register() call to forget.

 This protocol is deliberately NOT `@objc`: it carries `InAppCampaign`, a Swift
 struct with no Objective-C representation. Only the conforming CLASS is
 `@objc`, which is all `NSClassFromString` needs.
 */
public protocol InAppMessagePresenter: AnyObject {

    /// Draw `campaign` into `window`.
    ///
    /// - Returns: true if the message was displayed. Returning false lets the
    ///   caller treat it as not-shown - it must NOT count an impression for a
    ///   message nobody saw, which is the accounting error that makes a channel
    ///   look healthier than it is.
    func present(
        campaign: InAppCampaign,
        in window: UIWindow,
        delegate: InAppMessageViewDelegate
    ) -> Bool
}
#endif
