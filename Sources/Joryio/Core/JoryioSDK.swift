import Foundation
import UIKit
import UserNotifications

/// Main Joryio SDK class
///
/// ## Safe before initialize()
///
/// Every public method can be called before `initialize()` without crashing
/// (SDK contract 12). Collaborators are implicitly-unwrapped optionals that are
/// nil until init, so each entry point guards first. Settings whose intent
/// must survive - `optOut()`, `optIn()`, `wipeData()`, `updateConsent(_:)`,
/// `setSdkAuthenticationToken(_:)`, the auth-error handler and the in-app
/// callback - are recorded and applied when `initialize()` runs. Calls that
/// collect or send (track, identify, attributes, aliases, subscriptions,
/// reset, flush, push token / receipt / click / unregister, in-app reports)
/// are queued - at most 1000, oldest dropped, the same cap on every platform
/// (SDK contract 20) - and run in order once the SDK has started. Getters
/// return empty values.
///
/// ## Launched before the first unlock
///
/// A launch before the device is unlocked for the first time since boot (a
/// background push, a location wake) cannot read the SDK's storage. The rest
/// of `initialize()` then waits for `protectedDataDidBecomeAvailable`, and
/// every call keeps being queued until it runs (scan 3, S1). A device that is
/// merely LOCKED, having been unlocked once since boot, starts at once: the
/// SDK's files and Keychain items are readable then (scan 4, finding 1).
/// `isInitializationPending` says which.
public class Joryio {
    // Singleton instance
    public static let shared = Joryio()

    private var sdkKey: String!
    private var apiEndpoint: String!
    private var config: JoryioConfig!
    private var logger: Logger!
    private var storage: StorageManager!
    private var identity: IdentityManager!
    private var session: SessionManager!
    private var network: NetworkClient!
    private var queue: QueueManager!
    private var inAppMessaging: InAppMessagingManager!
    private var pushNotifications: PushNotificationManager!
    /// Thread-safe holder for the optional SDK-authentication token + handler.
    /// Created at initialize() from config; shared with NetworkClient.
    private var authStore: SdkAuthTokenStore!

    /// Coalescing window for attribute writes; see scheduleAttributeFlush().
    private static let attributeFlushDebounceMs: UInt64 = 800
    /// Serializes attribute flushes so a burst of setAttributes becomes one
    /// request rather than several overlapping ones.
    private let flushLock = NSLock()
    private var isFlushingAttributes = false
    private var flushAgainRequested = false
    /// The attribute snapshot a request is carrying right now (under
    /// `flushLock`) - an account switch must not send it a second time.
    private var inFlightAttributes: PendingAttributeSnapshot?
    /// The pending-set generation an account switch handed over (under
    /// `flushLock`). Not reset(): a reset discards unsent attribute writes.
    private var handedOverGeneration: Int?
    private var _attributeFlushTask: Task<Void, Never>?

    // MARK: Shared mutable state
    //
    // Read and written from the host's threads, the network tasks and the
    // lifecycle observers. These were bare vars - `isOptedOut`,
    // `lastTransportError`, the in-app counters - which is a data race, not
    // merely a stale read. Everything below goes through `stateLock`.
    private let stateLock = NSLock()
    private var _isInitialized = false
    private var _isOptedOut = false
    private var _consent: JoryioConfig.TrackingConsent = .granted
    private var _lastTransportError: JoryioTransportError?
    private var _inAppHandedOff = 0
    private var _inAppReported = 0
    private var _warnedAboutUnreportedInApp = false
    /// A Session Start that could not be sent when its session began
    /// (consent pending or denied, opted out) - sent once sending is allowed
    /// again in the same session.
    private var _sessionStartOwed = false
    /// wipeData() at runtime started a new session for the new anonymous
    /// id: it is announced by the next event, or the next foreground,
    /// exactly as a timed-out session is (SDK contract v6, 66).
    private var _sessionStartDue = false
    /// initialize() refused the key or the host. Calls that answer through
    /// a callback then answer at once instead of waiting for a start that
    /// will not come (contract v4, 48).
    private var _initFailed = false
    /// initialize() waiting for protected data (see the class doc).
    private var _deferredInit: (sdkKey: String, apiHost: String, config: JoryioConfig?)?
    private var _deferredInitObserver: NSObjectProtocol?
    /// identify, addAlias, subscription changes and the opt-out record,
    /// persisted until the server acknowledges them (SDK contract 28).
    private var outbox: WriteOutbox!

    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private var isInitialized: Bool {
        get { locked { _isInitialized } }
        set { locked { _isInitialized = newValue } }
    }

    private var isOptedOut: Bool {
        get { locked { _isOptedOut } }
        set { locked { _isOptedOut = newValue } }
    }

    private var consent: JoryioConfig.TrackingConsent {
        get { locked { _consent } }
        set { locked { _consent = newValue } }
    }

    /// May the SDK COLLECT (record locally)? Not opted out and consent not denied.
    private var canCollect: Bool {
        locked { _isInitialized && !_isOptedOut && _consent != .denied }
    }

    /// May anything LEAVE the device? Collecting is allowed AND consent is
    /// granted. `.pending` collects and holds; it never sends.
    private var canSend: Bool {
        locked { _isInitialized && !_isOptedOut && _consent == .granted }
    }

    /**
     How in-app messages get drawn. Base names no view class - that is what
     lets the rendering layer ship as a separate product an app can omit.

     Discovered from `JoryioUI` at initialize() when that product is linked, so
     adding it is the whole integration step. Nil means no UI product and no
     host callback: messages are simply not displayed.
     */
    #if canImport(UIKit)
    public var inAppPresenter: InAppMessagePresenter?
    #endif

    /**
     Look for the optional UI product.

     `NSClassFromString` rather than a compile-time reference, because a
     compile-time reference is exactly the coupling the split removes.
     */
    #if canImport(UIKit)
    internal func discoverInAppPresenter() -> InAppMessagePresenter? {
        // The module name DIFFERS BY PACKAGE MANAGER:
        //
        //   SwiftPM    JoryioUI is its own target  -> "JoryioUI.Default…"
        //   CocoaPods  Joryio/UI is a SUBSPEC of the Joryio pod, and subspecs
        //              share one module -> "Joryio.Default…"
        let candidates = [
            "JoryioUI.DefaultInAppMessagePresenter",
            "Joryio.DefaultInAppMessagePresenter",
        ]

        for name in candidates {
            if let cls = NSClassFromString(name) as? NSObject.Type,
               let presenter = cls.init() as? InAppMessagePresenter {
                logger?.info("In-app rendering available (\(name))")
                return presenter
            }
        }

        // WARN, not debug. An app that linked the UI product and still gets no
        // messages needs to see this; an analytics-only app can ignore it.
        logger?.warn(
            "No in-app presenter found - the UI product is not linked, so in-app "
                + "messages will NOT be displayed. Add JoryioUI (SwiftPM) or "
                + "pod 'Joryio/UI' (CocoaPods) if you want them."
        )
        return nil
    }
    #endif

    /// Cached e-commerce tracker, so repeated `ecommerce()` calls do not each
    /// build a new one. Replaced when a caller passes a fresh config.
    private var _ecommerce: EcommerceTracker?

    /// What `initialize()` builds on. Production uses the defaults; tests
    /// supply isolated storage and a stubbed transport, and turn off the
    /// calls into UIApplication / UNUserNotificationCenter that a host-less
    /// test bundle does not have. Internal - not part of the public API.
    struct Environment {
        var storage: ((String, Logger) -> StorageManager)?
        var sessionConfiguration: URLSessionConfiguration = .default
        var defaults: UserDefaults = .standard
        var systemIntegration = true
        /// The Keychain calls the "unlocked since boot?" probe makes. Nil:
        /// the system's. Tests answer with the statuses a device gives before
        /// the first unlock, so they run the PRODUCTION decision
        /// (`KeychainHelper.probeProtectedData`), not a stand-in for it.
        var secItemCalls: KeychainHelper.SecItemCalls?
        /// How long a retired SDK-authentication token is kept at least
        /// (`SdkAuthTokenStore.settleGrace`). Tests shorten it.
        var retiredTokenSettleGrace: TimeInterval = SdkAuthTokenStore.settleGraceSeconds
    }

    private let environment: Environment

    /// The singleton uses the default environment. Tests make their own
    /// instances with `@testable import`.
    init(environment: Environment = Environment()) {
        self.environment = environment
    }

    // MARK: - Calls made before initialize()

    /// Same cap on every platform (SDK contract 20). Oldest dropped first.
    static let maxPreInitCalls = 1000
    private let bufferLock = NSLock()
    /// `purgeable`: the call COLLECTS something, so a later optOut(),
    /// wipeData() or consent denied made before init removes it. unregisterPush,
    /// flush, reset and push-token registration are not collection and stay
    /// (scan 3, M3) - an opt-out used to discard an unregisterPush() too.
    private var preInitCalls: [(call: (Joryio) -> Void, purgeable: Bool, settle: (() -> Void)?)] = []
    /// True once the buffer has been replayed. Until then a call is buffered
    /// even while initialize() is running, so it cannot overtake older ones.
    private var preInitDrained = false

    /// The thread replaying the buffer, whose calls run instead of queueing.
    private var replayThread: Thread?
    /// How many buffered calls were made BEFORE a wipeData() made before init.
    /// A wipe purges the buffered calls that collect, so these are the
    /// withdrawals (and unregisterPush, reset, flush) of the identity being
    /// erased: they run before the wipe, under that identity, and the outbox
    /// keeps them through it (contract v4 36; Unity scan 5, N4). They used to
    /// replay after it, under the new anonymous id.
    private var preWipeCallCount = 0

    /**
     True when the caller may run now. Otherwise `call` is kept (up to 1000,
     oldest dropped) and replayed, in order, at the end of a successful
     initialize() - and the caller returns.

     Calls made before init used to log and do nothing, so a `track()` from an
     app that initialises a moment later - common with deferred launch work -
     was lost, while Android and React Native buffered the same call.

     "Ready" is the buffer having been replayed, not `isInitialized`: a call
     landing between the two would otherwise overtake older buffered ones.

     A call that COLLECTS (`purgeable`) made while the person is opted out or
     consent is denied is dropped at call time, not kept (SDK contract v7,
     73; every SDK the same): it used to wait in the buffer and go out after
     a later optIn() / grant, made before init or after it - data collected
     at a moment the person had said no. `keptWhileRefused`: identify(),
     whose user id is still kept for withdrawals (owner decision D-b).
     */
    private func runNowOrQueue(
        _ call: @escaping (Joryio) -> Void,
        purgeable: Bool = true,
        keptWhileRefused: Bool = false,
        settle: (() -> Void)? = nil,
        method: String = #function
    ) -> Bool {
        bufferLock.lock()
        if preInitDrained || replayThread == Thread.current {
            bufferLock.unlock()
            return true
        }
        bufferLock.unlock()
        // Read outside the buffer lock (it reads defaults and other locks).
        let refused = purgeable && !keptWhileRefused && collectionRefusedNow()
        bufferLock.lock()
        if preInitDrained || replayThread == Thread.current {
            bufferLock.unlock()
            return true
        }
        if refused {
            bufferLock.unlock()
            if isInitialized {
                logger?.debug("\(method) dropped: tracking is opted out or consent is denied")
            } else {
                print("[Joryio] \(method) called before initialize() while tracking is opted out or consent is denied: dropped.")
            }
            return false
        }
        var dropped = false
        if preInitCalls.count >= Self.maxPreInitCalls {
            // The oldest call that COLLECTS goes first; a withdrawal, an
            // unregisterPush(), reset() or flush() only when nothing else is
            // left (SDK contract v5, 51). A burst of track() calls used to
            // push out an unsubscribe made before them.
            let index = preInitCalls.firstIndex(where: { $0.purgeable }) ?? 0
            preInitCalls.remove(at: index)
            if index < preWipeCallCount { preWipeCallCount -= 1 }
            dropped = true
        }
        preInitCalls.append((call, purgeable, settle))
        bufferLock.unlock()
        if dropped {
            print("[Joryio] More than \(Self.maxPreInitCalls) calls were made before initialize(); dropped the oldest data call.")
        }
        if isInitialized {
            logger?.debug("\(method) queued behind the calls made before initialize()")
        } else {
            print("[Joryio] \(method) called before initialize(): queued, and run when the SDK starts.")
        }
        return false
    }

    /// Opted out, or consent denied, as it stands for a call being buffered:
    /// once initialize() has applied the config, the live state; before it,
    /// what is stored or was decided before init (the same answers
    /// `isUserOptedOut()` and `getTrackingConsent()` give then).
    private func collectionRefusedNow() -> Bool {
        if isInitialized { return !canCollect }
        return isUserOptedOut() || getTrackingConsent() == .denied
    }

    /// Replay buffered calls in order. Calls arriving meanwhile from other
    /// threads join the end of the buffer, so ordering holds until it is empty.
    private func drainPreInitCalls() {
        while true {
            bufferLock.lock()
            if preInitCalls.isEmpty {
                preInitDrained = true
                replayThread = nil
                bufferLock.unlock()
                return
            }
            let batch = preInitCalls
            preInitCalls = []
            replayThread = Thread.current
            bufferLock.unlock()
            batch.forEach { $0.call(self) }
        }
    }

    /// initialize() failed: buffered calls that answer through a callback
    /// answer now (contract v4, 48). The rest stay buffered for an
    /// initialize() that succeeds.
    private func settleBufferedCallsAfterFailedInit() {
        bufferLock.lock()
        let settles = preInitCalls.compactMap(\.settle)
        preWipeCallCount -= preInitCalls.prefix(preWipeCallCount).filter { $0.settle != nil }.count
        preInitCalls.removeAll { $0.settle != nil }
        bufferLock.unlock()
        settles.forEach { $0() }
    }

    /// Drop the buffered calls that collect (see `preInitCalls`).
    private func purgeCollectingPreInitCalls(markingWipe: Bool = false) {
        bufferLock.lock()
        preInitCalls.removeAll { $0.purgeable }
        if markingWipe { preWipeCallCount = preInitCalls.count }
        bufferLock.unlock()
    }

    /// Run the calls made before a pre-init wipeData(), under the identity
    /// that wipe erases (see `preWipeCallCount`). Called inside initialize(),
    /// right before that wipe.
    private func runCallsMadeBeforeTheWipe() {
        bufferLock.lock()
        let count = min(preWipeCallCount, preInitCalls.count)
        let batch = Array(preInitCalls.prefix(count))
        preInitCalls.removeFirst(count)
        preWipeCallCount = 0
        let previousReplayThread = replayThread
        replayThread = Thread.current
        bufferLock.unlock()
        batch.forEach { $0.call(self) }
        bufferLock.lock()
        replayThread = previousReplayThread
        bufferLock.unlock()
    }

    /// Diagnostics for tests.
    var preInitCallCountForTesting: Int {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return preInitCalls.count
    }

    /// A warning for a helper (the e-commerce tracker) - through the logger
    /// once there is one, printed before init.
    func logWarning(_ message: String) {
        if let logger { logger.warn(message) } else { print("[Joryio] \(message)") }
    }

    /// Log a "not initialized" message safely - `logger` is nil until
    /// `initialize()` runs.
    private func logNotInitialized(_ method: String = #function) {
        if let logger = logger {
            logger.error("SDK not initialized. Call initialize() first. [\(method)]")
        } else {
            print("[Joryio] SDK not initialized. Call initialize() first. [\(method)]")
        }
    }

    // MARK: - Calls recorded before initialize()

    /// UserDefaults keys for intent that must survive until (and across) the
    /// launch that initialises. Global, not per SDK key: before init there is
    /// no key to scope by. Booleans only - nothing identifying.
    static let pendingOptOutKey = "joryio_pending_opt_out"
    static let pendingWipeKey = "joryio_pending_wipe"
    /// An explicit `updateConsent(.granted / .denied)` made before init, kept
    /// so it is not lost when the app is killed before initialising.
    static let pendingConsentKey = "joryio_pending_consent"
    /// A runtime wipeData() left the new session's Session Start due. Kept
    /// across launches: the wiped install's session is stored, so a launch
    /// within the timeout RESUMES it - and, the due flag being in memory
    /// only, it went out without ever being announced (scan 7, S1). Cleared
    /// when a Session Start is recorded.
    static let sessionStartDueKey = "joryio_session_start_due"
    /// A Session Start owed because collection was not allowed (consent
    /// denied, opted out) when the session began or was discarded. Kept
    /// across launches (SDK contract v8, 85; web the same): the owed flag
    /// was in memory only, so a launch that resumed the session with
    /// collection allowed again - a stored denial lifted by an explicit
    /// grant in the config, an optIn() before init - sent that session's
    /// events without ever announcing it. Cleared when a Session Start is
    /// recorded.
    static let sessionStartOwedKey = "joryio_session_start_owed"

    /// In memory only: a token is a credential and must not sit in defaults.
    private static let preInitLock = NSLock()
    private static var pendingAuthToken: String?
    private static var pendingAuthHandler: ((SdkAuthError) -> Void)?
    private static var pendingConsent: JoryioConfig.TrackingConsent?
    private static var pendingInAppCallback: (callback: (InAppCampaign) -> Void, capabilities: [String]?)?

    private static func withPreInit<T>(_ body: () -> T) -> T {
        preInitLock.lock()
        defer { preInitLock.unlock() }
        return body()
    }

    /**
     The opt-out state an initialising SDK must start in.

     A PERSISTED opt-out wins on its own: a user who called optOut() last run
     must stay opted out even if the host app still passes the default config.
     An `optOut()` / `optIn()` made BEFORE initialize() is applied to storage
     here, so it is honoured now and persisted for every later launch - it used
     to crash the app instead (implicitly-unwrapped storage), and before that
     to be lost.

     Returns that pre-init decision, if there was one. It WINS over
     `optOut` in the config (contract v4, 45): the call is explicit and was
     made later than the config was written.
     */
    @discardableResult
    static func applyPreInitOptOut(to storage: StorageManager, defaults: UserDefaults = .standard) -> Bool? {
        guard defaults.object(forKey: pendingOptOutKey) != nil else { return nil }
        let decision = defaults.bool(forKey: pendingOptOutKey)
        storage.setOptedOut(decision)
        defaults.removeObject(forKey: pendingOptOutKey)
        return decision
    }

    /**
     The consent an initialising SDK starts with (SDK contract 24, model A).

     - An explicit choice wins: `updateConsent(_:)` before init, else
       `trackingConsent` in the config.
     - `granted` lifts a stored `denied`; `denied` is stored.
     - `pending` applies to this launch only and never overrides a stored
       `denied`.
     - Nothing explicit (the config default): a stored `denied` stands,
       otherwise `granted` - an app with no consent banner just works.
     */
    static func startConsent(
        preInit: JoryioConfig.TrackingConsent?,
        config: JoryioConfig.TrackingConsent?,
        storedDenied: Bool
    ) -> JoryioConfig.TrackingConsent {
        switch preInit ?? config {
        case .granted?: return .granted
        case .denied?: return .denied
        case .pending?: return storedDenied ? .denied : .pending
        case nil: return storedDenied ? .denied : .granted
        }
    }

    // MARK: - Initialization

    /// Show enough of a key to compare two, without printing a credential.
    private static func maskKey(_ key: String?) -> String {
        guard let key, key.count > 8 else { return key ?? "nil" }
        return "\(key.prefix(12))…\(key.suffix(4))"
    }

    /// The most recent transport failure, or nil if the last request succeeded.
    ///
    /// The SDK knew it was being rejected and only wrote it to the log, so a
    /// host app's status display could show a confident "initialized" while
    /// every single request came back 401.
    public var lastTransportError: JoryioTransportError? {
        locked { _lastTransportError }
    }

    /// The endpoint this SDK is ACTUALLY sending to.
    public var currentApiEndpoint: String? { apiEndpoint }

    /// The API base every request is built on (`<base>/v1/track/batch`).
    /// Accepts a bare host, a host with scheme, or the full base with "/api".
    /// Keep identical to `normalizeApiEndpoint` (web) and `normalizeBaseUrl` (Android).
    static func normalizeApiEndpoint(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let withScheme = (lower.hasPrefix("http://") || lower.hasPrefix("https://")) ? trimmed : "https://\(trimmed)"
        var noSlash = withScheme
        while noSlash.hasSuffix("/") { noSlash.removeLast() }
        if let url = URL(string: noSlash), url.path.isEmpty || url.path == "/" {
            return noSlash + "/api"
        }
        return noSlash
    }

    /// Initialize the SDK with SDK key and API host
    /// - Parameters:
    ///   - sdkKey: Your SDK key (e.g., "jry_sdk_ios_abc123...")
    ///   - apiHost: API host (e.g., "api-eu1.joryio.com")
    ///   - config: Optional configuration for additional settings
    public func initialize(sdkKey: String, apiHost: String, config: JoryioConfig? = nil) {
        // Device info is built on background queues; UIKit's screen size is
        // read on the main thread and cached for them.
        DeviceInfo.primeScreenSize()
        guard !isInitialized else {
            // Re-initialisation is NOT supported: managers, timers, the queue
            // and the session are all built at init. Say so LOUDLY when the
            // caller asked for something different, and name WHAT differs.
            let requested = Self.normalizeApiEndpoint(apiHost)
            var differences: [String] = []
            if requested != apiEndpoint {
                differences.append("apiHost (using \(apiEndpoint ?? "nil"), not \(requested))")
            }
            if sdkKey != self.sdkKey {
                differences.append("sdkKey (using \(Self.maskKey(self.sdkKey)), not \(Self.maskKey(sdkKey)))")
            }
            if !differences.isEmpty {
                let message = "initialize() called again with a different "
                    + differences.joined(separator: " and ")
                    + ". The new values are IGNORED - restart the app to apply them."
                if let logger { logger.error(message) } else { print("[Joryio] ERROR: \(message)") }
            } else {
                logger?.debug("initialize() called again with the same configuration; ignoring")
            }
            return
        }

        if locked({ _deferredInit != nil }) {
            print("[Joryio] initialize() is already waiting for the device to be unlocked; this call is ignored.")
            return
        }

        // Validate SDK key - loudly, but WITHOUT crashing: an analytics SDK
        // must never be the reason an app cannot start. `isInitialized` stays
        // false, which every entry point guards on, so the SDK sends nothing.
        guard sdkKey.hasPrefix("jry_sdk_ios_") else {
            print(
                "[Joryio] ERROR: Invalid SDK key format: keys must start with "
                    + "'jry_sdk_ios_'. The SDK will NOT send any data. Copy your SDK key "
                    + "from the Joryio dashboard."
            )
            initializationFailed()
            return
        }

        guard !apiHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print(
                "[Joryio] ERROR: apiHost is empty. The SDK will NOT send any data. "
                    + "Pass your API host to initialize()."
            )
            initializationFailed()
            return
        }
        locked { _initFailed = false }

        // Launched before the first unlock since boot: storage reads as empty
        // and the database cannot be opened. Starting now ran the SDK on that
        // empty view - opt-out read as false, a NEW anonymous id, no database
        // for the whole process, push re-registered under the new id even for
        // a person who had opted out or unregistered (scan 3, S1). Wait.
        guard isProtectedDataAvailable(sdkKey: sdkKey) else {
            deferInitialization(sdkKey: sdkKey, apiHost: apiHost, config: config)
            return
        }

        self.sdkKey = sdkKey
        // Same rule as web and Android: scheme added, trailing slash dropped,
        // "/api" appended when the host carries no path.
        self.apiEndpoint = Self.normalizeApiEndpoint(apiHost)
        self.config = config ?? JoryioConfig()

        self.logger = Logger(enabled: self.config.enableDebug, logLevel: self.config.logLevel)
        logger.info("Initializing Joryio SDK v\(SDK_VERSION)")
        logger.debug("SDK Key: \(sdkKey)")
        logger.debug("API Endpoint: \(self.apiEndpoint ?? "unknown")")

        // Initialize core components
        self.storage = environment.storage?(sdkKey, logger) ?? StorageManager(sdkKey: sdkKey, logger: logger)

        // SDK authentication: on when configured OR when a token is supplied -
        // at init, or before it through setSdkAuthenticationToken (Android
        // opts in the same way). Tokens retired at a logout come back from
        // the Keychain, still bound to that user's queued items (D-a).
        let preInitToken = Self.withPreInit { Self.pendingAuthToken }
        self.authStore = SdkAuthTokenStore(
            enabled: self.config.enableSdkAuthentication,
            initialToken: preInitToken ?? self.config.sdkAuthenticationToken,
            persistedRetired: storage.getRetiredAuthTokens(),
            persistRetired: { [weak storage = self.storage] in storage?.setRetiredAuthTokens($0) },
            settleGrace: environment.retiredTokenSettleGrace
        )
        if let handler = Self.withPreInit({ Self.pendingAuthHandler }) {
            authStore.setHandler(handler)
        }
        if authStore.enabled {
            logger.info("SDK authentication enabled; attaching X-Joryio-Auth to ingest requests")
        }

        // Opt-out: persisted flag, a pre-init call, or config. MUST come after
        // `storage` is assigned - reading it earlier crashed every fresh launch.
        // An optOut() / optIn() made before init wins over the config: it is
        // explicit and later (contract v4, 45).
        let startOptedOut: Bool
        if let preInitDecision = Self.applyPreInitOptOut(to: self.storage, defaults: environment.defaults) {
            startOptedOut = preInitDecision
        } else {
            startOptedOut = self.storage.getOptedOut() || self.config.optOut
            // `optOut: true` at init is the same decision as optOut():
            // persisted, so it holds on a later launch that passes the
            // default config.
            if self.config.optOut { self.storage.setOptedOut(true) }
        }

        // Consent (SDK contract 24): an explicit choice wins and `denied` is
        // stored; with no explicit choice a stored `denied` stands.
        let preInitConsent = Self.withPreInit { Self.pendingConsent }
            ?? environment.defaults.string(forKey: Self.pendingConsentKey).flatMap(JoryioConfig.TrackingConsent.init(rawValue:))
        environment.defaults.removeObject(forKey: Self.pendingConsentKey)
        let explicitConsent = preInitConsent ?? self.config.trackingConsent
        let startConsent = Self.startConsent(
            preInit: preInitConsent,
            config: self.config.trackingConsent,
            storedDenied: self.storage.getConsentDenied()
        )
        if explicitConsent == .granted { self.storage.setConsentDenied(false) }
        if startConsent == .denied { self.storage.setConsentDenied(true) }
        locked {
            _isOptedOut = startOptedOut
            _consent = startConsent
        }
        if startOptedOut { logger.warn("User has opted out of tracking") }
        if startConsent != .granted { logger.info("Tracking consent is \(startConsent.rawValue)") }

        self.identity = IdentityManager(
            storage: storage,
            logger: logger,
            initialUserId: self.config.userId,
            initialAnonymousId: self.config.anonymousId
        )
        self.session = SessionManager(
            storage: storage,
            logger: logger,
            sessionTimeout: self.config.sessionTimeout
        )
        self.network = NetworkClient(
            sdkKey: sdkKey,
            apiEndpoint: self.apiEndpoint,
            logger: logger,
            maxRetries: self.config.maxRetries,
            retryBackoffMs: self.config.retryBackoffMs,
            requestTimeout: self.config.requestTimeout,
            authStore: authStore,
            sessionConfiguration: environment.sessionConfiguration
        )
        self.queue = QueueManager(
            storage: storage,
            sender: network,
            logger: logger,
            batchSize: self.config.batchSize,
            flushInterval: self.config.flushInterval,
            maxQueueSize: self.config.maxQueueSize,
            sendImmediately: self.config.sendImmediately
        )
        self.outbox = WriteOutbox(
            logger: logger,
            load: { [weak storage = self.storage] in storage?.readValue(forKey: Self.outboxStorageKey) ?? .unavailable },
            save: { [weak storage = self.storage] in storage?.setValue($0, forKey: Self.outboxStorageKey) },
            sender: { [weak network = self.network] path, body, userId in
                await network?.sendWrite(path: path, body: body, userId: userId) ?? .retry(retryAfter: nil, answered: false)
            }
        )
        let inAppConfig = self.config.inApp
        self.inAppMessaging = InAppMessagingManager(
            networkClient: network,
            storage: storage,
            identityManager: identity,
            sessionManager: session,
            logger: logger,
            allowHtmlJsInAppMessages: inAppConfig.allowHtmlJsInAppMessages,
            enabled: inAppConfig.enabled,
            syncInterval: inAppConfig.syncInterval,
            callbacks: InAppCallbacks(
                onMessageDisplay: inAppConfig.onMessageDisplay,
                onMessageClick: inAppConfig.onMessageClick,
                onMessageDismiss: inAppConfig.onMessageDismiss
            )
        )
        self.pushNotifications = PushNotificationManager(
            networkClient: network,
            identityManager: identity,
            storage: storage,
            logger: logger,
            inAppMessaging: inAppMessaging
        )

        // Route transport outcomes to `lastTransportError`. Set BEFORE any
        // task can use the network (scan 5, N2): they used to be assigned
        // after the pre-init wipe, the opt-out record and the permission
        // report had started requests - a write racing those reads.
        network.onTransportFailure = { [weak self] error in
            guard let self else { return }
            let unauthorized: Bool
            if let netError = error as? NetworkClient.NetworkError {
                switch netError {
                case .unauthorized, .sdkAuthError: unauthorized = true
                case .httpError(let code): unauthorized = code == 401 || code == 403
                default: unauthorized = false
                }
            } else {
                unauthorized = false
            }
            let transportError = JoryioTransportError(
                message: error.localizedDescription,
                isUnauthorized: unauthorized,
                isRetryable: self.network.isRetryable(error)
            )
            self.locked { self._lastTransportError = transportError }
        }
        network.onTransportSuccess = { [weak self] in
            guard let self else { return }
            self.locked { self._lastTransportError = nil }
        }

        // One gate, asked by every outbound path (SDK contracts 4 and 5).
        queue.canSend = { [weak self] in self?.canSend ?? false }
        queue.afterFlush = { [weak self] in self?.pruneRetiredTokens() }
        queue.currentUserId = { [weak self] in self?.identity.getUserId() }
        // For SDK authentication the "current" user is the one a withdrawal is
        // sent for (SDK contract v6, 63): a user kept while tracking is off
        // (D-b). Their unsubscribe refused with a 401 used to be dropped as
        // "a previous user's" without the app ever being asked for their
        // token. Nothing but withdrawals is sent while such a user is kept.
        network.currentUserId = { [weak self] in self?.identity.withdrawalUserId() }
        outbox.permits = { [weak self] entry in
            guard let self else { return false }
            // Withdrawals - the opt-out record, an unsubscribe, a push
            // unregister - are delivered whatever the opt-out or the consent
            // (contract v4, 36). Everything else waits for both.
            if !entry.isCollection { return self.isInitialized }
            return self.canSend
        }
        outbox.currentUserId = { [weak self] in self?.identity.withdrawalUserId() }
        outbox.resolve = { [weak self] entry in self?.resolveIds(of: entry) ?? entry }
        outbox.flushEvents = { [weak self] in await self?.queue.flush(force: true) }
        outbox.onSettled = { [weak self] entry, stored in self?.outboxEntrySettled(entry, stored: stored) }
        inAppMessaging.canSync = { [weak self] in self?.canSend ?? false }
        pushNotifications.canRegister = { [weak self] in self?.canSend ?? false }
        pushNotifications.canReport = { [weak self] in self?.canSend ?? false }
        pushNotifications.onUnregisterSettled = { [weak self] in self?.pruneRetiredTokens() }

        if environment.systemIntegration {
            // Become the notification-center delegate WITHOUT discarding the
            // app's: non-Joryio notifications and the callbacks we do not
            // handle are forwarded to it (PushNotificationManager's delegate
            // extension).
            let center = UNUserNotificationCenter.current()
            if let existing = center.delegate, !(existing is PushNotificationManager) {
                pushNotifications.previousDelegate = existing
            }
            center.delegate = pushNotifications
        } else {
            queue.usesBackgroundTask = false
            pushNotifications.unregisterWithOS = {}
        }

        isInitialized = true

        // Consent denied, or opted out, at launch: nothing collected, nothing
        // left over from an earlier run either.
        if startConsent == .denied || startOptedOut {
            discardCollectedData(owesSessionStart: true)
        }

        // A launch that continues an unexpired session sends no Session Start
        // (SDK contract 32): that session was announced when it began.
        // A session a runtime wipeData() started, not announced before the
        // app was closed, is announced now (scan 7, S1; contract v7, 75).
        var announceSession = !session.resumedAtLaunch
            || environment.defaults.bool(forKey: Self.sessionStartDueKey)
        if !self.config.trackSessionStart {
            environment.defaults.removeObject(forKey: Self.sessionStartDueKey)
        }

        // A user held (D-b) at the last launch: a token on standby for
        // them is theirs (contract v9, 89), as at the held identify().
        if let held = identity.getHeldUserId() {
            authStore.clearStandby(forUser: held)
        }

        // A wipeData() made before init - BEFORE any side effect below
        // (SDK contract 25).
        if environment.defaults.bool(forKey: Self.pendingWipeKey) {
            environment.defaults.removeObject(forKey: Self.pendingWipeKey)
            runCallsMadeBeforeTheWipe()
            // The token supplied for this launch (config or a pre-init
            // setter) is the next user's, not the erased one's: kept through
            // the wipe (contract 84, v9 89). Filed as standby and then
            // dropped, the user signed in right after init had none (scan 9, S1).
            wipeKeepsToken = authStore.currentToken()
            wipeData()
            wipeKeepsToken = nil
            announceSession = true
        }

        // A Session Start an earlier launch owed (consent denied or opted
        // out then) is announced by the first launch allowed to collect
        // (contract v8, 85) - as a NEW session, like releaseOwedSessionStart:
        // the resumed one may have been announced before a runtime opt-out.
        // Still not allowed: owed again, in memory and in defaults.
        if environment.defaults.bool(forKey: Self.sessionStartOwedKey) {
            if !self.config.trackSessionStart {
                environment.defaults.removeObject(forKey: Self.sessionStartOwedKey)
            } else if canCollect {
                if !announceSession {
                    session.resetSession()
                    announceSession = true
                }
            } else {
                locked { _sessionStartOwed = true }
            }
        }

        // The opt-out record follows the opt-out, including a decision made
        // in the config or before init (SDK contract 33).
        syncOptOutMarker()

        // An in-app callback set before init.
        if let pending = Self.withPreInit({ Self.pendingInAppCallback }) {
            setInAppMessageCallback(pending.callback, capabilities: pending.capabilities)
        }
        Self.withPreInit {
            Self.pendingAuthToken = nil
            Self.pendingAuthHandler = nil
            Self.pendingConsent = nil
            Self.pendingInAppCallback = nil
        }

        // Report the permission state now the SDK is live.
        Task { await reportPushPermissionIfChanged() }

        // Recover a device token the OS delivered before we existed.
        registerPendingDeviceTokenIfAny()

        // Opt-in auto-prompt (off by default; see the config's doc).
        if self.config.requestPushPermissionAtLaunch, environment.systemIntegration {
            logger.info("requestPushPermissionAtLaunch is on; asking now")
            Task { _ = await self.requestPushPermission() }
        }

        // Find JoryioUI if it is linked. InAppPresenterDiscoveryTests asserts
        // the lookup; this call is what makes it matter.
        #if canImport(UIKit)
        if inAppPresenter == nil {
            inAppPresenter = discoverInAppPresenter()
        }
        #endif

        // An identify() held while tracking was not allowed (D-b) runs now if
        // it may: BEFORE the Session Start, which belongs to that user (SDK
        // contract v6, 63 - it went out under the previous identity), and
        // before the calls made before init, which came later.
        releaseHeldIdentifyIfAllowed(atInit: true)

        // BEFORE the replayed pre-init calls: Session Start opens the session
        // their events belong to (SDK contract 32). It used to go through the
        // pre-init buffer itself and land after them.
        if self.config.trackSessionStart && announceSession {
            trackSessionStartEvent()
        }

        // Setup lifecycle observers
        setupLifecycleObservers()

        // Writes left over from the last run - identify, aliases, subscription
        // changes, the opt-out record, push unregisters - go out now.
        outbox.kick()
        pushNotifications.retryPendingUnregisters()

        // Sync in-app campaigns for this SESSION START. willEnterForeground
        // does NOT fire on a cold launch, so without this a killed-and-reopened
        // app never fetched campaigns.
        Task { [weak self] in
            await self?.inAppMessaging.syncCampaigns()
        }

        logger.info("SDK initialized successfully")

        // Retired tokens whose user has nothing left on the device (D-a).
        pruneRetiredTokens()

        // LAST: the calls the app made before initialize(), in order, now that
        // consent, opt-out and the identity are all in place.
        drainPreInitCalls()
    }

    /// The key or the host was refused: answer what is waiting on a callback.
    private func initializationFailed() {
        locked { _initFailed = true }
        settleBufferedCallsAfterFailedInit()
    }

    private var initFailed: Bool { locked { _initFailed } }

    /// Where the write outbox is persisted (StorageManager key-value table).
    static let outboxStorageKey = "write_outbox"

    /// Has the device been unlocked since it started? See the class doc and
    /// `KeychainHelper.isProtectedDataAvailable()`: the same Keychain probe on
    /// every thread, never `UIApplication.isProtectedDataAvailable` (false
    /// whenever the screen is locked - scan 4, finding 1).
    private func isProtectedDataAvailable(sdkKey: String) -> Bool {
        KeychainHelper(sdkKey: sdkKey, secItemCalls: environment.secItemCalls ?? .system).isProtectedDataAvailable()
    }

    private func deferInitialization(sdkKey: String, apiHost: String, config: JoryioConfig?) {
        print(
            "[Joryio] The device has not been unlocked since it started, so the SDK's storage "
                + "cannot be read yet. initialize() finishes when it is unlocked; calls made "
                + "meanwhile are queued."
        )
        let observer = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resumeDeferredInitialization()
        }
        locked {
            _deferredInit = (sdkKey, apiHost, config)
            _deferredInitObserver = observer
        }
        // The unlock may have happened between the check and the observer
        // being registered - its notification is then never seen. Ask again.
        if isProtectedDataAvailable(sdkKey: sdkKey) {
            resumeDeferredInitialization()
        }
    }

    /// Finish an initialize() that waited for protected data.
    func resumeDeferredInitialization() {
        let (pending, observer) = locked { () -> ((sdkKey: String, apiHost: String, config: JoryioConfig?)?, NSObjectProtocol?) in
            let p = _deferredInit
            let o = _deferredInitObserver
            _deferredInit = nil
            _deferredInitObserver = nil
            return (p, o)
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        guard let pending else { return }
        initialize(sdkKey: pending.sdkKey, apiHost: pending.apiHost, config: pending.config)
    }

    /// Diagnostics for tests.
    var isInitializationDeferredForTesting: Bool { isInitializationPending }

    /**
     True while `initialize()` was accepted and is waiting for the device to
     be unlocked for the first time since it started (see the class doc).
     Not a failure: the SDK starts by itself on the unlock, and every call
     made meanwhile is queued. A bridge (React Native, Unity) reports such
     an initialize() as successful.
     */
    public var isInitializationPending: Bool { locked { _deferredInit != nil } }

    /// Diagnostics and test seams.
    var writeOutboxForTesting: WriteOutbox? { outbox }

    // MARK: - Event Tracking

    /// Track a custom event. Safe before `initialize()`: queued and sent when
    /// the SDK starts.
    ///
    /// An event the server could never accept is dropped here with a log
    /// line (SDK contract 29): a name of 1-255 characters (spaces count, as
    /// on the server), and properties of at most 50 KB serialized, 200
    /// top-level keys and 5 levels of nesting.
    public func track(_ eventName: String, properties: EventProperties = [:]) {
        guard runNowOrQueue({ $0.track(eventName, properties: properties) }) else { return }

        // NaN and +/-Infinity are not JSON: such a key is dropped with a
        // warning and the event goes ahead (SDK contract v5, 49). It used to
        // make the whole event fail to encode, and be lost.
        var dropped: [String] = []
        let properties = FiniteValues.sanitized(properties, dropped: &dropped)
        if !dropped.isEmpty {
            logger.warn("Event '\(eventName.prefix(64))': dropped non-finite number(s) at \(dropped.joined(separator: ", "))")
        }

        // The name rule is the backend's isValidSdkEventName exactly: 1-255
        // characters, whitespace included - a name of spaces is stored by the
        // server, so it is not dropped here either (contract v4, 41).
        if let reason = Self.eventRejectionReason(name: eventName, properties: properties) {
            logger.error("Event '\(eventName.prefix(64))' dropped: \(reason). The server would refuse it.")
            return
        }

        guard canCollect else {
            logger.debug("Tracking not permitted (opted out or consent denied), skipping \(eventName)")
            return
        }

        // A session that timed out while the app sat open starts afresh here,
        // and announces itself BEFORE the event that started it.
        let renewed = session.checkAndRenewSession()
        if renewed || takeSessionStartDue(), config.trackSessionStart, eventName != "Session Start" {
            trackSessionStartEvent()
        }

        record(eventName, properties: properties)
    }

    /// Queue one event under the current ids, and show anything it triggers.
    /// No buffer, no session check: track() and the Session Start path
    /// have done both.
    private func record(_ eventName: String, properties: EventProperties) {
        let event = Event(
            type: eventName,
            properties: properties,
            timestamp: Date(),
            userId: identity.getUserId(),
            anonymousId: identity.getAnonymousId(),
            sessionId: session.getSessionId()
        )

        queue.enqueue(event)

        logger.debug("Event tracked: \(eventName)")

        // Show anything waiting on this event - locally, no round trip. AFTER
        // the event is queued: the event is data and must be recorded whether
        // or not it triggers a message.
        inAppMessaging?.onEventTracked(eventName, properties: properties)
    }

    // MARK: Event limits - the backend's, published in its batch contract

    static let maxEventNameLength = 255
    static let maxPropertyJsonChars = 51_200
    static let maxPropertyKeys = 200
    static let maxPropertyDepth = 5

    /// Why the server would refuse this event for good, or nil. Exactly the
    /// backend's rule (validate-event-properties.util.ts / SDK_EVENT_LIMITS):
    /// a name of 1-255 characters; at most 200 TOP-LEVEL keys; nesting where
    /// the properties object is level 1 and only objects/arrays go one level
    /// deeper (a plain value never adds a level); JSON at most 51,200
    /// characters (UTF-16 code units, as JavaScript's String.length counts).
    /// Stricter than the server here would drop events it accepts.
    static func eventRejectionReason(name: String, properties: EventProperties) -> String? {
        let nameLength = name.utf16.count
        if nameLength == 0 || nameLength > maxEventNameLength {
            return "the name must be 1-\(maxEventNameLength) characters"
        }
        if properties.count > maxPropertyKeys {
            return "properties have more than \(maxPropertyKeys) top-level keys"
        }
        func tooDeep(_ value: Any, _ depth: Int) -> Bool {
            if depth > maxPropertyDepth { return true }
            let value = unwrapped(value)
            let children: [Any]
            if let dict = value as? [String: Any] { children = Array(dict.values) }
            else if let array = value as? [Any] { children = array }
            else { return false }
            for child in children {
                let child = unwrapped(child)
                if child is [String: Any] || child is [Any] {
                    if tooDeep(child, depth + 1) { return true }
                }
            }
            return false
        }
        if tooDeep(properties as [String: Any], 1) {
            return "properties nest deeper than \(maxPropertyDepth) levels"
        }
        // Measured like JSON.stringify on the server: no escaping it does not
        // do. JSONEncoder writes `/` as `\/` by default, so a property full of
        // URLs measured larger than the server counts it and was dropped
        // while the server would have taken it (contract v4, 41).
        let encoder = WireJSON.encoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        if let data = try? encoder.encode(properties.mapValues { AnyCodable($0) }),
           let json = String(data: data, encoding: .utf8),
           json.utf16.count > maxPropertyJsonChars {
            return "properties are larger than 50 KB"
        }
        return nil
    }

    /// Track a screen view
    public func trackScreen(_ screenName: String, properties: EventProperties = [:]) {
        var props = properties
        props["screen_name"] = screenName
        track("Screen Viewed", properties: props)
    }

    // MARK: - User Identification

    /// Identify a user.
    ///
    /// Binds the device's anonymous history to `userId` on the server,
    /// re-registers the push token under the user, and re-syncs in-app
    /// messages for them. Safe before `initialize()`.
    public func identify(_ userId: String) {
        guard runNowOrQueue({ $0.identify(userId) }, keptWhileRefused: true) else { return }

        guard !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warn("identify() needs a non-empty user id; ignored")
            return
        }

        guard canCollect else {
            // Owner decision D-b: kept on the device, and used ONLY so an
            // unsubscribe, the opt-out record or a push unregister carries
            // the right user. No request, no event, no profile write. When
            // tracking is allowed again the normal identify runs.
            if isInitialized {
                // The session's token belongs to whoever was here before; it
                // goes with their leftovers, as at an account switch, so this
                // user's withdrawals never carry it (SDK contract v6, 63).
                authStore.retireTokenOnSwitch(outgoing: identity.withdrawalUserId(), incoming: userId)
                identity.holdUserId(userId)
                // A token kept on standby for this user (set before a
                // reset()) is theirs now: bound to their withdrawals, never
                // dropped at wipeData() as someone else's (contract v9, 89;
                // scan 9, B1).
                authStore.clearStandby(forUser: userId)
                logger.debug("Tracking not permitted: the user id is kept on the device for withdrawals only")
            }
            return
        }

        // A DIFFERENT user without reset() in between - an account switch -
        // is reset-then-identify for the token and the unsent attribute
        // writes (SDK contract v5, 53): the previous user's go out under
        // their own ids, with their own token. They used to go out as the
        // NEW user (`plan` of one person written on another's profile), and
        // their queued events were sent with the new user's token, refused,
        // and dropped.
        if let previous = identity.getUserId(), previous != userId {
            handOverPreviousUser(previous, to: userId)
        }

        identity.identify(userId: userId)

        // A token kept for this user - set for them before a reset(), or
        // theirs from an earlier logout - is the session's again when the
        // session holds none (scan 7, N1): their requests used to go out with
        // no token although theirs was right there.
        authStore.adoptRetired(forUser: userId)

        // A sync already in flight, and a display waiting on its delay, were
        // for the previous identity (SDK contract 26, v4 43).
        inAppMessaging.invalidate()

        // Re-register the stored device token against the new identity so a
        // token first captured while anonymous becomes bound to this user.
        pushNotifications.reregisterDeviceToken()

        // The anonymous id is read NOW, so the server merges the history of
        // the visitor who was actually here. After reset() it is the NEW id
        // (reset is synchronous - SDK contract 16).
        let request = IdentifyRequest(userId: userId, anonymousId: identity.getAnonymousId(), attributes: [:])
        enqueueWrite(.identify, path: "/v1/identify", request, userId: userId, anonymousId: request.anonymousId)
        // No client `$identify` event (SDK contract v5, 59): the server
        // records one for every /v1/identify, with the attributes and app
        // fields. iOS alone sent its own as well, so every iOS identify
        // counted twice.
    }

    /**
     identify() of a different user while `previous` was identified: what
     `previous` left unsent is sent under their ids, and their token is
     retired to their queued items, as reset() does (contract v5, 53).

     The token is retired only when it is not already the NEW user's: an
     app that sets the next user's token before calling identify() keeps it.
     */
    private func handOverPreviousUser(_ previous: String, to next: String) {
        cancelAttributeFlush()
        let inFlight: PendingAttributeSnapshot? = withAttributeFlushLock { inFlightAttributes }
        let unsent = identity.pending.takeForHandOff(excluding: inFlight)
        withAttributeFlushLock { handedOverGeneration = unsent.generation }
        enqueueAttributeHandOff(unsent, userId: previous, anonymousId: identity.getAnonymousId())
        identity.clearTraitBag()
        authStore.retireTokenOnSwitch(outgoing: previous, incoming: next)
    }

    /// Attribute writes of a previous identity, as durable outbox writes
    /// under that identity's ids (chunked to the server's per-request unset
    /// limit).
    private func enqueueAttributeHandOff(_ snapshot: PendingAttributeSnapshot, userId: String?, anonymousId: String) {
        guard !snapshot.isEmpty else { return }
        var unsetChunks = stride(from: 0, to: snapshot.unsets.count, by: PendingAttributes.maxUnsetsPerRequest).map {
            Array(snapshot.unsets[$0..<min($0 + PendingAttributes.maxUnsetsPerRequest, snapshot.unsets.count)])
        }
        if unsetChunks.isEmpty { unsetChunks = [[]] }
        for (index, unsets) in unsetChunks.enumerated() {
            let first = index == 0
            let request = SetAttributesRequest(
                userId: userId,
                anonymousId: anonymousId,
                attributes: first && !snapshot.sets.isEmpty ? snapshot.sets : nil,
                increment: first && !snapshot.increments.isEmpty ? snapshot.increments : nil,
                unset: unsets.isEmpty ? nil : unsets
            )
            enqueueWrite(.attributes, path: "/v1/attributes", request, userId: userId, anonymousId: anonymousId)
        }
        logger.debug("Unsent attribute writes of the previous user queued under their own ids")
    }

    /// Attach a labelled alias - a second identifier for the same person, such
    /// as a loyalty number or a CRM id - to the current profile.
    ///
    /// Works for anonymous visitors too: the alias lands on the anonymous
    /// profile and follows it when the person is identified. Safe before
    /// `initialize()`.
    /// - Parameters:
    ///   - label: lowercase letters, digits and underscores, e.g. `loyalty_id`.
    ///   - name: the alias value, e.g. `L-12345`.
    public func addAlias(_ label: String, name: String) {
        guard runNowOrQueue({ $0.addAlias(label, name: name) }) else { return }
        guard canCollect else {
            logger.debug("Tracking not permitted, skipping addAlias")
            return
        }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, !trimmedName.isEmpty else {
            logger.warn("addAlias needs a non-empty label and name; ignored")
            return
        }

        let userId = identity.getUserId()
        let anonymousId = identity.getAnonymousId()
        enqueueWrite(.alias, path: "/v1/alias/add", AddAliasRequest(
            anonymousId: anonymousId,
            userId: userId,
            aliasLabel: trimmedLabel,
            aliasName: trimmedName
        ), userId: userId, anonymousId: anonymousId)
    }

    // MARK: - Requests that must reach the server

    /// identify, addAlias, the subscription calls and the opt-out record: one
    /// request each, which the server must receive. They go through the write
    /// outbox (SDK contract 28): persisted until the server acknowledges them,
    /// kept across restarts AND across reset() - each carries the ids it was
    /// made under - and sent in order. While consent is pending they wait
    /// there. They used to sit in a memory-only list that reset() emptied
    /// (scan 3, S3).
    private func enqueueWrite<T: Encodable>(
        _ kind: OutboxEntry.Kind,
        path: String,
        _ request: T,
        userId: String?,
        anonymousId: String?,
        markerValue: Bool? = nil,
        withdrawal: Bool = false,
        supersedeKey: String? = nil,
        alsoReplacing anonymousKey: String? = nil
    ) {
        let encoder = WireJSON.encoder()
        guard let data = try? encoder.encode(request), let body = String(data: data, encoding: .utf8) else {
            logger.error("Could not encode a \(kind.rawValue) write; dropped")
            return
        }
        outbox.add(OutboxEntry(
            kind: kind,
            path: path,
            body: body,
            userId: userId,
            markerValue: markerValue,
            anonymousId: anonymousId,
            withdrawal: withdrawal,
            supersedeKey: supersedeKey
        ), alsoReplacing: anonymousKey)
        outbox.kick()
    }

    /**
     The ids a write is SENT under (contract v4, 38).

     A write made while anonymous - a newsletter signup before the account
     exists - and sent after identify() used to carry the anonymous id only.
     With SDK authentication the server refuses that for an identified
     profile (403 `SDK_ANONYMOUS_ID_IDENTIFIED`), and the write was dropped.
     Now, while the anonymous id it was made under is still this device's,
     it goes out under the current user. A write from a previous identity
     (the anonymous id changed with reset() or wipeData()) keeps its own ids.
     */
    private func resolveIds(of entry: OutboxEntry) -> OutboxEntry {
        guard entry.userId == nil,
              let captured = entry.anonymousId,
              captured == identity.getAnonymousId(),
              let userId = identity.getUserId(),
              var json = (try? JSONSerialization.jsonObject(with: Data(entry.body.utf8))) as? [String: Any]
        else { return entry }
        json["userId"] = userId
        // Subscriptions carry ONE identifier, never both (the rule every SDK
        // follows for them).
        if entry.kind == .subscription { json.removeValue(forKey: "anonymousId") }
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let body = String(data: data, encoding: .utf8)
        else { return entry }
        return entry.sendingAs(userId: userId, body: body)
    }

    /// An outbox write left the outbox - stored, or dropped.
    private func outboxEntrySettled(_ entry: OutboxEntry, stored: Bool) {
        switch entry.kind {
        case .identify:
            // The audience just changed; what this person should see did too.
            Task { [weak self] in await self?.inAppMessaging.syncCampaigns(force: true) }
        case .optOutMarker:
            // Dropped (refused, or out of attempts): the next opt-out change
            // or launch tries again - re-queueing here would loop.
            guard stored, let value = entry.markerValue else { return }
            // A logged-out user's marker landing says nothing about THIS
            // person's record (contract v7 74, as on Android).
            guard entry.anonymousId == identity.getAnonymousId() else { break }
            storage.setOptOutMarkerAcked(value)
            // The opt-out may have changed again while this was in flight.
            syncOptOutMarker()
        case .alias, .subscription, .pushUnregister, .attributes:
            break
        }
        pruneRetiredTokens()
    }

    /// Users with a withdrawal still queued - an unsubscribe, the opt-out
    /// record, a push unregister.
    private func queuedWithdrawalUserIds() -> Set<String> {
        let writes = outbox?.snapshot().filter { !$0.isCollection } ?? []
        let unregisters = pushNotifications?.unregisterOutbox.snapshot() ?? []
        return Set((writes + unregisters).compactMap(\.userId))
    }

    /// Set by initialize() only, around the pre-init wipe it runs: the token
    /// supplied for this launch, which that wipe must not drop as standby
    /// (scan 9, S1). Nil for every wipeData() the app makes.
    private var wipeKeepsToken: String?

    /**
     Forget each retired SDK-authentication token whose user has nothing left
     on the device - no outbox write, no push unregister, no queued event
     (owner decision D-a). Called when a write settles and after each event
     flush.
     */
    func pruneRetiredTokens() {
        guard let authStore, let storage, let outbox else { return }
        let users = authStore.retiredUserIds
        guard !users.isEmpty else { return }
        let pushEntries = pushNotifications?.unregisterOutbox.snapshot() ?? []
        let outboxUsers = Set((outbox.snapshot() + pushEntries).compactMap(\.userId))
        // The user requests are made for now - identified, or held while
        // tracking is off (D-b) - keeps a token filed under them: a held
        // user's withdrawals carry it (SDK contract v7, 72).
        let current = identity?.withdrawalUserId()
        authStore.pruneRetired { user in
            user == current || outboxUsers.contains(user) || storage.hasQueuedEvents(forUserId: user)
        }
    }

    /**
     Make the `tracking_opted_out` profile record follow the opt-out (SDK
     contract 33).

     Sent when the opt-out differs from what the server last acknowledged -
     including a decision made in the config or before init - retried until
     acknowledged, and not sent when nothing changed. The `false` record
     used to be best-effort (lost when offline), and an opt-out made at init
     never reached the profile at all.
     */
    private func syncOptOutMarker() {
        guard isInitialized else { return }
        let desired = isOptedOut
        let acked = storage.getOptOutMarkerAcked()
        let userId = identity.withdrawalUserId()
        let anonymousId = identity.getAnonymousId()
        let signedIn = identity.getUserId()
        // Only THIS person's markers (contract v7 74, same on Android and
        // web): a logged-out user's queued marker keeps its own ids and is
        // delivered - replacing it (optOut, reset, optIn) lost their "no".
        func isThisPerson(_ e: OutboxEntry) -> Bool {
            e.kind == .optOutMarker && e.anonymousId == anonymousId
                && (e.userId == nil || e.userId == signedIn || e.userId == userId)
        }
        let queued = outbox.snapshot().filter(isThisPerson)
        // Already on its way.
        if queued.last?.markerValue == desired { return }
        outbox.removeAll(where: isThisPerson)
        guard desired != acked else { return }
        enqueueWrite(.optOutMarker, path: "/v1/attributes", SetAttributesRequest(
            userId: userId,
            anonymousId: anonymousId,
            attributes: Self.optOutRecord(desired)
        ), userId: userId, anonymousId: anonymousId, markerValue: desired)
    }

    /// The profile record of the opt-out: `true` on optOut(), and `false`
    /// again on optIn() - the decision is reversible on the profile too.
    static func optOutRecord(_ optedOut: Bool) -> UserAttributes {
        optedOut ? ["tracking_opted_out": true] : ["tracking_opted_out": false]
    }

    /// Resend what the outbox holds. Called on foreground and when sending
    /// resumes.
    private func retryOwedRequests(force: Bool = false) {
        outbox.kick(force: force)
        pushNotifications.retryPendingUnregisters(force: force)
    }

    /// Transient failures and the server's `success: false` are retried
    /// later; a request the server refuses as invalid (4xx) is not.
    static func isWorthRetryingLater(_ error: Error) -> Bool {
        guard let netError = error as? NetworkClient.NetworkError else {
            return true // offline, timeout, DNS
        }
        switch netError {
        case .serverRejected, .rateLimited, .unknown, .sdkAuthError:
            return true
        case .httpError(let code):
            return code >= 500 || code == 408
        case .unauthorized, .invalidURL, .invalidResponse:
            return false
        }
    }

    /// Reset user identity (on logout).
    ///
    /// A NEW anonymous id, no user id, no pending attribute writes or timers,
    /// no in-app state, and a new session announced with a Session Start; the
    /// push token is re-registered under the new anonymous identity and in-app
    /// messages re-sync (SDK contract 6).
    ///
    /// The identity changes SYNCHRONOUSLY, before anything else (SDK contract
    /// 16): an `identify()` on the very next line uses the new anonymous id.
    /// Queued events go out afterwards - each carries the ids it was tracked
    /// under - as does every identify, alias and subscription change still
    /// waiting to reach the server. Safe before `initialize()`.
    public func reset() {
        guard runNowOrQueue({ $0.reset() }, purgeable: false) else { return }

        logger.info("Resetting SDK state")

        cancelAttributeFlush()

        // The token belonged to the user who just left (contract v4, 39): the
        // session forgets it, but it stays bound to that user so their own
        // queued events and writes still go out authenticated - clearing it
        // made every normal logout drop the user's last events. Read the
        // outgoing user BEFORE the identity changes. A refusal of their
        // leftovers is still dropped without asking the app for a token.
        // A user held while tracking is off (D-b) is the outgoing one too:
        // their withdrawals are queued and their token is theirs, not a
        // standby token for someone signing in next (contract v8, 82).
        authStore.retireToken(forUser: identity.withdrawalUserId())

        identity.reset()
        session.resetSession()

        // The next user never sees the previous user's campaigns, and nothing
        // scheduled for the previous user fires.
        inAppMessaging.clear()

        // Now send what the outgoing identity left queued.
        queue.flushSync()

        // Re-associate the device token with the fresh anonymous identity.
        pushNotifications.reregisterDeviceToken()

        // A new session began; say so, exactly as a timed-out session does.
        if config.trackSessionStart {
            trackSessionStartEvent()
        }

        Task { [weak self] in
            await self?.inAppMessaging.syncCampaigns(force: true)
        }

        logger.info("SDK state reset complete")
    }

    // MARK: - User Attributes

    /// A value the host meant as "no value": `nil` inside `Any`, or `NSNull`
    /// from a bridge. Such a value UNSETS the attribute (SDK contract 19), the
    /// same on every platform - it used to be sent as JSON null on iOS.
    static func isNullValue(_ value: Any) -> Bool {
        if value is NSNull { return true }
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional && mirror.children.isEmpty
    }

    /// `Optional(x)` boxed in `Any` becomes `x`.
    static func unwrapped(_ value: Any) -> Any {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional, let child = mirror.children.first {
            return unwrapped(child.value)
        }
        return value
    }

    /// Set multiple user attributes. A `nil` or `NSNull` value removes the
    /// attribute. Safe before `initialize()`.
    public func setAttributes(_ attributes: UserAttributes) {
        guard runNowOrQueue({ $0.setAttributes(attributes) }) else { return }

        guard canCollect else {
            logger.debug("Tracking not permitted, skipping setAttributes")
            return
        }

        var sets: UserAttributes = [:]
        var unsets: [String] = []
        for (key, raw) in attributes {
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                logger.warn("An attribute with an empty key was ignored")
                continue
            }
            if Self.isNullValue(raw) {
                unsets.append(key)
            } else {
                sets[key] = Self.unwrapped(raw)
            }
        }
        // A non-finite number (NaN, +/-Infinity) is dropped with a warning,
        // the rest goes ahead (SDK contract v5, 49). One used to make every
        // flush of the pending set fail to encode, so no later attribute
        // write reached the server either.
        var dropped: [String] = []
        sets = FiniteValues.sanitized(sets, dropped: &dropped)
        if !dropped.isEmpty {
            logger.warn("Attribute value(s) dropped - not a finite number: \(dropped.joined(separator: ", "))")
        }
        guard !sets.isEmpty || !unsets.isEmpty else { return }

        if !sets.isEmpty {
            identity.setAttributes(sets)
            // Not acknowledged until the server says so. Recorded BEFORE the
            // attempt so a failure needs no special handling.
            identity.pending.mark(sets)
        }
        for key in unsets {
            identity.unsetAttribute(key)
            identity.pending.markUnset(key)
        }

        inAppMessaging?.attributesDidChange(Array(sets.keys) + unsets)

        scheduleAttributeFlush()
    }

    private var attributeFlushTask: Task<Void, Never>? {
        get { locked { _attributeFlushTask } }
        set { locked { _attributeFlushTask = newValue } }
    }

    private func cancelAttributeFlush() {
        let task: Task<Void, Never>? = locked {
            let t = _attributeFlushTask
            _attributeFlushTask = nil
            return t
        }
        task?.cancel()
    }

    /**
     Coalesce a burst of writes into one request.

     A debounce rather than a fixed interval: a single write still goes out
     promptly, and only a burst is held. The foreground and consent paths flush
     IMMEDIATELY, bypassing this.

     A new write cancels only the debounce SLEEP. The flush itself runs in its
     own task, which nothing cancels: it used to run inside the debounce task,
     so a write made while a request was in flight cancelled THAT REQUEST - the
     server had often applied it already, the SDK saw a cancellation and kept
     the values, and the next flush sent the same `$inc` again. A counter
     bumped twice in quick succession was counted three times.
     */
    private func scheduleAttributeFlush() {
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.attributeFlushDebounceMs * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            Task { await self.flushPendingAttributes() }
        }
        let previous: Task<Void, Never>? = locked {
            let p = _attributeFlushTask
            _attributeFlushTask = task
            return p
        }
        previous?.cancel()
    }

    /**
     Send everything the server has not acknowledged - sets, increments and
     unsets - and clear what it took.

     Retried rather than dropped: a failure leaves the values queued, and the
     next trigger (another write, foreground, consent granted) picks them up.
     A write the server refuses as INVALID (400 / 413 / 422) is split and the
     halves resent, so one bad key cannot hold every later write hostage; a
     single operation still refused is dropped with a log line - the same rule
     as an event batch (SDK contract 3).
     */
    func flushPendingAttributes() async {
        guard canSend else { return }

        // Serialize + coalesce: a request arriving mid-flight sets a flag
        // instead, and one follow-up flush covers everything it added.
        let claimed: Bool = withAttributeFlushLock {
            if isFlushingAttributes {
                flushAgainRequested = true
                return false
            }
            isFlushingAttributes = true
            return true
        }
        guard claimed else { return }

        defer {
            let again: Bool = withAttributeFlushLock {
                isFlushingAttributes = false
                let again = flushAgainRequested
                flushAgainRequested = false
                return again
            }
            if again { Task { await flushPendingAttributes() } }
        }

        // More than one request only when the unsets exceed what the server
        // takes per request; bounded so nothing can spin.
        for _ in 0..<10 {
            let snapshot = identity.pending.snapshot()
            guard !snapshot.isEmpty, canSend else { return }
            let userId = identity.getUserId()
            let anonymousId = identity.getAnonymousId()
            withAttributeFlushLock { inFlightAttributes = snapshot }
            let resolved = await sendAttributes(snapshot, userId: userId, anonymousId: anonymousId)
            withAttributeFlushLock { inFlightAttributes = nil }
            guard resolved else {
                // Failed while the app switched to another user: these values
                // are no longer in the pending set (they were handed over minus
                // this request), so they go to the outbox under the ids they
                // were sent with rather than being lost.
                if withAttributeFlushLock({ handedOverGeneration == snapshot.generation }) {
                    enqueueAttributeHandOff(snapshot, userId: userId, anonymousId: anonymousId)
                }
                return
            }
            logger.info("Attributes sent to server")
            guard snapshot.unsets.count >= PendingAttributes.maxUnsetsPerRequest else { return }
        }
    }

    /// Send one snapshot. True when it is resolved - accepted, or dropped as
    /// invalid - so the caller may go on.
    private func sendAttributes(_ snapshot: PendingAttributeSnapshot, userId: String?, anonymousId: String) async -> Bool {
        do {
            let request = SetAttributesRequest(
                userId: userId,
                anonymousId: anonymousId,
                attributes: snapshot.sets.isEmpty ? nil : snapshot.sets,
                increment: snapshot.increments.isEmpty ? nil : snapshot.increments,
                unset: snapshot.unsets.isEmpty ? nil : snapshot.unsets
            )
            try await network.setAttributes(request)
            // Clears only what is still exactly what was sent, so a write that
            // landed mid-flight stays pending.
            identity.pending.acknowledge(snapshot)
            return true
        } catch {
            if case NetworkClient.NetworkError.httpError(403) = error {
                // Refused by the identity policy: retrying it would block every
                // later attribute write for good (SDK contract 28).
                logger.error("Dropping an attribute write the server refused (403)")
                identity.pending.acknowledge(snapshot)
                return true
            }
            guard Self.isInvalidRequest(error) else {
                logger.error("Failed to send attributes, will retry: \(error.localizedDescription)")
                return false
            }
            if let (first, second) = snapshot.split() {
                guard await sendAttributes(first, userId: userId, anonymousId: anonymousId) else { return false }
                return await sendAttributes(second, userId: userId, anonymousId: anonymousId)
            }
            let keys = Array(snapshot.sets.keys) + Array(snapshot.increments.keys) + snapshot.unsets
            logger.error("Dropping an attribute write the server refused as invalid (\(keys.joined(separator: ", "))): \(error.localizedDescription)")
            identity.pending.acknowledge(snapshot)
            return true
        }
    }

    /// 400 / 413 / 422 and the other 4xx the server repeats forever - not
    /// 401/402/403 (credentials, suspension) or 408/429 (try again).
    static func isInvalidRequest(_ error: Error) -> Bool {
        guard case NetworkClient.NetworkError.httpError(let code) = error else { return false }
        return (400..<500).contains(code) && ![401, 402, 403, 408, 429].contains(code)
    }

    /// A plain function so the async flush never holds an NSLock across a
    /// suspension point.
    private func withAttributeFlushLock<T>(_ body: () -> T) -> T {
        flushLock.lock()
        defer { flushLock.unlock() }
        return body()
    }

    /// Set a single user attribute. `nil` removes it, like `unsetAttribute`.
    public func setAttribute(_ key: String, value: Any?) {
        setAttributes([key: value as Any])
    }

    /// Increment a numeric attribute.
    ///
    /// Sent as an atomic `$inc` DELTA (never a locally computed absolute), and
    /// queued like `setAttributes`: retried until the server acknowledges it,
    /// surviving offline periods and restarts. Safe before `initialize()`.
    public func incrementAttribute(_ key: String, by value: Double = 1.0) {
        guard runNowOrQueue({ $0.incrementAttribute(key, by: value) }) else { return }

        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warn("incrementAttribute() needs a key; ignored")
            return
        }

        guard value.isFinite else {
            logger.warn("incrementAttribute('\(key)') needs a finite number; ignored")
            return
        }

        guard canCollect else {
            logger.debug("Tracking not permitted, skipping incrementAttribute")
            return
        }

        // In-memory optimistic echo only (for in-session reads and thresholds).
        identity.incrementAttribute(key, by: value)
        identity.pending.markIncrement(key, by: value)
        inAppMessaging?.attributesDidChange([key])
        scheduleAttributeFlush()
    }

    /// Remove a user attribute - an atomic `$unset`, queued and retried like
    /// `setAttributes`. Safe before `initialize()`.
    public func unsetAttribute(_ key: String) {
        guard runNowOrQueue({ $0.unsetAttribute(key) }) else { return }

        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warn("unsetAttribute() needs a key; ignored")
            return
        }

        guard canCollect else {
            logger.debug("Tracking not permitted, skipping unsetAttribute")
            return
        }

        identity.unsetAttribute(key)
        identity.pending.markUnset(key)
        scheduleAttributeFlush()
    }

    // MARK: - Privacy Controls

    // The opt-out is recorded on the profile as `tracking_opted_out`, the same
    // key on every SDK (SDK contract 14). No `$`: the backend drops
    // `$`-prefixed attribute keys, so the old `$tracking_opted_out` never
    // reached a profile and no segment could exclude on it.

    /// Opt out of tracking.
    ///
    /// Persists across launches until `optIn()`. Stops every write path -
    /// events, attributes (including increments and unsets), aliases,
    /// subscriptions, push registration and receipts, in-app impressions - and
    /// clears what was collected but not yet sent. The opt-out is recorded on
    /// the profile as `tracking_opted_out: true` (retried until the server
    /// has it). Does not change the tracking consent. Safe before
    /// `initialize()`: the choice is stored and applied before anything the
    /// SDK does at start.
    public func optOut() {
        guard isInitialized else {
            environment.defaults.set(true, forKey: Self.pendingOptOutKey)
            isOptedOut = true
            // Calls queued before this one collected data the person has now
            // withdrawn; they are dropped, as queued events are below. An
            // unregisterPush() or flush() is not collection and stays.
            purgeCollectingPreInitCalls()
            print("[Joryio] optOut() before initialize(): recorded, and applied when the SDK starts.")
            return
        }

        isOptedOut = true
        storage.setOptedOut(true)

        // Everything collected BEFORE consent was withdrawn but not yet sent is
        // dropped, not delivered later. A message waiting on its display
        // delay is not shown (v4, 43).
        discardCollectedData(owesSessionStart: true)
        inAppMessaging.invalidate()

        // The consent RECORD - not tracking: the only way the server learns
        // the person opted out on this device.
        syncOptOutMarker()

        logger.info("User opted out of tracking")
    }

    /// Drop everything collected but not yet sent. Used by opt-out, consent
    /// being denied and wipeData(). Withdrawals are kept and still delivered
    /// - the opt-out record, an unsubscribe, a group leave, a push unregister
    /// (contract v4, 36): they withdraw, they do not collect.
    ///
    /// `owesSessionStart`: this session's Session Start is discarded with the
    /// rest (it may sit in the queue unsent, consent pending), so when
    /// collection is allowed again a NEW session begins with its own - the
    /// same as Android. Consent pending -> denied -> granted used to leave
    /// that session with no Session Start at all (scan 4, M3).
    private func discardCollectedData(owesSessionStart: Bool) {
        cancelAttributeFlush()
        identity?.pending.clear()
        // A `push_permission` write discarded here never reached the server:
        // report it again when sending is allowed (scan 5, N6).
        storage?.clearReportedPushPermission()
        queue?.clearQueue()
        outbox?.removeAll { $0.isCollection }
        if owesSessionStart { markSessionStartOwed() }
    }

    /// A Session Start is owed: in memory for this launch, and in defaults
    /// for the next (contract v8, 85).
    private func markSessionStartOwed() {
        locked { _sessionStartOwed = true }
        if config?.trackSessionStart == true {
            environment.defaults.set(true, forKey: Self.sessionStartOwedKey)
        }
    }

    /**
     Delete everything this SDK has stored on the device (SDK contract 21).

     Erases the identity (user id, anonymous id), the event queue, pending
     attribute writes and identify / alias / subscription writes, in-app
     state, the session, the device id and the push token - and asks the
     server to unregister that token (retried until it answers), so nothing
     is sent to the erased install. KEEPS the opt-out and the stored consent:
     a person who opted out and then asked for their data to be deleted has
     not asked to be tracked again.

     Deliberately SEPARATE from optOut(): "stop collecting" and "delete what you
     already have" are different requests. This is the one an erasure request
     needs. Safe before `initialize()`: the wipe runs when the SDK starts,
     before anything else it does.
     */
    public func wipeData() {
        guard isInitialized else {
            environment.defaults.set(true, forKey: Self.pendingWipeKey)
            // What was queued before the wipe is erased with everything else -
            // except its withdrawals, which run before the wipe at init.
            purgeCollectingPreInitCalls(markingWipe: true)
            print("[Joryio] wipeData() before initialize(): recorded, and run when the SDK starts.")
            return
        }
        // Push FIRST: the server files the token under the identity being
        // erased, so the unregister has to carry it.
        pushNotifications.wipe()
        environment.defaults.removeObject(forKey: Self.pendingDeviceTokenKey)

        // The erased user's token, like at reset(): no longer the session's,
        // still bound to their withdrawals waiting in the outbox. It used to
        // stay current here, so the next anonymous visitor carried it (Android
        // already cleared it). The held (D-b) user's counts as theirs.
        // The erased user - the held (D-b) one included - read BEFORE the
        // identity is cleared: their own token stays for their withdrawals.
        let erasedUser = identity.withdrawalUserId()
        authStore.retireToken(forUser: erasedUser)
        // A standby token - set for someone who has not signed in here, with
        // nothing queued for them - serves no withdrawal of the person being
        // erased: forgotten with everything else (contract v8, 82). It used
        // to stay in the Keychain, and keep authentication on, for 30 days.
        // Kept: the erased user's own token even when it came through
        // standby (a held user's - scan 9, B1), a token whose user still
        // has a withdrawal queued, and the token supplied for this launch
        // (scan 9, S1). Contract v9, 89.
        let withdrawalUsers = queuedWithdrawalUserIds()
        authStore.dropStandby(keepingUser: erasedUser, keepingToken: wipeKeepsToken) { withdrawalUsers.contains($0) }

        discardCollectedData(owesSessionStart: false)
        storage.clearUserAttributes()
        storage.clearPendingAttributes()
        storage.clearSession()
        storage.setUserId(nil)
        storage.clearDeviceId()
        inAppMessaging.clear()
        // The anonymous id too, in storage AND in memory - it is the key the
        // erased profile was filed under. Clear storage first, then let the
        // identity manager mint the replacement.
        storage.clearAnonymousId()
        identity.onDataWiped()
        session.resetSession()
        // The new session is the new anonymous id's: announced by the next
        // event (or foreground), as Android does by ending the session. It
        // started silently - its Session Start, if one was queued, went with
        // the discarded data - so a Unity quiet start, which replays a
        // pre-init wipe through here, sent a whole first session without
        // one (scan 6, Unity S1).
        locked { _sessionStartDue = true }
        if config.trackSessionStart {
            environment.defaults.set(true, forKey: Self.sessionStartDueKey)
        }
        logger.info("Local SDK data wiped (opt-out kept)")
    }

    /// Opt back in to tracking. The ONLY call that lifts an opt-out - consent
    /// being granted does not (SDK contract 24). Safe before `initialize()`.
    public func optIn() {
        guard isInitialized else {
            environment.defaults.set(false, forKey: Self.pendingOptOutKey)
            isOptedOut = false
            print("[Joryio] optIn() before initialize(): recorded, and applied when the SDK starts.")
            return
        }

        let wasOptedOut = isOptedOut
        isOptedOut = false
        storage.setOptedOut(false)
        logger.info("User opted in to tracking")

        // Clear the record on the way back in, or a person who declined and
        // later accepted stays flagged forever. Only when it CHANGED.
        syncOptOutMarker()

        releaseHeldIdentifyIfAllowed()
        guard canSend else { return }
        guard wasOptedOut else {
            // Nothing was held back by an opt-out; still a good moment to
            // resend writes waiting on a failure.
            retryOwedRequests(force: true)
            return
        }
        inAppMessaging.invalidate()
        releaseOwedSessionStart()
        resumeSending()
    }

    /// Get current opt-out status. Reflects ONLY the opt-out switch
    /// (`optOut()` / `optIn()`), never the consent - see
    /// `getTrackingConsent()`.
    ///
    /// Before `initialize()` it answers from what is stored - an `optOut()` /
    /// `optIn()` made before init, else the persisted opt-out - never a
    /// default `false` while a stored opt-out exists (contract v4, 44).
    public func isUserOptedOut() -> Bool {
        guard isInitialized else {
            let defaults = environment.defaults
            if defaults.object(forKey: Self.pendingOptOutKey) != nil {
                return defaults.bool(forKey: Self.pendingOptOutKey)
            }
            return defaults.bool(forKey: StorageManager.optOutKey)
        }
        return isOptedOut
    }

    /// The tracking consent in effect: `granted`, `denied` or `pending`
    /// (SDK contract 24). Collection happens only when this is `granted` AND
    /// the person has not opted out. Safe before `initialize()`.
    ///
    /// Before `initialize()` it answers from what is stored (contract v4, 44):
    /// an `updateConsent(_:)` made before init, else a stored `denied`, else
    /// `granted` - and a `pending` never hides a stored `denied`.
    public func getTrackingConsent() -> JoryioConfig.TrackingConsent {
        guard isInitialized else {
            let defaults = environment.defaults
            let storedDenied = defaults.bool(forKey: StorageManager.consentDeniedKey)
            let preInit = Self.withPreInit({ Self.pendingConsent })
                ?? defaults.string(forKey: Self.pendingConsentKey).flatMap(JoryioConfig.TrackingConsent.init(rawValue:))
            switch preInit {
            case .granted?: return .granted
            case .denied?: return .denied
            case .pending?: return storedDenied ? .denied : .pending
            case nil: return storedDenied ? .denied : .granted
            }
        }
        return consent
    }

    /// Change tracking consent at runtime - typically from your consent banner.
    ///
    /// - `.granted`: everything held while consent was pending is sent
    ///   (events, attribute writes, identify, aliases, subscription changes,
    ///   the Session Start), push registers and in-app messages sync. Lifts a
    ///   stored `.denied`.
    /// - `.denied`: nothing more is collected, and what was held is discarded.
    ///   STORED: it holds across launches until `.granted` is given
    ///   explicitly (here, or `trackingConsent: .granted` in the config).
    /// - `.pending`: collect and hold, send nothing. For this launch only,
    ///   and ignored while `.denied` is stored.
    ///
    /// Opt-out is separate and wins: granting consent never lifts an opt-out
    /// (only `optIn()` does), and an opted-out user stays opted out whatever
    /// the consent. Safe before `initialize()`: applied before anything the
    /// SDK does at start.
    public func updateConsent(_ consent: JoryioConfig.TrackingConsent) {
        guard isInitialized else {
            // Pending never reopens a denial (contract v4, 45): denied - made
            // before init now, or stored - holds until `.granted`. Android
            // has always kept it; iOS let the pending replace it.
            //
            // A `.granted` made before init in this process (or kept from one
            // killed before it initialised) is newer than the stored denial
            // and already lifts it: then the pending replaces it, exactly as
            // on Android (scan 6, Unity S2). iOS ignored the pending, so a
            // Unity "quiet start" - pending first, the app's own consent
            // handed back after init - started GRANTED here and denied there.
            if consent == .pending {
                let explicit = Self.withPreInit({ Self.pendingConsent })
                    ?? environment.defaults.string(forKey: Self.pendingConsentKey).flatMap(JoryioConfig.TrackingConsent.init(rawValue:))
                let deniedNow = explicit == .denied
                    || (explicit == nil && environment.defaults.bool(forKey: StorageManager.consentDeniedKey))
                if deniedNow {
                    print("[Joryio] updateConsent(.pending) before initialize() ignored: consent is denied, and only .granted lifts that.")
                    return
                }
            }
            Self.withPreInit { Self.pendingConsent = consent }
            if consent == .pending {
                environment.defaults.removeObject(forKey: Self.pendingConsentKey)
            } else {
                environment.defaults.set(consent.rawValue, forKey: Self.pendingConsentKey)
            }
            if consent == .denied {
                purgeCollectingPreInitCalls()
            }
            return
        }
        if consent == .pending, storage.getConsentDenied() {
            logger.info("updateConsent(.pending) ignored: consent is denied, and only .granted lifts that")
            return
        }
        let previous = self.consent
        self.consent = consent
        logger.info("Tracking consent \(previous.rawValue) -> \(consent.rawValue)")
        if previous != consent { inAppMessaging.invalidate() }

        switch consent {
        case .denied:
            storage.setConsentDenied(true)
            discardCollectedData(owesSessionStart: true)
        case .pending:
            break
        case .granted:
            storage.setConsentDenied(false)
            releaseHeldIdentifyIfAllowed()
            // The opt-out record may have waited for consent.
            syncOptOutMarker()
            outbox.kick(force: true)
            guard canSend else { return }
            releaseOwedSessionStart()
            resumeSending()
        }
    }

    /// An identify() held while tracking was not allowed (D-b): once it is
    /// allowed again, the normal identify runs.
    ///
    /// `atInit`: called by initialize() itself, before its Session Start -
    /// the identify runs right there, ahead of the calls made before init.
    private func releaseHeldIdentifyIfAllowed(atInit: Bool = false) {
        guard canCollect, let held = identity.getHeldUserId() else { return }
        identity.clearHeldUserId()
        guard held != identity.getUserId() else { return }
        if atInit {
            bufferLock.lock()
            let previousReplayThread = replayThread
            replayThread = Thread.current
            bufferLock.unlock()
            identify(held)
            bufferLock.lock()
            replayThread = previousReplayThread
            bufferLock.unlock()
            return
        }
        // During initialize() the calls made before it are not replayed yet;
        // this identify is older than all of them, so it goes first.
        bufferLock.lock()
        if !preInitDrained, replayThread != Thread.current {
            preInitCalls.insert(({ $0.identify(held) }, true, nil), at: 0)
            bufferLock.unlock()
            return
        }
        bufferLock.unlock()
        identify(held)
    }

    /// A Session Start a runtime wipeData() left due, taken (once).
    private func takeSessionStartDue() -> Bool {
        locked {
            let due = _sessionStartDue
            _sessionStartDue = false
            return due
        }
    }

    /// The Session Start held back while sending was not allowed, sent now.
    private func releaseOwedSessionStart() {
        let owed: Bool = locked {
            let owed = _sessionStartOwed
            _sessionStartOwed = false
            return owed
        }
        if owed, config.trackSessionStart {
            // A NEW session: the one whose Session Start was discarded (or
            // never collected) is not resumed with a second one.
            session.resetSession()
            trackSessionStartEvent()
        } else if !config.trackSessionStart {
            environment.defaults.removeObject(forKey: Self.sessionStartOwedKey)
        }
    }

    /// Everything that was held back, released: used by opt-in and by
    /// consent being granted.
    private func resumeSending() {
        queue.resetBackoff()
        queue.flushSync(force: true)
        retryOwedRequests(force: true)
        pushNotifications.retryRegistrationIfUnconfirmed()
        Task { [weak self] in
            guard let self else { return }
            await self.flushPendingAttributes()
            await self.reportPushPermissionIfChanged()
            await self.inAppMessaging.syncCampaigns(force: true)
        }
    }

    // MARK: - Marketing subscription
    //
    // A DIFFERENT consent from optIn/optOut above. That one is whether we may
    // OBSERVE this person; this is whether we may MESSAGE them.

    /// Mirrors the backend's SUBSCRIPTION_CHANNELS and the other SDKs.
    private static let subscriptionChannels = ["email", "sms", "whatsapp", "push", "viber"]
    private static let subscriptionStatuses = ["optedIn", "subscribed", "unsubscribed"]

    /// Set the marketing subscription status for one channel. Safe before
    /// `initialize()`; held while tracking consent is pending.
    /// - Parameters:
    ///   - channel: one of email, sms, whatsapp, push, viber
    ///   - status: one of optedIn, subscribed, unsubscribed
    ///
    /// `unsubscribed` is a withdrawal: kept and delivered even when the user
    /// has opted out, consent is denied or pending, or after `wipeData()`
    /// (contract v4, 36). A newer change for the same channel replaces one
    /// still waiting to be sent (v4, 37).
    public func setSubscription(channel: String, status: String) {
        let withdrawal = status == "unsubscribed"
        guard runNowOrQueue({ $0.setSubscription(channel: channel, status: status) }, purgeable: !withdrawal) else { return }
        guard withdrawal || canCollect else {
            logger.warn("setSubscription not sent: tracking is opted out or consent is denied")
            return
        }
        guard Self.subscriptionChannels.contains(channel) else {
            logger.error("Invalid channel: \(channel). Must be one of: \(Self.subscriptionChannels.joined(separator: ", "))")
            return
        }
        guard Self.subscriptionStatuses.contains(status) else {
            logger.error("Invalid status: \(status). Must be one of: \(Self.subscriptionStatuses.joined(separator: ", "))")
            return
        }
        // A withdrawal made while tracking is not allowed carries the user
        // the app identified meanwhile (D-b).
        let userId = withdrawal ? identity.withdrawalUserId() : identity.getUserId()
        let anonymousId = identity.getAnonymousId()
        enqueueWrite(.subscription, path: "/v1/subscriptions/channel", ChannelSubscriptionRequest(
            channel: channel,
            status: status,
            // One identifier, never both - same rule as the other SDKs.
            userId: userId,
            anonymousId: userId == nil ? anonymousId : nil
        ), userId: userId, anonymousId: anonymousId, withdrawal: withdrawal,
           supersedeKey: Self.supersedeKey("channel:\(channel)", userId: userId, anonymousId: anonymousId),
           alsoReplacing: anonymousSupersedeKey("channel:\(channel)", userId: userId, anonymousId: anonymousId))
    }

    /// Join a subscription group (list) on a channel.
    public func addToSubscriptionGroup(_ groupId: String, channel: String) {
        updateSubscriptionGroup(groupId, channel: channel, action: "subscribe")
    }

    /// Leave a subscription group (list) on a channel.
    public func removeFromSubscriptionGroup(_ groupId: String, channel: String) {
        updateSubscriptionGroup(groupId, channel: channel, action: "unsubscribe")
    }

    private func updateSubscriptionGroup(_ groupId: String, channel: String, action: String) {
        // Leaving a group is a withdrawal (contract v4, 36), like unsubscribing.
        let withdrawal = action == "unsubscribe"
        guard runNowOrQueue({ $0.updateSubscriptionGroup(groupId, channel: channel, action: action) },
                            purgeable: !withdrawal, method: "\(action)SubscriptionGroup") else { return }
        guard withdrawal || canCollect else {
            logger.warn("Subscription group change not sent: tracking is opted out or consent is denied")
            return
        }
        guard !groupId.trimmingCharacters(in: .whitespaces).isEmpty else {
            logger.error("Cannot update subscription group: groupId is required")
            return
        }
        guard Self.subscriptionChannels.contains(channel) else {
            logger.error("Invalid channel: \(channel). Must be one of: \(Self.subscriptionChannels.joined(separator: ", "))")
            return
        }
        let userId = withdrawal ? identity.withdrawalUserId() : identity.getUserId()
        let anonymousId = identity.getAnonymousId()
        enqueueWrite(.subscription, path: "/v1/subscriptions/group", SubscriptionGroupRequest(
            groupId: groupId,
            channel: channel,
            action: action,
            userId: userId,
            anonymousId: userId == nil ? anonymousId : nil
        ), userId: userId, anonymousId: anonymousId, withdrawal: withdrawal,
           supersedeKey: Self.supersedeKey("group:\(channel):\(groupId)", userId: userId, anonymousId: anonymousId),
           alsoReplacing: anonymousSupersedeKey("group:\(channel):\(groupId)", userId: userId, anonymousId: anonymousId))
    }

    /**
     A subscription write replaces a queued one only for the SAME subject
     and the same person (SDK contract v5, 52): the user it is sent for, or
     the anonymous id when anonymous. The key named only the channel, so
     after reset() - or an account switch - the next person's subscribe
     silently replaced the previous person's unsubscribe still waiting to be
     sent, and they kept getting mail.
     */
    static func supersedeKey(_ subject: String, userId: String?, anonymousId: String) -> String {
        if let userId { return "\(subject)|user:\(userId)" }
        return "\(subject)|anon:\(anonymousId)"
    }

    /**
     The key of the same person's writes made while they were still
     anonymous on this device, or nil (SDK contract v6, 64).

     A write queued anonymously is SENT as the user identified since, as
     long as the anonymous id is still this device's (`resolveIds`). So a
     write for the CURRENT user replaces those too: they are this person's
     older intent. Not for anyone else - a user kept while tracking is off
     (D-b) is not who those writes go out as, and after reset() or
     wipeData() the anonymous id is a new one (contract v5, 52).
     */
    private func anonymousSupersedeKey(_ subject: String, userId: String?, anonymousId: String) -> String? {
        guard let userId, userId == identity.getUserId() else { return nil }
        return Self.supersedeKey(subject, userId: nil, anonymousId: anonymousId)
    }

    // MARK: - SDK Authentication

    /// Supply/replace the customer-minted SDK-authentication JWT.
    ///
    /// Supplying a token TURNS SDK AUTHENTICATION ON, whether or not
    /// `enableSdkAuthentication` was set - the same as Android. It used to be
    /// ignored with a warning unless the flag was set at init. Thread-safe;
    /// safe before `initialize()` (held in memory and applied at init).
    public func setSdkAuthenticationToken(_ token: String) {
        // An empty token is what a bridge passes for null: warn, change
        // nothing (SDK contract 19). It must not switch authentication on
        // with no credential, nor wipe a valid token.
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if let logger { logger.warn("setSdkAuthenticationToken() needs a token; ignored") } else {
                print("[Joryio] setSdkAuthenticationToken() needs a token; ignored")
            }
            return
        }
        guard isInitialized else {
            Self.withPreInit { Self.pendingAuthToken = token }
            return
        }
        authStore.setToken(token)
        logger.debug("SDK authentication token updated")
    }

    /// Register a handler invoked when an ingest request is rejected with an
    /// SDK-authentication error. Respond by minting a fresh JWT and calling
    /// `setSdkAuthenticationToken(_:)`; the SDK then retries the failed request
    /// once with the new token. Safe before `initialize()`.
    public func setSdkAuthenticationErrorHandler(_ handler: @escaping (SdkAuthError) -> Void) {
        guard isInitialized else {
            Self.withPreInit { Self.pendingAuthHandler = handler }
            return
        }
        authStore.setHandler(handler)
    }

    /// Remove the handler set with `setSdkAuthenticationErrorHandler(_:)` -
    /// for a bridge or screen tearing down, so the SDK stops calling into it.
    /// After this, a rejected request is logged and kept for the next token.
    /// Safe before `initialize()`.
    public func clearSdkAuthenticationErrorHandler() {
        guard isInitialized else {
            Self.withPreInit { Self.pendingAuthHandler = nil }
            return
        }
        authStore.clearHandler()
    }

    // MARK: - Queue Management

    /// E-commerce tracking helper - the standard product / cart / checkout /
    /// purchase events, with a default currency applied to each.
    ///
    /// - Parameter config: pass to change the currency or auto-tracking flags.
    ///   Omit to reuse the existing tracker.
    ///
    /// ```swift
    /// let ecommerce = Joryio.shared.ecommerce(config: EcommerceConfig(currency: "USD"))
    /// ecommerce.viewProduct(EcommerceProduct(productId: "SKU123", name: "Blue Shirt", price: 29.99))
    /// ```
    @discardableResult
    public func ecommerce(config: EcommerceConfig? = nil) -> EcommerceTracker {
        // Usable before initialize(): the tracker only forwards to track(),
        // which already no-ops and warns when uninitialised.
        if let config {
            let tracker = EcommerceTracker(sdk: self, config: config)
            _ecommerce = tracker
            return tracker
        }
        if let existing = _ecommerce { return existing }
        let tracker = EcommerceTracker(sdk: self)
        _ecommerce = tracker
        return tracker
    }

    /// Manually flush the event queue. Skips the SDK's own backoff, never a
    /// server's Retry-After (SDK contract 35). Safe before `initialize()`.
    public func flush() {
        guard runNowOrQueue({ $0.flush() }, purgeable: false) else { return }
        queue.flushSync(force: true)
    }

    /// Get current queue size
    public func getQueueSize() -> Int {
        guard isInitialized else { return 0 }
        return queue.getQueueSize()
    }

    // MARK: - Identity Access

    /// Get current user ID
    public func getUserId() -> String? {
        guard isInitialized else { return nil }
        return identity.getUserId()
    }

    /// Get anonymous ID
    public func getAnonymousId() -> String {
        guard isInitialized else { return "" }
        return identity.getAnonymousId()
    }

    /// Get user identity
    public func getIdentity() -> (userId: String?, anonymousId: String) {
        guard isInitialized else { return (nil, "") }
        return (identity.getUserId(), identity.getAnonymousId())
    }

    // MARK: - Session Access

    /// Get current session ID
    public func getSessionId() -> String {
        guard isInitialized else { return "" }
        return session.getSessionId()
    }

    /// Get session info
    public func getSessionInfo() -> (sessionId: String, sessionStart: Date, duration: TimeInterval) {
        guard isInitialized else { return ("", Date(), 0) }
        let sessionInfo = session.getSession()
        return (
            sessionInfo.sessionId,
            sessionInfo.sessionStart,
            session.getSessionDuration()
        )
    }

    // MARK: - In-App Messaging

    /// Show any in-app waiting on a push tap. Called by PushNotificationManager.
    internal func handlePushTapped() async {
        guard isInitialized else { return }
        await inAppMessaging?.onPushTapped()
    }

    /// Fetch in-app campaigns now, bypassing the automatic-sync interval.
    public func syncInAppCampaigns() async {
        guard isInitialized else {
            logNotInitialized()
            return
        }

        guard canSend else {
            logger.debug("Not syncing in-app campaigns: opted out or consent not granted")
            return
        }

        await inAppMessaging.syncCampaigns(force: true)
    }

    /// Manually trigger campaign evaluation (testing API - requires enableDebug)
    public func evaluateInAppCampaigns() async {
        guard isInitialized else {
            logNotInitialized()
            return
        }
        guard requireDebug("evaluateInAppCampaigns") else { return }

        guard canSend else {
            logger.debug("Not evaluating campaigns: opted out or consent not granted")
            return
        }

        await inAppMessaging.evaluateCampaigns()
    }

    /// Take over in-app display: the SDK hands you the campaign and draws
    /// nothing itself, so a host app can render messages with its own UI.
    ///
    /// A host that renders its own UI MUST report what happened via
    /// `trackInAppImpression` - `"displayed"` when it is on screen and
    /// `"dismissed"` when it goes away. Those reports are what count the
    /// message - `"displayed"` is also what spends the campaign's frequency
    /// budget, so a message handed over and never drawn costs nothing - and
    /// what free the SDK to hand over the next one (after 30 seconds without a
    /// report, the SDK frees itself and logs a warning).
    /// - Parameter capabilities: what YOUR renderer can draw, e.g.
    ///   `["content.native"]` for a game canvas, adding `"content.html"` only if
    ///   you host a WebView. Matches Android.
    public func setInAppMessageCallback(
        _ callback: @escaping (InAppCampaign) -> Void,
        capabilities: [String]? = nil
    ) {
        guard isInitialized else {
            Self.withPreInit { Self.pendingInAppCallback = (callback, capabilities) }
            return
        }
        inAppMessaging.hostCapabilities = capabilities
        // Wrapped to count handoffs, so the SDK can say something when a host
        // takes messages and reports none of them. Matches Android.
        inAppMessaging.onMessageReady = { [weak self] campaign in
            if let self { self.locked { self._inAppHandedOff += 1 } }
            callback(campaign)
            self?.warnIfInAppNeverReported()
        }
    }

    /// Hand in-app display back to the SDK: removes the callback set with
    /// `setInAppMessageCallback(_:capabilities:)`, so `JoryioUI` draws
    /// messages again and the capability report describes the SDK's own
    /// renderer. A message the host was holding stops occupying the display
    /// slot. Safe before `initialize()`.
    public func clearInAppMessageCallback() {
        guard isInitialized else {
            Self.withPreInit { Self.pendingInAppCallback = nil }
            return
        }
        inAppMessaging.clearHostRenderer()
    }

    /// Warn once when a host takes in-app messages and reports none.
    private func warnIfInAppNeverReported() {
        let handedOff: Int? = locked {
            guard !_warnedAboutUnreportedInApp, _inAppReported == 0, _inAppHandedOff >= 3 else { return nil }
            _warnedAboutUnreportedInApp = true
            return _inAppHandedOff
        }
        guard let handedOff else { return }
        logger.warn(
            "\(handedOff) in-app messages were handed to your callback and none were reported. "
                + "Call trackInAppImpression(campaignId:action:) with \"displayed\"/\"clicked\"/\"dismissed\" "
                + "when you render one, or campaign analytics will show zero displays and frequency "
                + "caps will never apply to these messages."
        )
    }

    /**
     Submit a form shown inside an in-app message (the `joryioBridge.submitForm`
     bridge call lands here). Never throws: a failure is an `ok: false` answer.
     */
    public func submitInAppForm(campaignId: String, values: [String: Any]) async -> InAppFormSubmitResponse {
        guard isInitialized else {
            logNotInitialized()
            return InAppFormSubmitResponse(ok: false, message: "Something went wrong. Please try again.")
        }
        guard canSend else {
            return InAppFormSubmitResponse(ok: false, message: "Something went wrong. Please try again.")
        }
        var encoded: [String: InAppFormValue] = [:]
        for (key, raw) in values {
            if let list = raw as? [Any] {
                encoded[key] = .list(list.map { String(describing: $0) })
            } else if let s = raw as? String {
                encoded[key] = .string(s)
            } else if !(raw is NSNull) {
                encoded[key] = .string(String(describing: raw))
            }
        }
        let request = InAppFormSubmitRequest(
            campaignId: campaignId,
            userId: identity.getUserId(),
            anonymousId: identity.getAnonymousId(),
            values: encoded
        )
        do {
            return try await network.submitInAppForm(request)
        } catch {
            logger.error("In-app form submit failed: \(error.localizedDescription)")
            return InAppFormSubmitResponse(ok: false, message: "Something went wrong. Please try again.")
        }
    }

    /// Report an in-app impression for a message YOU rendered.
    ///
    /// - Parameters:
    ///   - action: `displayed`, `clicked`, `dismissed` or `converted` (the
    ///     backend's vocabulary; its listed synonyms are accepted too, anything
    ///     else is refused with a log line). Matches Android.
    ///   - elementId: for a click, WHICH button or link (its id). Optional.
    public func trackInAppImpression(campaignId: String, action: String, elementId: String? = nil) {
        guard runNowOrQueue({ $0.trackInAppImpression(campaignId: campaignId, action: action, elementId: elementId) }) else { return }
        guard !campaignId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warn("trackInAppImpression() needs a campaignId; ignored")
            return
        }
        locked { _inAppReported += 1 }
        inAppMessaging.trackHostImpression(campaignId: campaignId, action: action, elementId: elementId)
    }

    /// Clear the show-once record (testing API - requires enableDebug)
    public func resetDisplayedCampaigns() {
        guard isInitialized else {
            logNotInitialized()
            return
        }
        guard requireDebug("resetDisplayedCampaigns") else { return }
        inAppMessaging.resetDisplayedCampaigns()
    }

    /// Gate for the QA-only calls that CHANGE behaviour. Read-only
    /// diagnostics are deliberately not gated.
    private func requireDebug(_ method: String) -> Bool {
        guard config?.enableDebug == true else {
            logger?.warn(
                "\(method) is a testing API and is ignored unless enableDebug is on. It changes "
                    + "live state (frequency caps / message display), so it must not run in a "
                    + "production build."
            )
            return false
        }
        return true
    }

    // MARK: - Push Notifications

    /// Request push notification permissions
    @discardableResult
    public func requestPushPermission() async -> Bool {
        guard isInitialized else {
            logNotInitialized()
            return false
        }

        guard !isOptedOut else {
            logger.debug("User opted out, skipping push permissions")
            return false
        }

        // Lifts a durable unregisterPush(): asking is the app opting back in.
        let granted = await pushNotifications.requestPermissions()
        await reportPushPermissionIfChanged()
        return granted
    }

    /// Where the user stands on notifications, without asking them anything.
    ///
    /// Values are the cross-platform vocabulary (SDK contract 8):
    /// `granted` (provisional and ephemeral included), `denied`,
    /// `notDetermined`. `unavailable` is part of the shared vocabulary for
    /// platforms that can lack push entirely; iOS always has it, so iOS does
    /// not return it. `isPushEnabled()` is true exactly when this is `granted`.
    public func getPushPermissionStatus() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.pushPermissionStatus(settings.authorizationStatus)
    }

    /// The ONE mapping from the OS status to the public vocabulary.
    ///
    /// `isPushEnabled` and `getPushPermissionStatus` used to disagree:
    /// provisional and ephemeral authorisation read as "granted" from one and
    /// `false` from the other, so a host branching on either got a different
    /// answer for the same device. Both now derive from this.
    static func pushPermissionStatus(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .authorized, .provisional, .ephemeral:
            return "granted"
        @unknown default:
            // A status Apple adds later is not automatically "safe to prompt":
            // treating an unknown as notDetermined would burn the one ask.
            return "denied"
        }
    }

    /// Reserved attribute carrying the notification-permission state.
    ///
    /// No `$` prefix: contact attributes are written to Mongo as
    /// `attributes.<key>` dotted paths, where a `$`-prefixed key breaks.
    public static let pushPermissionAttribute = "push_permission"

    /// Report the notification-permission state as a user attribute, but ONLY
    /// when it changed since we last reported it.
    private func reportPushPermissionIfChanged() async {
        // canSend, not canCollect: recording "reported" while consent is
        // pending and then having the write discarded would never re-report.
        guard canSend, environment.systemIntegration else { return }
        // snake_case on the wire, deliberately: Android reports
        // NOT_DETERMINED.lowercase() = "not_determined"; iOS matches it here.
        let api = await getPushPermissionStatus()
        let current = api == "notDetermined" ? "not_determined" : api
        guard storage.getReportedPushPermission() != current else { return }
        storage.setReportedPushPermission(current)
        logger.debug("Push permission changed to \(current); reporting")
        setAttribute(Joryio.pushPermissionAttribute, value: current)
    }

    /// Register a push token supplied as a hex string (e.g. from a
    /// cross-platform bridge that already has the APNs token as a string).
    /// Mirrors the Android SDK's `registerPushToken(String)`. Lifts an earlier
    /// `unregisterPush()`. Safe before `initialize()`: queued.
    /// - Parameter onResult: called once with the registration outcome, on a
    ///   background task - hop to the main actor before touching UI. A
    ///   `success: false` from the server is a failure here, never a success.
    public func registerPushToken(
        _ token: String,
        onResult: ((PushRegistrationResult) -> Void)? = nil
    ) {
        // After a failed initialize() the callback answers at once: a bridge
        // promise waiting on it must never hang (contract v4, 48).
        let refusedByInit: () -> Void = {
            onResult?(PushRegistrationResult(success: false, message: "The SDK is not initialized: initialize() refused the SDK key or API host", isRetryable: false))
        }
        if initFailed, !isInitialized {
            refusedByInit()
            return
        }
        guard runNowOrQueue({ $0.registerPushToken(token, onResult: onResult) }, purgeable: false, settle: refusedByInit) else { return }

        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warn("registerPushToken() needs a token; ignored")
            onResult?(PushRegistrationResult(success: false, message: "Empty token"))
            return
        }

        // iOS push goes through APNs, whose device token is hex. A Firebase
        // (FCM) registration token - what `onTokenRefresh` hands a React
        // Native or Flutter app on iOS too - replaced the APNs token on the
        // server and every push to the device then failed (SDK contract v5,
        // 59). Refused here, for every caller of this method.
        // Registered as the check sees it: trimmed, lower-case hex. A token
        // with a stray newline passed the check, was stored untrimmed and
        // refused by the server (400) on every re-registration (scan 6, N2).
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isAPNsToken(token) else {
            logger.warn(
                "registerPushToken() refused a token that is not an APNs device token (hex). On iOS register "
                    + "the APNs token - for example Firebase's getAPNSToken() - never the FCM registration token."
            )
            onResult?(PushRegistrationResult(success: false, message: "Not an APNs device token (hex expected)", isRetryable: false))
            return
        }

        guard !isOptedOut else {
            logger.debug("User opted out, skipping push token registration")
            onResult?(PushRegistrationResult(success: false, message: "User opted out"))
            return
        }

        pushNotifications.registerDeviceToken(token, explicit: true, onResult: onResult)

        // A token in hand is evidence of authorisation: refresh push_permission.
        Task { await reportPushPermissionIfChanged() }
    }

    /// An APNs device token as a string: hex digits only, an even count, at
    /// least 64 (32 bytes, today's length; Apple may lengthen it) and at most
    /// 200 - the backend's own bounds (`push-token.util.ts`).
    static func isAPNsToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 64, trimmed.count <= 200, trimmed.count % 2 == 0 else { return false }
        return trimmed.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
    }

    /// Track a push-notification click by tracking id.
    /// Mirrors the Android SDK's `trackPushClick(String)`.
    public func trackPushClick(trackingId: String) {
        guard runNowOrQueue({ $0.trackPushClick(trackingId: trackingId) }) else { return }
        guard !trackingId.isEmpty else {
            logger.warn("trackPushClick() needs a trackingId; ignored")
            return
        }

        pushNotifications.handlePushClick(trackingId: trackingId)
    }

    /// Hand the APNs device token to the SDK.
    ///
    /// Call from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    /// Also the entry point for an engine that receives the token itself and
    /// forwards it - the Unity bridge passes the bytes it gets from
    /// `kUnityDidRegisterForRemoteNotificationsWithDeviceToken` here.
    ///
    /// Safe at any time: a token that arrives before `initialize()` is held and
    /// registered at init. Registration with the backend happens only while
    /// the user is opted in and consent is granted; otherwise the token is
    /// kept on the device and registered when that changes.
    public func didRegisterForRemoteNotifications(deviceToken: Data) {
        guard isInitialized else {
            stashPendingDeviceToken(deviceToken.map { String(format: "%02.2hhx", $0) }.joined())
            return
        }

        pushNotifications.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    /// Holds a device token that arrived before initialize(). UserDefaults:
    /// at this point there is no storage manager yet. Cleared at init.
    static let pendingDeviceTokenKey = "joryio_pending_device_token"

    private func stashPendingDeviceToken(_ token: String) {
        environment.defaults.set(token, forKey: Self.pendingDeviceTokenKey)
        print("[Joryio] Device token arrived before initialize(); stored for registration at init.")
    }

    /// Register (and clear) a token captured before initialize(). Mirrors
    /// Android's PushNotificationManager.bootstrapToken. Gated like every other
    /// registration path.
    private func registerPendingDeviceTokenIfAny() {
        guard let token = environment.defaults.string(forKey: Self.pendingDeviceTokenKey) else { return }
        environment.defaults.removeObject(forKey: Self.pendingDeviceTokenKey)
        logger.info("Registering push token captured before init")
        pushNotifications.registerDeviceToken(token)
    }

    /// Handle failed device token registration (call from AppDelegate)
    public func didFailToRegisterForRemoteNotifications(error: Error) {
        guard isInitialized else {
            logNotInitialized()
            return
        }

        pushNotifications.didFailToRegisterForRemoteNotifications(error: error)
    }

    /// Handle received push notification (call from AppDelegate)
    public func didReceiveRemoteNotification(
        _ userInfo: [AnyHashable: Any],
        completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard isInitialized else {
            logNotInitialized()
            completionHandler(.noData)
            return
        }

        pushNotifications.didReceiveRemoteNotification(userInfo, completionHandler: completionHandler)
    }

    /// Get current device token
    public func getDeviceToken() -> String? {
        guard isInitialized else { return nil }
        return pushNotifications.getDeviceToken()
    }

    /// Whether notifications are enabled: exactly when
    /// `getPushPermissionStatus()` is `granted`.
    public func isPushEnabled() async -> Bool {
        guard isInitialized else { return false }
        return await pushNotifications.isPushEnabled()
    }

    /// Update app badge count
    public func updateBadgeCount(_ count: Int) {
        guard isInitialized else { return }
        pushNotifications.updateBadgeCount(count)
    }

    /// Clear app badge
    public func clearBadge() {
        guard isInitialized else { return }
        pushNotifications.clearBadge()
    }

    /**
     Report that a push arrived on this device.

     For a host app running its OWN notification handling, so nothing routes
     through the SDK's handlers. Named and shaped to match
     `Joryio.reportPushDelivered(trackingId)` on Android.
     */
    public func reportPushDelivered(_ trackingId: String) {
        guard runNowOrQueue({ $0.reportPushDelivered(trackingId) }) else { return }
        pushNotifications.reportDelivered(trackingId: trackingId)
    }

    /// Unregister from push notifications: the token is removed on the server
    /// (`POST /v1/push/unregister`, as Android and web do) and with the OS.
    ///
    /// Durable: it holds across launches - the token iOS hands over at the
    /// next launch is not registered - until `registerPushToken(_:)` or
    /// `requestPushPermission()` is called. Safe before `initialize()`.
    public func unregisterPush() {
        guard runNowOrQueue({ $0.unregisterPush() }, purgeable: false) else { return }
        pushNotifications.unregister()
    }

    // MARK: - Lifecycle Observers

    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onAppBackgrounded()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onAppForegrounded()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onAppTerminating()
        }
    }

    private func onAppBackgrounded() {
        logger.debug("App backgrounded")
        // Send what we have, then stop the periodic timer (apps with a
        // background mode keep running and would otherwise wake every 5s).
        queue?.flushSync()
        queue?.suspendPeriodicFlush()
    }

    private func onAppForegrounded() {
        logger.debug("App foregrounded")
        queue?.resumePeriodicFlush()
        Task { await reportPushPermissionIfChanged() }

        // No-op when the backend already confirmed this token.
        pushNotifications.retryRegistrationIfUnconfirmed()

        // identify / addAlias / subscription changes that failed last time.
        retryOwedRequests()

        // Renew FIRST and let the renewal itself say whether a new session
        // began. This used to renew and THEN measure the time since the last
        // activity - which the renewal had just reset, so no Session Start was
        // ever sent after a timeout.
        let renewed = session.checkAndRenewSession()
        if renewed || takeSessionStartDue(), config.trackSessionStart {
            trackSessionStartEvent()
        }

        // Retry attributes BEFORE syncing, so targeting sees them.
        Task {
            await flushPendingAttributes()
            await inAppMessaging.syncCampaigns()
        }
    }

    private func onAppTerminating() {
        logger.debug("App terminating")
        queue?.flushSync()
    }

    /**
     Announce the session that just began.

     Recorded DIRECTLY, never through the pre-init buffer: at initialize() the
     buffer has not been replayed yet, and a Session Start that joined it
     landed after the events of the very session it opens (SDK contract 32).

     While consent is pending it is queued on the device like every other
     event - nothing leaves - so it stays ahead of the events of its session.
     When it cannot be collected at all - consent denied, opted out - it is
     owed, and recorded once collection is allowed again in this session.
     */
    private func trackSessionStartEvent() {
        // Whatever announces the session covers one a wipe left due.
        locked { _sessionStartDue = false }
        guard canCollect else {
            markSessionStartOwed()
            return
        }
        locked { _sessionStartOwed = false }
        environment.defaults.removeObject(forKey: Self.sessionStartDueKey)
        environment.defaults.removeObject(forKey: Self.sessionStartOwedKey)
        let deviceId = storage.getDeviceId()
        let properties = DeviceInfo.getTrackingProperties(deviceId: deviceId)
        record("Session Start", properties: properties)
    }
}
