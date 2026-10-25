import Foundation

/// SDK version
public let SDK_VERSION = "1.3.1"

/// Default configuration constants
public struct ConfigDefaults {
    public static let batchSize = 50
    public static let flushInterval: TimeInterval = 5.0
    public static let maxQueueSize = 1000
    public static let maxRetries = 3
    public static let retryBackoffMs = 1000.0
    public static let requestTimeout: TimeInterval = 10.0
    public static let sessionTimeout: TimeInterval = 30 * 60 // 30 minutes
}

// MARK: - In-App Messaging Configuration

/// In-app messaging configuration.
///
/// REMOVED in 1.3.0 because they were accepted and did nothing (SDK contract
/// 11 - every documented option works or is gone):
///  - `evaluationMode`: the SERVER decides it per campaign and sends it with
///    the campaign; the client-wide value was never read.
///  - `displayOptions` (`InAppDisplayOptions`: position, animation, backdrop
///    and close-button colours, z-index): the campaign carries its own
///    placement and style, and no renderer ever read these.
/// `syncInterval` and the three callbacks were also accepted and ignored; they
/// are now wired up.
public struct InAppConfig {
    /// Default minimum gap between automatic syncs, in seconds.
    public static let defaultSyncInterval: TimeInterval = 300

    /// False turns in-app messaging off entirely: no sync, nothing displayed,
    /// nothing reported. Tracking, identity and push are unaffected.
    public let enabled: Bool

    /// Allow in-app messages authored as HTML, which render in a web view
    /// inside your app.
    ///
    /// OFF BY DEFAULT.
    ///
    /// The message document is shown with a Content-Security-Policy that
    /// refuses all script (`script-src 'none'`), frames, network access and
    /// form posts, exactly as the web SDK's sandbox does - only the SDK's own
    /// `joryioBridge`, injected outside the document, runs. Author `<script>`,
    /// inline `on*` handlers and `<iframe>` embeds therefore do NOT execute on
    /// iOS (nor on web). The server no longer strips them, so this CSP is the
    /// control. It stays opt-in because a web view is still a larger surface
    /// than the native renderer, and because some security reviews require
    /// that no web view is created at all.
    ///
    /// Leaving this off does NOT disable in-app messaging: native messages
    /// still display. Only HTML campaigns are skipped.
    public let allowHtmlJsInAppMessages: Bool

    /// Minimum seconds between AUTOMATIC campaign syncs (launch and every
    /// foreground). Syncs the SDK forces because the answer just changed -
    /// identify, reset, a watched attribute, a push tap - are not throttled.
    public let syncInterval: TimeInterval

    /// Called on the main thread after the SDK displays a message.
    public let onMessageDisplay: ((InAppMessage) -> Void)?
    /// Called on the main thread when a button or link in a message is tapped,
    /// with the element's name (button id or `data-action`).
    public let onMessageClick: ((InAppMessage, String) -> Void)?
    /// Called on the main thread after a message is dismissed.
    public let onMessageDismiss: ((InAppMessage) -> Void)?

    public init(
        enabled: Bool = true,
        allowHtmlJsInAppMessages: Bool = false,
        syncInterval: TimeInterval = InAppConfig.defaultSyncInterval,
        onMessageDisplay: ((InAppMessage) -> Void)? = nil,
        onMessageClick: ((InAppMessage, String) -> Void)? = nil,
        onMessageDismiss: ((InAppMessage) -> Void)? = nil
    ) {
        self.enabled = enabled
        self.allowHtmlJsInAppMessages = allowHtmlJsInAppMessages
        self.syncInterval = syncInterval
        self.onMessageDisplay = onMessageDisplay
        self.onMessageClick = onMessageClick
        self.onMessageDismiss = onMessageDismiss
    }
}

// MARK: - Main Configuration

/// Main SDK configuration
/// NOTE: `captureUTM`, `persistQueue`, `resetSessionOnNewCampaign` and
/// `trackPageProperties` were REMOVED (2026-08-16). They were declared, stored
/// and read by nothing - web-SDK concepts (URL parameters, page views) copied
/// into the mobile config and never implemented. Leaving them was worse than a
/// gap: an app setting `captureUTM: false` believed it had switched something
/// off that had never been on. If mobile deep-link attribution is built later,
/// add the flag back at that point and wire it.
public struct JoryioConfig {
    // User Identification
    public let userId: String?
    public let anonymousId: String?

    // Batching & Performance
    /// Events per request. Capped at 500, the server's limit per batch.
    public let batchSize: Int
    /// Seconds between automatic flushes. At least 1 second: a smaller
    /// value is raised to it (a value of 0 or less made the timer spin).
    public let flushInterval: TimeInterval
    public let sendImmediately: Bool
    public let maxQueueSize: Int

    // Session Management
    public let sessionTimeout: TimeInterval
    /// Ask for notification permission automatically, right after `initialize()`.
    ///
    /// **Off by default, and that default is the recommendation.** iOS shows the
    /// system prompt exactly once; a refusal is permanent short of a trip to
    /// Settings. Firing it at launch - before the user has any reason to want
    /// notifications from you - is how apps spend their single ask for nothing.
    /// A soft prompt first - an in-app primer, then the system prompt - is the
    /// common pattern among push SDKs for a flag like this one.
    ///
    /// Turn it on only when notifications ARE the product (a messaging or alerts
    /// app, where a user who declines has no reason to be there). Otherwise show
    /// a primer - the `request_push_permission` in-app button action - and call
    /// `requestPushPermission()` when the user says yes.
    public let requestPushPermissionAtLaunch: Bool

    public let trackSessionStart: Bool

    // UTM Tracking

    // In-App Messaging
    public let inApp: InAppConfig

    // Storage

    // Network & Retry
    public let maxRetries: Int
    public let retryBackoffMs: Double
    public let requestTimeout: TimeInterval

    // SDK Authentication (JWT-based, opt-in)
    /// When true, the app supplies a customer-minted JWT that the SDK attaches
    /// as `X-Joryio-Auth` to every ingest request and refreshes on a 401.
    /// Disabled by default — leaving this false keeps behaviour unchanged.
    public let enableSdkAuthentication: Bool
    /// Optional initial JWT to seed the token store at initialization. The app
    /// may also (or instead) call `setSdkAuthenticationToken(_:)` after init.
    public let sdkAuthenticationToken: String?

    // Privacy & GDPR
    // `respectDoNotTrack` is GONE. It was accepted, stored and never read
    // (audit 2026-09-26, I8). It could not have been read: Do Not Track is a
    // BROWSER signal (`navigator.doNotTrack`) and iOS has no equivalent - App
    // Tracking Transparency governs cross-app tracking, not first-party
    // analytics, and honouring it here would have silently switched the SDK
    // off for every user who declined an unrelated prompt. Web keeps the
    // option because the browser has the concept; a mobile option that can
    // never do anything is worse than none, since it reads as a promise.
    /// Start opted out. Opt-out also PERSISTS: once `optOut()` has been called
    /// the user stays opted out across launches until `optIn()`, whatever
    /// this value says.
    public let optOut: Bool
    /// Consent at launch (SDK contracts 4 and 24, identical on every platform):
    /// - `nil` (the default, "unset"): a `.denied` stored by an earlier launch
    ///   stays; with nothing stored, the SDK behaves as `.granted` - an app
    ///   without a consent banner just works.
    /// - `.granted`: normal. Lifts a stored `.denied`.
    /// - `.pending`: events and attribute writes are kept ON THE DEVICE
    ///   (bounded by `maxQueueSize`) and nothing is sent - no in-app sync, no
    ///   push registration - until `updateConsent(.granted)` releases them or
    ///   `.denied` discards them. For this launch only; never overrides a
    ///   stored `.denied`.
    /// - `.denied`: nothing is collected and anything queued is cleared.
    ///   STORED: holds across launches until `.granted` is given explicitly.
    /// Consent never lifts an opt-out; only `optIn()` does.
    public let trackingConsent: TrackingConsent?

    // Debugging
    /// Logging on, and the testing-only APIs enabled. On its own it logs at
    /// `.debug` - everything (SDK contract v5, 58; Android's
    /// `effectiveLogLevel`). It used to leave the level at `.error`, so the
    /// documented troubleshooting switch printed errors only.
    public let enableDebug: Bool
    /// The level in effect: the `logLevel` passed to `init`, or - when none
    /// was - `.debug` with `enableDebug` and `.error` without.
    public let logLevel: LogLevel

    public enum TrackingConsent: String {
        case granted
        case denied
        case pending
    }

    public enum LogLevel: String {
        case error
        case warn
        case info
        case debug
    }

    public init(
        userId: String? = nil,
        anonymousId: String? = nil,
        batchSize: Int = ConfigDefaults.batchSize,
        flushInterval: TimeInterval = ConfigDefaults.flushInterval,
        sendImmediately: Bool = false,
        maxQueueSize: Int = ConfigDefaults.maxQueueSize,
        sessionTimeout: TimeInterval = ConfigDefaults.sessionTimeout,
        trackSessionStart: Bool = true,
        requestPushPermissionAtLaunch: Bool = false,
        inApp: InAppConfig = InAppConfig(),
        maxRetries: Int = ConfigDefaults.maxRetries,
        retryBackoffMs: Double = ConfigDefaults.retryBackoffMs,
        requestTimeout: TimeInterval = ConfigDefaults.requestTimeout,
        enableSdkAuthentication: Bool = false,
        sdkAuthenticationToken: String? = nil,
        optOut: Bool = false,
        trackingConsent: TrackingConsent? = nil,
        enableDebug: Bool = false,
        logLevel: LogLevel? = nil
    ) {
        self.userId = userId
        self.anonymousId = anonymousId
        self.batchSize = batchSize
        self.flushInterval = flushInterval
        self.sendImmediately = sendImmediately
        self.maxQueueSize = maxQueueSize
        self.sessionTimeout = sessionTimeout
        self.trackSessionStart = trackSessionStart
        self.requestPushPermissionAtLaunch = requestPushPermissionAtLaunch
        self.inApp = inApp
        self.maxRetries = maxRetries
        self.retryBackoffMs = retryBackoffMs
        self.requestTimeout = requestTimeout
        self.enableSdkAuthentication = enableSdkAuthentication
        self.sdkAuthenticationToken = sdkAuthenticationToken
        self.optOut = optOut
        self.trackingConsent = trackingConsent
        self.enableDebug = enableDebug
        self.logLevel = logLevel ?? (enableDebug ? .debug : .error)
    }
}

// MARK: - User Attributes

/// User attributes/traits
public typealias UserAttributes = [String: Any]

/// Event properties
public typealias EventProperties = [String: Any]
