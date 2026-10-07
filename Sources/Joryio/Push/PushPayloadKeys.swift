import Foundation

/// The push data contract: the keys a Joryio push carries at the root of its
/// APNs payload, under the names the backend sends them
/// (packages/backend/src/common/push/push-payload.contract.ts).
///
/// The same names on every platform - Android reads them from FCM `data`, the
/// web service worker from the push's `data` - and the backend's
/// sdk-push-payload-parity.spec greps this file for each one. Before this, the
/// SDK gated its delivery receipt on `jry_campaign_id` and opened
/// `jry_deep_link`, and the backend sent neither: no campaign push ever
/// produced a receipt or opened its link on iOS.
public enum PushPayloadKeys {
    /// `"true"` on every Joryio push. Payloads without it are not ours.
    public static let marker = "joryio"
    public static let markerValue = "true"

    /// Signed id for the delivery receipt and the click.
    public static let trackingId = "trackingId"

    /// Campaign id, or journey id for a journey send. Informational, for the host.
    public static let campaignId = "jry_campaign_id"

    /// What a tap opens.
    public static let deepLink = "jry_deep_link"

    /// Rich-notification image, attached by `JoryioNotificationService`.
    public static let imageUrl = "jry_image_url"

    /// Silent sync nudge type: `in_app` (or the older `campaigns`).
    public static let sync = "jry_sync"

    /// Whether a payload is a Joryio push.
    public static func isJoryio(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo[marker] as? String) == markerValue
    }

    /// The tracking id, when the payload is a Joryio push that carries one.
    /// A test send carries none: there is nothing to report for it.
    public static func extractTrackingId(_ userInfo: [AnyHashable: Any]) -> String? {
        guard isJoryio(userInfo),
              let id = userInfo[trackingId] as? String,
              !id.isEmpty else { return nil }
        return id
    }
}
