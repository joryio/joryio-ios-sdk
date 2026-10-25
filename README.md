# Joryio iOS SDK

The Joryio SDK for iOS apps: identify users, track events, receive push notifications and display in-app messages, all through your Joryio workspace.

## Features

- **Event tracking** with batching (50 events or 5 seconds by default), an offline SQLite queue and retry with exponential backoff
- **Identity** - anonymous ID out of the box, `identify`, labelled aliases with `addAlias`, `reset` on logout
- **User attributes** - set, increment and unset, queued and retried until the server confirms them
- **Push notifications** over APNs, with delivery receipts, click tracking, deep links and a Notification Service Extension base class for rich images
- **In-app messages** - native (UIKit) and HTML, rendered by the optional `JoryioUI` product or by your own UI
- **E-commerce helpers** that send the standard event names Joryio reports on
- **Subscription preferences** per channel and subscription group
- **Privacy controls** - opt-out, tracking consent (granted, pending, denied) and on-device data wipe
- **SDK authentication** (optional) - a customer-minted JWT on every ingest request

## Requirements

- iOS 14.0+
- Swift 5.9+ (Xcode 15 or newer)
- A Joryio workspace and an **iOS SDK key** (`jry_sdk_ios_...`) from **Settings → Apps** in the dashboard

## Installation

The SDK comes as three products:

| Product | Link it into | Contains |
|---------|--------------|----------|
| `Joryio` | Your app | Tracking, identity and push. No WebKit and no message views linked |
| `JoryioUI` | Your app (optional) | In-app message display. Depends on `Joryio` |
| `JoryioNotificationServiceExtension` | Your Notification Service Extension only | Rich push images. No dependencies and extension-safe (see [Rich images](#3-rich-images-optional)) |

Add `JoryioUI` if you want the SDK to draw in-app messages. Without it, messages are not displayed unless you render them yourself (see [Rendering messages yourself](#rendering-messages-yourself)).

### Swift Package Manager (recommended)

In Xcode: **File → Add Package Dependencies**, enter `https://github.com/joryio/joryio-ios-sdk.git`, choose version `1.3.0` or later, and add `Joryio` and, if you want in-app display, `JoryioUI` to your app target.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/joryio/joryio-ios-sdk.git", from: "1.3.0")
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "Joryio", package: "joryio-ios-sdk"),
            .product(name: "JoryioUI", package: "joryio-ios-sdk"), // optional: in-app display
        ]
    )
]
```

### CocoaPods (legacy)

CocoaPods trunk becomes read-only on 2 December 2026, so the last Joryio pod is the last version released before that date (1.3.1 is published there too); later releases ship through Swift Package Manager only, which is the recommended route. To move, delete the `pod 'Joryio...'` lines, run `pod install`, and add the package as above. A Notification Service Extension then writes `import JoryioNotificationServiceExtension` instead of `import Joryio`.

```ruby
platform :ios, '14.0'

target 'MyApp' do
  pod 'Joryio/UI', '~> 1.3'   # tracking, identity, push AND in-app display
  # pod 'Joryio', '~> 1.3'    # tracking, identity and push only - no WebKit linked
end

# Only if you add a Notification Service Extension for rich images:
target 'NotificationService' do
  pod 'Joryio/NotificationServiceExtension', '~> 1.3'
end
```

Then run `pod install`. The default subspec is the UI-free `Joryio/Core`, so a bare `pod 'Joryio'` does not display in-app messages.

### Privacy manifest

The Swift package and the pod ship Apple's privacy manifest (`PrivacyInfo.xcprivacy`). It declares the one required-reason API the SDK uses - `UserDefaults`, reason `CA92.1` - and the data the SDK collects: user ID, device ID, product interaction and purchase history, each linked to the user and not used for tracking. Every one is declared for App Functionality, Analytics and Developer's Advertising or Marketing, and all but the device ID also for Product Personalization. No location is declared: the SDK never reads the device location, and the country the Joryio backend derives from the IP address is not data the SDK collects. Xcode includes it in your app's privacy report. Attributes and event properties you choose to send are yours to declare in your app's own manifest.

## Quick start

### 1. Initialize

In your `AppDelegate`:

```swift
import Joryio

func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
) -> Bool {
    Joryio.shared.initialize(
        sdkKey: "jry_sdk_ios_YOUR_SDK_KEY",
        apiHost: "api-eu1.joryio.com"   // your workspace's API host
    )
    return true
}
```

`apiHost` accepts a bare host, a host with scheme, or the full base URL ending in `/api`; the SDK adds `https://` and `/api` when they are missing. Use the API host shown for your workspace in the dashboard.

With options:

```swift
Joryio.shared.initialize(
    sdkKey: "jry_sdk_ios_YOUR_SDK_KEY",
    apiHost: "api-eu1.joryio.com",
    config: JoryioConfig(
        batchSize: 50,
        flushInterval: 5.0,
        enableDebug: true
    )
)
```

A key that does not start with `jry_sdk_ios_`, or an empty host, is logged as an error and the SDK stays disabled - it never crashes your app. Calling `initialize` a second time is ignored.

Every public method is safe to call before `initialize`. `optOut()`, `optIn()`, `wipeData()`, `updateConsent(_:)`, `setSdkAuthenticationToken(_:)`, `setSdkAuthenticationErrorHandler(_:)` and `setInAppMessageCallback(_:capabilities:)` are remembered and applied when the SDK starts. Calls that collect or send - `track`, `identify`, attributes, `addAlias`, subscriptions, `reset`, `flush`, the push token, receipt, click and unregister calls, and in-app reports - are queued (at most 1000, oldest dropped first, the same limit on every Joryio SDK) and run in order once `initialize` succeeds. Getters return empty values until then. A call that collects data - an event, an attribute, an alias, a subscribe, a push receipt or click, an in-app report - made while the user is opted out or consent is denied is dropped at once: a later `optIn()` or `.granted` never sends it. `identify` is still kept, so that withdrawals carry the right user. A call missing a required value (`identify("")`, `track("")`, an empty attribute key) logs a warning and does nothing. Decisions made before `initialize` - `optOut()`, `optIn()`, `updateConsent(_:)`, `wipeData()` - take effect before anything the SDK does at start, and an `optOut()` / `optIn()` made before `initialize` wins over `optOut` in the config. `isUserOptedOut()` and `getTrackingConsent()` answer from what is stored even before `initialize`. When nothing has been decided yet, `getTrackingConsent()` answers `.granted` - the consent an app without a consent banner starts with. If `initialize` refuses the SDK key or the host, `registerPushToken(_:onResult:)` answers `success: false` at once instead of waiting.

**Launched before the first unlock.** Only a launch before the device has been unlocked once since it started (a background push or a location wake right after a reboot) waits: the SDK's storage cannot be read until then. `initialize` finishes by itself on that first unlock, calls made meanwhile stay queued, and `isInitializationPending` is `true` while it waits - not a failure. A device that is merely locked, having been unlocked once since it started, starts at once: a silent push on a locked phone is handled normally.

### 2. Track events

```swift
Joryio.shared.track("Button Tapped")

Joryio.shared.track("Product Viewed", properties: [
    "product_id": "abc123",
    "price": 99.99,
    "category": "Electronics"
])

Joryio.shared.trackScreen("ProductDetail", properties: ["product_id": "abc123"])
```

### 3. Identify users

```swift
Joryio.shared.identify("user-123")
Joryio.shared.setAttributes([
    "email": "user@example.com",
    "name": "Jane Doe",
    "plan": "premium"
])

Joryio.shared.setAttribute("language", value: "en")
Joryio.shared.incrementAttribute("lifetime_value", by: 99.99)
Joryio.shared.unsetAttribute("temporary_flag")

// A second identifier for the same person - works before identify() too
Joryio.shared.addAlias("loyalty_id", name: "L-12345")

// On logout
Joryio.shared.reset()
```

`identify` joins the device's anonymous history to the user on the server, re-registers the push token under them and re-syncs in-app messages. `reset` starts a new anonymous identity at once (a new anonymous ID, no user ID, no pending attribute writes or in-app state, and a new session announced with a Session Start), re-registers the push token under it and re-syncs in-app messages. An `identify` on the line after `reset()` already uses the new identity; events queued before the reset are still sent with the IDs they were tracked under.

Identifying a different user without `reset()` in between is treated like a logout and a login for what the previous user left behind: their unsent attribute writes go out under their own IDs, never the new user's, and with SDK authentication their token stays bound to their queued items. While the person has opted out or consent is denied, `identify` only keeps the user ID on the device, so an unsubscribe, the opt-out record or a push unregister names the right user - nothing is sent, tracked or written to a profile. The normal identify runs once tracking is allowed again; `reset()` and `wipeData()` forget the kept ID.

A number that is not finite (NaN or infinity) in event properties or attribute values is dropped with a log warning, and the rest of the call goes ahead.

`identify`, `addAlias`, the subscription calls, the `tracking_opted_out` record and the server side of `unregisterPush()` / `wipeData()` are kept on the device until the server acknowledges them - across restarts and across `reset()` (each carries the IDs it was made under) - and sent in order, one at a time. A newer change by the same person for the same channel or group replaces one still waiting, so an older retry never lands after it. A write made while anonymous and sent after `identify` goes out under the user ID, as long as the anonymous ID it was made under is still this device's. A write the server refuses for good (HTTP 400, 403, 409, 413, 422) is dropped and logged; a subscription change answered 404 (no profile yet) is retried after the queued events are sent, at most 5 times; `success: false` and the current user's SDK-authentication 401 are retried with backoff, at most 10 times per write. Being offline, timeouts, HTTP 402, 429 and 5xx never count against a write. While ingestion is paused for your workspace (HTTP 402), withdrawals still go out ahead of the writes that have to wait. When 1,000 writes are waiting, the oldest one that is not a withdrawal makes room.

`addAlias` labels must use lowercase letters, digits and underscores. An anonymous visitor's alias stays with their profile when they are identified.

Attribute writes - including `incrementAttribute` (sent as an atomic increment) and `unsetAttribute` - are kept on the device until the server confirms them, so a write made offline is sent when the connection returns, even after an app restart. A `200` response with `success: false` is not a confirmation. A write the server refuses as invalid (HTTP 400, 413 or 422) is split and resent in halves, so one bad key cannot hold up the others; a single write still refused is dropped and logged. A write made while a request is in flight never cancels it, so an increment is never counted twice. `setAttribute(key, value: nil)` - or `NSNull` from a bridge - removes the attribute.

### Where identifiers are stored

| Value | Stored in | Survives app deletion |
|-------|-----------|-----------------------|
| Anonymous ID, device ID, session | `UserDefaults` | No |
| Opt-out, a stored consent denial, decisions made before `initialize`, in-app display history | `UserDefaults` | No |
| User ID, APNs device token, unsent attribute writes, pending push unregisters (they carry the token), a user ID kept while opted out, a logged-out user's SDK-authentication token (until that user's queued items are sent or dropped) | Keychain (this device only, after first unlock) | No - the SDK detects a reinstall and clears its Keychain items |
| Queued events; identify, alias, subscription and opt-out writes waiting for the server; attribute writes a previous user left when the app identified someone else without `reset()` | SQLite in Application Support, excluded from backups | No |

Every key the SDK writes to `UserDefaults` starts with `jry_` or `joryio_`.

### Automatic session data

**Session Start** events carry device and environment data: `$device_id`, `$platform`, `$model`, `$os_name`, `$os_version`, `$app_version`, `$build_number`, `$bundle_id`, `$screen_width`, `$screen_height`, `$locale`, `$language`, `$languages` and `$timezone`.

## Configuration options

All parameters of `JoryioConfig` are optional:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `userId` | `String?` | `nil` | Start with a known user ID |
| `anonymousId` | `String?` | generated | Use your own anonymous ID |
| `batchSize` | `Int` | `50` | Events per request (at most 500, the server's limit) |
| `flushInterval` | `TimeInterval` | `5.0` | Seconds between automatic flushes (minimum `1.0`) |
| `sendImmediately` | `Bool` | `false` | Send each event immediately |
| `maxQueueSize` | `Int` | `1000` | Most events kept on the device while they cannot be sent. Only this cap drops events, oldest first |
| `sessionTimeout` | `TimeInterval` | `1800` | Seconds of inactivity before a new session |
| `trackSessionStart` | `Bool` | `true` | Track "Session Start" automatically |
| `requestPushPermissionAtLaunch` | `Bool` | `false` | Ask for notification permission at initialize. Prefer asking at a moment the user understands |
| `inApp` | `InAppConfig` | `InAppConfig()` | In-app messaging options (below) |
| `maxRetries` | `Int` | `3` | Retry attempts per request (event batches back off between flushes instead) |
| `retryBackoffMs` | `Double` | `1000` | Initial retry backoff in ms |
| `requestTimeout` | `TimeInterval` | `10.0` | Per-request timeout in seconds |
| `enableSdkAuthentication` | `Bool` | `false` | Attach a customer-minted JWT to every ingest request |
| `sdkAuthenticationToken` | `String?` | `nil` | Initial JWT |
| `optOut` | `Bool` | `false` | Start opted out of tracking. A call to `optOut()` persists across launches regardless of this value |
| `trackingConsent` | `TrackingConsent?` | `nil` (unset) | `.granted`, `.pending` or `.denied`. Unset keeps a stored `.denied`, otherwise behaves as `.granted` - see [Tracking consent](#tracking-consent) |
| `enableDebug` | `Bool` | `false` | Turns logging on - at `.debug` unless `logLevel` is set; also enables the testing-only APIs |
| `logLevel` | `LogLevel?` | `nil` | `.error`, `.warn`, `.info` or `.debug`. Unset: `.debug` with `enableDebug`, otherwise `.error` |

`InAppConfig`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `enabled` | `true` | `false` turns in-app messaging off: no sync, nothing displayed |
| `allowHtmlJsInAppMessages` | `false` | Display HTML messages (see [In-app messaging](#in-app-messaging)) |
| `syncInterval` | `300` | Minimum seconds between automatic syncs (launch, foreground) |
| `onMessageDisplay` | `nil` | Called on the main thread after the SDK displays a message |
| `onMessageClick` | `nil` | Called on the main thread with the message and the tapped element's name |
| `onMessageDismiss` | `nil` | Called on the main thread after a message is dismissed |

## Push notifications

Joryio sends iOS push through APNs. Upload your APNs key or certificate in the dashboard first - see [APNs credentials](https://docs.joryio.com/developers/apps/apns-credentials).

### 1. Forward the AppDelegate callbacks

```swift
import Joryio

class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Joryio.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Joryio.shared.didFailToRegisterForRemoteNotifications(error: error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Joryio.shared.didReceiveRemoteNotification(userInfo, completionHandler: completionHandler)
    }
}
```

`initialize` sets the SDK as the `UNUserNotificationCenter` delegate, keeping any delegate your app set before it. The SDK acts only on Joryio notifications (payload key `joryio`): it shows them while the app is in the foreground and handles their taps (click tracking and deep links). Every other notification, and the settings callback, is forwarded to your delegate unchanged. If you set your own delegate after `initialize`, report Joryio taps yourself with `trackPushClick(trackingId:)`.

An engine that receives the APNs token itself can hand it over the same way: the Unity bridge passes the token from `kUnityDidRegisterForRemoteNotificationsWithDeviceToken` to `didRegisterForRemoteNotifications(deviceToken:)`. A token that arrives before `initialize` is kept and registered when the SDK starts.

The token is registered with Joryio only while the user is opted in and tracking consent is granted; otherwise it is kept on the device and registered when that changes. Delivery receipts and click tracking follow the same rule.

### 2. Ask for permission

Ask when the user has a reason to say yes - the system prompt can be shown only once.

```swift
let status = await Joryio.shared.getPushPermissionStatus()   // "granted", "denied" or "notDetermined"
if status == "notDetermined" {
    let granted = await Joryio.shared.requestPushPermission()
}
```

`requestPushPermission` also registers for remote notifications, so the token reaches Joryio through the AppDelegate callback above.

If another library already owns registration, pass the APNs token yourself as a hex string. Anything else - such as a Firebase (FCM) registration token - is refused with `success: false` and a log line:

```swift
Joryio.shared.registerPushToken(hexToken) { result in
    if !result.success && result.isRetryable {
        // transient failure (offline, DNS, 5xx): try again later
    }
}
```

Provisional and ephemeral authorization count as `"granted"`. `isPushEnabled()` is `true` exactly when the status is `"granted"`. The `push_permission` user attribute uses the same values, with `not_determined` for `"notDetermined"`.

More push calls: `isPushEnabled()` (async), `getDeviceToken()`, `unregisterPush()`, `updateBadgeCount(_:)`, `clearBadge()`, `trackPushClick(trackingId:)` and `reportPushDelivered(_:)` (for apps that handle notifications themselves).

`unregisterPush()` removes the token on the Joryio server and with iOS, and it is remembered across launches: the token iOS hands over at a later launch is kept on the device but not registered, until the app calls `registerPushToken(_:onResult:)` or `requestPushPermission()` again. `registerPushToken` reports a `200` with `success: false` as a failure.

### 3. Rich images (optional)

APNs cannot attach an image by itself; a Notification Service Extension in your app has to. Add one (**File → New → Target → Notification Service Extension**) and add the extension product to **that target only**:

- Swift Package Manager: `JoryioNotificationServiceExtension`
- CocoaPods: `pod 'Joryio/NotificationServiceExtension'` in the extension's target block

Do not link `Joryio` into the extension: it uses `UIApplication.shared`, which app extensions may not call, and it brings SQLite into a process limited to 24 MB. The extension product has no dependencies. Replace the generated class with:

```swift
import JoryioNotificationServiceExtension   // CocoaPods: import Joryio

class NotificationService: JoryioNotificationService {}
```

It downloads the URL in the payload's `jry_image_url` key (or `attachment-url`, the name other tools use) and attaches it.

### Payload keys

Every Joryio push carries the same keys on iOS, Android and web, at the root of the APNs payload beside `aps`. The names are also constants on `PushPayloadKeys`.

| Key | Effect |
|-----|--------|
| `joryio` | Always `"true"` on a Joryio push; other notifications are ignored |
| `trackingId` | Used for the delivery receipt and for click tracking. Absent on test sends, which are not counted |
| `jry_campaign_id` | The campaign id, or the journey id for a journey send. For your app; the SDK does not act on it |
| `jry_deep_link` | Opened with `UIApplication.open` when the notification is tapped |
| `jry_image_url` | Image attached by `JoryioNotificationService` (`attachment-url` is accepted too) |
| `jry_sync` | Silent sync nudge. `in_app` (or `campaigns`) makes the SDK fetch in-app campaigns now; nothing is shown |

## In-app messaging

With `JoryioUI` linked, the SDK draws eligible messages itself and tracks impressions, clicks and dismissals. It discovers `JoryioUI` at `initialize` - there is no registration call.

Messages come in two shapes:

- **Native** - structured data (headline, body, image, buttons) drawn with UIKit views that honour your app's tint colour, Dynamic Type, dark mode and VoiceOver. No web view.
- **HTML** - author-supplied markup and CSS, shown in a `WKWebView`.

**HTML messages are off by default**, because they run inside your app. Opting in is your team's decision:

```swift
Joryio.shared.initialize(
    sdkKey: "jry_sdk_ios_YOUR_SDK_KEY",
    apiHost: "api-eu1.joryio.com",
    config: JoryioConfig(inApp: InAppConfig(allowHtmlJsInAppMessages: true))
)
```

Leaving it off does not disable in-app messaging: native messages still display, and HTML campaigns are skipped and logged.

HTML messages are shown under a Content-Security-Policy that blocks all script, frames, network access and form posts - the same rules as the web SDK. Only the SDK's `joryioBridge` runs, so links, buttons, `data-joryio-action` attributes, bridge calls and `data-jry-form` forms work, but an author's own `<script>`, inline `on*` handlers and `<iframe>` embeds do not execute on iOS (or on web).

Banners and slide-ups take touches only inside the message; the rest of your app stays usable behind them. Modal and fullscreen messages block the screen.

Campaigns sync at launch and when the app enters the foreground (at most once per `syncInterval`), and immediately when the user is identified or reset, when a push is tapped, and when an attribute a campaign watches changes. Event-triggered, push-tap and attribute-threshold messages go through the same frequency caps and one-message-at-a-time rule as any other. You can also sync on demand:

```swift
await Joryio.shared.syncInAppCampaigns()
```

### Rendering messages yourself

Set a callback to draw messages with your own UI. It takes over from the SDK's rendering, so you will not get two copies:

```swift
Joryio.shared.setInAppMessageCallback({ campaign in
    showMyMessage(campaign)
    Joryio.shared.trackInAppImpression(campaignId: campaign.id, action: "displayed")
}, capabilities: ["content.native"])

// When a button is tapped, and when the message closes:
Joryio.shared.trackInAppImpression(campaignId: campaign.id, action: "clicked", elementId: "buy_now")
Joryio.shared.trackInAppImpression(campaignId: campaign.id, action: "dismissed")

// Hand display back to the SDK's own renderer:
Joryio.shared.clearInAppMessageCallback()
```

You must then report what happened with `trackInAppImpression(campaignId:action:elementId:)` - `action` is `"displayed"`, `"clicked"`, `"dismissed"` or `"converted"`, and `elementId` optionally names the button or link for a click. Any other action is refused with a log message. Your `"displayed"` report is the only one sent for that message (the SDK does not send its own), and it is what counts the message against the campaign's frequency cap: a message handed to your callback and never reported as displayed uses none of it. `"dismissed"` frees the SDK to hand over the next message: a message you reported `"displayed"` holds the display until you report `"dismissed"`, so nothing is drawn on top of it. Without any report, the SDK frees itself after 30 seconds; a message reported `"displayed"` and never `"dismissed"` holds the display for at most 5 minutes. Report `"dismissed"` whenever the message leaves the screen, including after a click. A message waiting on its display delay is not handed over once the user is identified as someone else, opts out or changes consent. `capabilities` says what your renderer can draw: add `"content.html"` only if you host a web view.

### A presenter of your own

To keep the SDK's delivery but replace the drawing, conform to `InAppMessagePresenter` and assign it - it replaces the built-in renderer, before or after `initialize`:

```swift
Joryio.shared.inAppPresenter = MyPresenter()
```

Return `true` from `present(campaign:in:delegate:)` only when the message is on screen; the SDK then reports `"displayed"` and counts the display itself. Report taps with the delegate's `messageViewClicked(_:action:url:)` and closing with `messageViewDidDismiss(_:)`. Do not call `trackInAppImpression` from a presenter: the message would be reported twice.

Forms inside a message are submitted with `submitInAppForm(campaignId:values:)` (async, never throws; the SDK's own renderer calls it for you). A submission is sent once and not retried, so a form is never submitted twice.

### Testing helpers

`resetDisplayedCampaigns()` and `evaluateInAppCampaigns()` change live state, so they only run when `enableDebug` is on.

## E-commerce

```swift
let ecommerce = Joryio.shared.ecommerce(config: EcommerceConfig(currency: "USD"))

let shirt = EcommerceProduct(productId: "SKU123", name: "Blue Shirt", price: 29.99)
ecommerce.viewProduct(shirt)
ecommerce.addToCart(item: EcommerceCartItem(product: shirt, quantity: 1))
ecommerce.purchase(order: EcommerceOrder(
    orderId: "ORD123",
    items: [EcommerceCartItem(product: shirt, quantity: 1)],
    value: 29.99
))
```

`purchase` sends `Order Completed` with the keys revenue reporting reads: `orderId` and `total`. If you track a purchase with `track()` yourself, use the same keys - `order_id` and `value` are not read, and the order counts as zero revenue.

A call missing what makes the event meaningful - a `productId`, an `orderId`, a finite price or value, an `items` list in a purchase (it may be empty) - logs a warning and sends nothing, never an empty or zero order.

Also available: `viewCategory`, `search`, `removeFromCart`, `cartViewed`, `updateCart`, `startCheckout`, `addPaymentInfo`, `orderFulfilled`, `orderDelivered`, `orderCancelled`, `orderRefunded`, `addToWishlist`, `removeFromWishlist`, `shareProduct`, `applyCoupon`, `removeCoupon` and `submitReview`. See [E-commerce tracking](https://docs.joryio.com/developers/sdk/ecommerce-tracking).

## Subscription preferences

Whether a person may be **messaged** on a channel - separate from `optOut()`, which is whether they may be **tracked**.

```swift
Joryio.shared.setSubscription(channel: "email", status: "unsubscribed")
Joryio.shared.addToSubscriptionGroup("list_abc123", channel: "email")
Joryio.shared.removeFromSubscriptionGroup("list_abc123", channel: "email")
```

Channels: `email`, `sms`, `whatsapp`, `push`, `viber`. Statuses: `optedIn`, `subscribed`, `unsubscribed`.

A change made while tracking consent is pending waits on the device and is sent when consent is granted; one that fails is kept, across restarts and `reset()`, and sent again.

An **unsubscribe** - `status: "unsubscribed"`, or `removeFromSubscriptionGroup` - is a withdrawal: it is accepted and delivered even when the person has opted out, consent is pending or denied, or after `wipeData()`. Subscribing and joining a group are not.

## Privacy controls

```swift
Joryio.shared.optOut()            // stop tracking - remembered across launches
Joryio.shared.optIn()             // resume
Joryio.shared.isUserOptedOut()    // the opt-out switch only
Joryio.shared.getTrackingConsent() // .granted, .denied or .pending
Joryio.shared.wipeData()          // erase everything this SDK stored on the device

let (userId, anonymousId) = Joryio.shared.getIdentity()
```

`optOut()` stops every write: events, attributes, aliases, subscribing, push registration and receipts, and in-app impressions. Data collected but not yet sent is discarded. Withdrawals still go out and are never discarded: an unsubscribe, the opt-out record and a push unregister. The choice is stored on the device - not per SDK key, so it survives a key change too - and `optOut: true` in the config is stored the same way. The SDK records it on the profile as the attribute `tracking_opted_out` (`true`, and `false` again on `optIn()`), so campaigns can exclude on it. The record is sent only when the opt-out changes - including `optOut: true` in the config or a call made before `initialize` - whatever the consent (pending or denied too), and retried until the server stores it.

`wipeData()` erases the user ID and anonymous ID, the device ID, queued events, unsent attribute writes, in-app state, the session and the push token, which is also unregistered on the Joryio server. It keeps the opt-out, and it does not opt the user out; call `optOut()` as well if that is intended. The next event (or the next time the app comes to the foreground) starts a new session, announced with a Session Start.
Push then stays off until the app calls `registerPushToken(_:)` or `requestPushPermission()` again - a token iOS hands over on a later launch is not registered automatically. Registering and unregistering run one at a time: registering a token again cancels its unregister if that has not reached the server yet, and an unconfirmed unregister of another token is sent before any new registration.

### Tracking consent

Pass the consent your consent manager holds at launch, and update it when the user decides:

```swift
Joryio.shared.initialize(
    sdkKey: "jry_sdk_ios_YOUR_SDK_KEY",
    apiHost: "api-eu1.joryio.com",
    config: JoryioConfig(trackingConsent: .pending)
)

// Later, from your consent banner:
Joryio.shared.updateConsent(.granted)   // or .denied
```

| Consent | Behaviour |
|---------|-----------|
| `.granted` | Normal |
| `.pending` | Events and attribute writes are kept on the device (up to `maxQueueSize`) and nothing is sent: no Session Start, no in-app sync, no push registration. `.granted` sends what was kept; `.denied` discards it |
| `.denied` | Nothing is collected, and anything kept is cleared |

Consent and opt-out are two independent switches: collection happens only when consent is `.granted` AND the person has not opted out - either "no" wins.

- `.denied` is **stored** and holds across launches. Only an explicit `updateConsent(.granted)` or `trackingConsent: .granted` in the config lifts it.
- `trackingConsent` defaults to **unset** (`nil`): with nothing stored it behaves as `.granted`, so an app without a consent banner just works; a stored `.denied` stays.
- `.pending` is not stored: it applies to this launch only and never overrides a `.denied` - stored, or set earlier before `initialize`.
- Consent never lifts an opt-out - only `optIn()` does - and `optOut()` never changes the stored consent.
- `getTrackingConsent()` returns the consent in effect; `isUserOptedOut()` reflects only the opt-out.
- A session that began while collection was not allowed is announced with a Session Start once it is allowed - later in the same launch, or at a later launch as a new session.

## SDK authentication (optional)

When SDK authentication is enabled for your workspace, every ingest request must carry a JWT minted by your backend. Supplying a token - in `sdkAuthenticationToken` or with `setSdkAuthenticationToken(_:)`, before or after `initialize` - turns the header on, with or without `enableSdkAuthentication`:

```swift
Joryio.shared.initialize(
    sdkKey: "jry_sdk_ios_YOUR_SDK_KEY",
    apiHost: "api-eu1.joryio.com",
    config: JoryioConfig(enableSdkAuthentication: true, sdkAuthenticationToken: initialToken)
)

Joryio.shared.setSdkAuthenticationErrorHandler { error in
    // error.reason: .missing, .invalid, .expired, .subMismatch ...
    fetchFreshToken { Joryio.shared.setSdkAuthenticationToken($0) }
}

// When whatever installed the handler goes away (a bridge, a screen):
Joryio.shared.clearSdkAuthenticationErrorHandler()
```

An empty token is ignored with a warning; it never switches authentication on or replaces a valid token. SDK authentication verifies identified users: anonymous visitors' events, attributes, aliases, subscriptions and push registration are accepted without a token unless your workspace turns on strict SDK identity.

`reset()` clears the token. Events and writes the outgoing user had already queued still go out with that user's token, so a normal logout loses nothing - the token is kept in the Keychain, bound to those items, until they are sent or dropped, so closing the app right after a logout loses nothing either. Identifying a different user without `reset()` does the same with the previous user's token, and so does setting the next user's token with `setSdkAuthenticationToken(_:)`: set it before or after `identify`, in either order the previous user's leftovers keep their own token. Each request carries the token whose `sub` is that request's user, never one that names someone else; a token set for the next user before `reset()` - also while no one is signed in - is kept for them and used again at their `identify`, and `wipeData()` forgets it - unless it is the token of the user being erased (also one identified while tracking is off), or the token supplied for this launch when a `wipeData()` made before `initialize()` runs. Events and writes left over from a user who is no longer the current one are dropped when SDK authentication refuses them, whatever the reason (`missing`, `sub_mismatch`, `expired`, `invalid`), so they cannot block the next user's. Your error handler hears only about the current user's requests - never about a previous user's leftovers. While the person has opted out or consent is denied, still set the user's token at login: the user identified meanwhile counts as the current one for their unsubscribe, so if it is refused the handler is asked for their token and the unsubscribe is kept.

## Utilities

```swift
Joryio.shared.flush()                    // send queued events now
Joryio.shared.getQueueSize()
Joryio.shared.getUserId()
Joryio.shared.getAnonymousId()
Joryio.shared.getSessionId()
let (sessionId, start, duration) = Joryio.shared.getSessionInfo()
let (userId, anonymousId) = Joryio.shared.getIdentity()

Joryio.shared.lastTransportError     // the most recent request failure, or nil after a success
Joryio.shared.currentApiEndpoint     // the API base the SDK is sending to
```

The SDK flushes when the app goes to the background and checks the session when it returns; a session that timed out sends a new Session Start.

### How queued events are delivered

Events are sent in batches of at most 500 and about 900 KB. If the server refuses a batch as invalid (HTTP 400, 413 or 422), the SDK splits it and resends the halves, so one bad event cannot hold up the rest; an event refused on its own is dropped and logged. Events the server reports as failed are kept and retried. HTTP 429, 5xx and network failures keep everything and retry with exponential backoff (honouring `Retry-After`). HTTP 402 or 403 stops sending for the rest of the session and keeps the events. Failures never delete events; only `maxQueueSize` does, oldest first. An event the server would refuse for good - an empty name or one over 255 characters, or properties over 50 KB serialized (measured as the server measures it), over 200 top-level keys or nested deeper than 5 levels - is dropped at `track()` with a log line, and events the server lists in `rejectedIndices` are dropped rather than retried. `flush()` skips the SDK's own backoff but never a server `Retry-After`. With SDK authentication a batch never mixes two users, and queued events of a user who has logged out are dropped when the server refuses them for any SDK-authentication reason.

## Troubleshooting

- **No events in the dashboard** - check the key starts with `jry_sdk_ios_`, turn on `enableDebug` (it logs everything unless you also set `logLevel`), read the console, and call `flush()`.
- **No in-app messages** - make sure `JoryioUI` (or `pod 'Joryio/UI'`) is linked, or that you set `setInAppMessageCallback`.
- **No push** - check the Push Notifications capability on your app target, the APNs credentials in the dashboard, and that the AppDelegate callbacks are forwarded.

## Documentation

- [iOS SDK guide](https://docs.joryio.com/developers/sdk/ios-sdk)
- [APNs credentials](https://docs.joryio.com/developers/apps/apns-credentials)
- [Tracking events](https://docs.joryio.com/developers/sdk/tracking-events)
- [E-commerce tracking](https://docs.joryio.com/developers/sdk/ecommerce-tracking)
- [Changelog](./CHANGELOG.md)

## Support

- Issues: https://github.com/joryio/joryio-ios-sdk/issues
- Email: support@joryio.com

## License

Commercial - see [LICENSE](./LICENSE). Use of the SDK requires an active Joryio subscription or agreement.
