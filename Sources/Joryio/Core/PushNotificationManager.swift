import Foundation
import UIKit
import UserNotifications

/// Manages push notifications (APNS)
/// The outcome of a push-token registration.
///
/// Mirrors Android's `PushRegistrationResult` exactly - same name, same fields,
/// same meanings - so an integrator reads one document for both platforms.
///
/// registerPushToken used to be pure fire-and-forget: its only reaction to a
/// rejection was a logger call, which is gated behind debug logging. A release
/// build could therefore fail to register on every single launch with nothing,
/// anywhere, saying so - the device was simply never reachable. An integrator
/// worked around it by polling diagnostics a few seconds later and comparing
/// timestamps against a global last-error, which is a lot of machinery to learn
/// something this function already knew and threw away.
public struct PushRegistrationResult {
    public let success: Bool
    /// Provider or transport message on failure; nil on success.
    public let message: String?
    /// A bad or missing SDK key - retrying will not fix it.
    public let isUnauthorized: Bool
    /// Transient (network, 5xx): the SDK will try again on next launch.
    public let isRetryable: Bool

    public init(
        success: Bool,
        message: String? = nil,
        isUnauthorized: Bool = false,
        isRetryable: Bool = false
    ) {
        self.success = success
        self.message = message
        self.isUnauthorized = isUnauthorized
        self.isRetryable = isRetryable
    }
}

class PushNotificationManager: NSObject {
    private let networkClient: NetworkClient
    private let identityManager: IdentityManager
    private let storage: StorageManager
    private let logger: Logger
    private weak var inAppMessaging: InAppMessagingManager?

    private let stateLock = NSLock()
    private var _deviceToken: String?
    private var deviceToken: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _deviceToken }
        set { stateLock.lock(); _deviceToken = newValue; stateLock.unlock() }
    }

    /// May a token be registered with the backend right now? Set by the SDK:
    /// false while opted out or while tracking consent is not granted.
    ///
    /// Every registration path asks this one question. Registration used to
    /// check opt-out at the public `registerPushToken` only, so the AppDelegate
    /// forwarding, the token captured before init, the foreground retry and
    /// the identify/reset re-bind all registered an opted-out device anyway.
    /// The token is still SAVED when refused, so opting back in can register it.
    var canRegister: () -> Bool = { true }

    /// May this device report push receipts and clicks? Same gate.
    var canReport: () -> Bool = { true }

    /// The app's own notification-center delegate, if it had one when the SDK
    /// took over. Non-Joryio notifications, and the callbacks the SDK has no
    /// opinion on, go to it - see the UNUserNotificationCenterDelegate
    /// extension. Weak because UNUserNotificationCenter holds its delegate
    /// weakly too: whoever set it already owns it.
    weak var previousDelegate: UNUserNotificationCenterDelegate?

    /**
     Unregisters the server has not acknowledged (scan 3, S2).

     `POST /v1/push/unregister` used to be one attempt: offline, a 5xx or a
     `success: false`, and the server kept a token the person had asked to
     stop - and kept sending to it. Now each one is kept (in the Keychain: it
     carries the token) and retried until the server answers 2xx
     `success: true`, across restarts - the same as Android. Not gated by
     consent or opt-out: removing a token collects nothing, and a withdrawal
     is always delivered (contract v4, 36).

     Every drain of it runs under `opLock`, like every registration: an
     unregister is never on the wire at the same time as a registration.
     */
    private(set) lazy var unregisterOutbox: WriteOutbox = {
        let outbox = WriteOutbox(
            logger: logger,
            maxEntries: 20,
            load: { [weak storage] in .value(storage?.getPendingPushUnregisters()) },
            save: { [weak storage] in storage?.setPendingPushUnregisters($0) },
            sender: { [weak networkClient] path, body, userId in
                await networkClient?.sendWrite(path: path, body: body, userId: userId) ?? .retry(retryAfter: nil, answered: false)
            }
        )
        // The user a withdrawal is sent for - one kept while tracking is off
        // included (D-b) - counts as current for SDK authentication.
        outbox.currentUserId = { [weak identityManager] in identityManager?.withdrawalUserId() }
        outbox.onSettled = { [weak self] _, _ in self?.onUnregisterSettled() }
        outbox.drainGate = { [opLock] work in await opLock.run { await work() } }
        return outbox
    }()

    /**
     Registration and unregistration run one at a time, in the order they
     were asked for (Android's `opMutex`).

     A pending unregister used to be retried on its own schedule, so it
     could reach the server AFTER a later registration and switch push off
     for good (scan 4, finding 2). Now an explicit registration of the same
     token cancels it, and any other pending unregister is sent - and
     confirmed - before a registration goes out.
     */
    private let opLock = AsyncSerialLock()

    /// The token an unregister entry carries.
    private static func token(of entry: OutboxEntry) -> String? {
        ((try? JSONSerialization.jsonObject(with: Data(entry.body.utf8))) as? [String: Any])?["token"] as? String
    }

    /// Set by the SDK: an unregister left the outbox (retired tokens are
    /// pruned then - D-a).
    var onUnregisterSettled: () -> Void = {}

    /// Resend unregisters the server has not acknowledged. Called at start,
    /// on foreground and when sending resumes.
    func retryPendingUnregisters(force: Bool = false) {
        guard unregisterOutbox.count > 0 else { return }
        unregisterOutbox.kick(force: force)
    }

    init(
        networkClient: NetworkClient,
        identityManager: IdentityManager,
        storage: StorageManager,
        logger: Logger,
        inAppMessaging: InAppMessagingManager? = nil
    ) {
        self.networkClient = networkClient
        self.identityManager = identityManager
        self.storage = storage
        self.logger = logger
        self.inAppMessaging = inAppMessaging
        super.init()

        loadStoredDeviceToken()
        // Built now, on the initialising thread: the lazy property is read
        // from background tasks too (the SDK prunes retired tokens after a
        // flush), and two threads racing its first read would build two
        // outboxes over one store.
        _ = unregisterOutbox
    }

    // MARK: - Device Token Management

    /// Load stored device token from the Keychain (via StorageManager).
    /// The token is an identity-linking secret and is kept in the Keychain, not
    /// UserDefaults; see StorageManager for the accessibility/at-rest rationale.
    private func loadStoredDeviceToken() {
        if let token = storage.getDeviceToken() {
            self.deviceToken = token
            logger.debug("Loaded stored device token: \(token.prefix(20))...")
        }
    }

    /// Save device token to the Keychain (via StorageManager).
    private func saveDeviceToken(_ token: String) {
        self.deviceToken = token
        storage.setDeviceToken(token)
        logger.debug("Saved device token: \(token.prefix(20))...")
    }

    /// Get current device token
    func getDeviceToken() -> String? {
        return deviceToken
    }

    // MARK: - Push Registration

    /// Request push notification permissions
    func requestPermissions() async -> Bool {
        // Asking for permission is the app opting back in to push: it lifts
        // a durable unregisterPush().
        storage.setPushUnregistered(false)
        let center = UNUserNotificationCenter.current()

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])

            // Register EITHER WAY. Alert authorization and remote-notification
            // registration are separate on iOS: registering yields a device
            // token without user consent, and that token can only ever deliver
            // BACKGROUND (content-available) pushes - it cannot display
            // anything without the authorization above.
            //
            // Gating registration on `granted` meant a user who declined the
            // prompt had no token, so the in-app sync nudge could never reach
            // them - typically a large share of an iOS audience, silently. It
            // also meant that if they later enabled notifications in Settings,
            // we still held no token until the next prompt.
            //
            // Registering unconditionally is the common pattern among push SDKs,
            // for the same reasons. Disclose it in the privacy policy.
            await registerForRemoteNotifications()

            if granted {
                logger.info("Push notification permission granted")
                return true
            } else {
                logger.warn("Push notification permission denied")
                return false
            }
        } catch {
            logger.error("Failed to request push permissions: \(error.localizedDescription)")
            return false
        }
    }

    /// Register for remote notifications
    @MainActor
    private func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
        logger.debug("Registered for remote notifications")
    }

    /// Handle successful device token registration
    func didRegisterForRemoteNotifications(deviceToken: Data) {
        // Convert token to string
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()

        logger.info("Received device token: \(tokenString.prefix(20))...")

        saveDeviceToken(tokenString)

        // Register with backend
        Task {
            await registerDeviceWithBackend(tokenString)
        }
    }

    /// Handle failed device token registration
    func didFailToRegisterForRemoteNotifications(error: Error) {
        logger.error("Failed to register for remote notifications: \(error.localizedDescription)")
    }

    /// Register a device token supplied directly as a hex string (used by the
    /// cross-platform bridge, which already has the token as a string).
    /// - Parameter explicit: the APP asked for this registration
    ///   (`registerPushToken(_:)`), which lifts an earlier `unregisterPush()`.
    ///   A token the SDK recovers on its own (captured before init) does not.
    func registerDeviceToken(
        _ token: String,
        explicit: Bool = false,
        onResult: ((PushRegistrationResult) -> Void)? = nil
    ) {
        logger.info("Registering supplied device token: \(token.prefix(20))...")
        if explicit { storage.setPushUnregistered(false) }
        saveDeviceToken(token)
        Task {
            // The app asked: always send. A registration that was in flight
            // when unregisterPush() ran could otherwise leave a stale
            // "already registered" mark that skips this one.
            await registerDeviceWithBackend(token, force: explicit, explicit: explicit, onResult: onResult)
        }
    }

    /// Re-register the currently stored device token against the current
    /// identity. Called on identify()/reset() so a token captured under one
    /// identity is re-bound to the new one instead of staying with the old user.
    func reregisterDeviceToken() {
        guard let token = deviceToken else {
            logger.debug("No stored device token to re-register")
            return
        }
        Task {
            await registerDeviceWithBackend(token, force: true)
        }
    }

    /// Retry a registration the backend never confirmed.
    ///
    /// Called on foreground. Transient failures are already retried inside the
    /// request, and a sustained outage is retried at the next init - but an app
    /// that STAYS OPEN after one would otherwise remain unreachable by push
    /// until relaunch, which for a long-lived session can be days.
    ///
    /// Cheap by construction: with a confirmed registration the guard inside
    /// registerDeviceWithBackend returns immediately without touching the network.
    func retryRegistrationIfUnconfirmed() {
        guard let token = deviceToken ?? storage.getDeviceToken() else { return }
        Task { await registerDeviceWithBackend(token) }
    }

    /// Track a push-notification click by tracking id (public entry point).
    func handlePushClick(trackingId: String) {
        guard canReport() else {
            logger.debug("Push click not reported: opted out or consent not granted")
            return
        }
        Task {
            await trackPushClick(trackingId: trackingId)
        }
    }

    /// Register device token with backend - one operation at a time with
    /// the unregisters (see `opLock`).
    private func registerDeviceWithBackend(
        _ token: String,
        force: Bool = false,
        explicit: Bool = false,
        onResult: ((PushRegistrationResult) -> Void)? = nil
    ) async {
        await opLock.run {
            await registerDeviceLocked(token, force: force, explicit: explicit, onResult: onResult)
        }
    }

    /// Caller holds `opLock`.
    private func registerDeviceLocked(
        _ token: String,
        force: Bool,
        explicit: Bool,
        onResult: ((PushRegistrationResult) -> Void)?
    ) async {
        if explicit {
            // Turning push back on. An unregister of THIS token still waiting
            // to be sent is cancelled rather than sent after the
            // registration, which would undo it.
            unregisterOutbox.removeAll { Self.token(of: $0) == token }
        }
        guard canRegister() else {
            logger.debug("Push token saved but not registered: opted out or consent not granted")
            onResult?(PushRegistrationResult(success: false, message: "Not registered: tracking is opted out or consent is not granted"))
            return
        }
        guard !storage.isPushUnregistered() else {
            logger.debug("Push token saved but not registered: the app called unregisterPush()")
            onResult?(PushRegistrationResult(success: false, message: "Not registered: unregisterPush() is in effect until registerPushToken() or requestPushPermission() is called"))
            return
        }

        // An unregister the server has not confirmed goes FIRST: sent after
        // this registration it would switch the device off again.
        if unregisterOutbox.count > 0 {
            await unregisterOutbox.drain(force: true)
            if unregisterOutbox.count > 0 {
                logger.debug("Push token not registered yet: an earlier unregister is still pending")
                onResult?(PushRegistrationResult(success: false, message: "An earlier unregister is still pending", isRetryable: true))
                return
            }
        }

        let userId = identityManager.getUserId()
        let anonymousId = identityManager.getAnonymousId()

        // Skip a registration the backend already has. Apple's guidance is to
        // call registerForRemoteNotifications() on EVERY launch, so the delegate
        // fires each time and without this every app open spent a request
        // restating an unchanged token.
        //
        // Keyed by token+identity: the same token under a new user is a
        // different registration, which is what makes reset() work.
        let key = "\(token)|\(userId ?? anonymousId)"
        if !force, storage.getRegisteredPushKey() == key {
            logger.debug("Push token already registered for this identity; skipping")
            // Already registered IS success. A caller that heard nothing here
            // would read a no-op as a silent failure - the very ambiguity this
            // callback removes.
            onResult?(PushRegistrationResult(success: true))
            return
        }

        // Gather device info
        let deviceInfo = DeviceInfo.getDeviceInfo()

        do {
            try await networkClient.registerPushToken(
                userId: userId,
                anonymousId: anonymousId,
                deviceToken: token,
                // The same identity the track path sends, so the server joins
                // this token to the existing device row instead of inserting a
                // second one.
                deviceId: storage.getDeviceId(),
                deviceInfo: deviceInfo
            )

            // Mark AFTER the backend confirms. Marking before would remember a
            // FAILED registration as done and leave the device permanently
            // unreachable by push.
            // Not if unregisterPush() / wipeData() ran while this was in
            // flight: the mark would make the next explicit registration a
            // no-op although the server no longer has the token.
            if !storage.isPushUnregistered() {
                storage.setRegisteredPushKey(key)
            }
            logger.info("Device token registered with backend successfully")
            onResult?(PushRegistrationResult(success: true))
        } catch {
            logger.error("Failed to register device token with backend: \(error.localizedDescription)")
            // Classified from THIS call's error.
            //
            // It used to read `networkClient.lastTransportError`, which does not
            // exist on NetworkClient - the property lives on JoryioSDK - so the
            // SDK did not compile. Pointing it at the SDK's copy would have
            // compiled and still been wrong: that property is shared, so a
            // concurrent request completing between the throw and the read
            // makes this callback describe someone else's failure. The caught
            // error IS this registration's outcome.
            let (message, isUnauthorized) = Self.describe(error)
            onResult?(
                PushRegistrationResult(
                    success: false,
                    message: message,
                    isUnauthorized: isUnauthorized,
                    // Anything not an auth rejection is worth another launch.
                    isRetryable: !isUnauthorized
                )
            )
        }
    }

    /// Turn a registration failure into something an integrator can act on.
    ///
    /// `isUnauthorized` is the one distinction that matters to a host app: a
    /// rejected SDK key is a thing they can FIX (wrong key, or a key for
    /// another workspace), everything else is worth retrying on next launch.
    /// NetworkError does not conform to LocalizedError, so localizedDescription
    /// alone would report "The operation couldn't be completed" for every one
    /// of these.
    static func describe(_ error: Error) -> (message: String, isUnauthorized: Bool) {
        guard let netError = error as? NetworkClient.NetworkError else {
            return (error.localizedDescription, false)
        }
        switch netError {
        case .unauthorized:
            return ("SDK key rejected by the server (401)", true)
        case let .sdkAuthError(reason, endpoint, _):
            return ("SDK authentication failed (\(reason)) at \(endpoint)", true)
        case let .httpError(code):
            // 403 is an authorization refusal too - retrying it forever without
            // saying so is how a mis-scoped key looks like a flaky network.
            return ("Server returned HTTP \(code)", code == 401 || code == 403)
        case let .rateLimited(retryAfter):
            let suffix = retryAfter.map { " - retry after \(Int($0))s" } ?? ""
            return ("Rate limited by the server\(suffix)", false)
        case .invalidURL:
            return ("Invalid API endpoint configured", false)
        case .invalidResponse:
            return ("Unreadable response from the server", false)
        case let .serverRejected(message):
            return ("Server did not store the registration" + (message.map { ": \($0)" } ?? ""), false)
        case .unknown:
            return ("Network request failed", false)
        }
    }

    // MARK: - Push Notification Handling

    /// Handle received push notification
    func didReceiveRemoteNotification(
        _ userInfo: [AnyHashable: Any],
        completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        logger.debug("Received remote notification: \(userInfo)")

        // Every Joryio push carries the `joryio` marker (push data contract,
        // PushPayloadKeys). This gated on `jry_campaign_id` or `jry_sync`, and
        // the backend never sent `jry_campaign_id` - so a campaign push was
        // ignored here and never produced a delivery receipt.
        guard PushPayloadKeys.isJoryio(userInfo) else {
            logger.debug("Not a Joryio notification, ignoring")
            completionHandler(.noData)
            return
        }
        let syncType = userInfo[PushPayloadKeys.sync] as? String

        // A silent nudge is not a delivered message: counting it as one would
        // add a phantom "received" to whatever campaign the tester was checking.
        //
        // The delivery RECEIPT is the only signal here. It becomes
        // `message.delivered`, the one push delivery signal with evidence
        // behind it: APNs answers a send with "accepted" and never reports what
        // reached the handset. There is deliberately NO local analytics event
        // beside it: a private "track notification event" helper used to sit
        // here that only logged (audit 2026-09-26, I13), and Android tracks none
        // either - the receipt and the click endpoint are the push analytics on
        // every platform, and a client-minted "received" event would double-count.
        // The receipt and a silent sync run BEFORE the completion handler is
        // called (bounded): iOS may suspend the app as soon as it is, and the
        // handler used to be called at once, so receipts and `jry_sync`
        // nudges sent from detached tasks were often delayed or lost (scan 5,
        // N5).
        let finish = Self.once { completionHandler(.newData) }
        Task { [weak self] in
            if syncType == nil, let trackingId = PushPayloadKeys.extractTrackingId(userInfo) {
                await self?.sendDeliveryReceipt(trackingId: trackingId)
            }
            await self?.handleNotificationContent(userInfo: userInfo)
            finish()
        }
        Task {
            try? await Task.sleep(nanoseconds: Self.backgroundWorkLimitSeconds * 1_000_000_000)
            finish()
        }
    }

    /// iOS gives a background push about 30 seconds; the handler is called
    /// before that whatever happens.
    static let backgroundWorkLimitSeconds: UInt64 = 25

    /// A closure that runs `body` once, however many times it is called.
    static func once(_ body: @escaping () -> Void) -> () -> Void {
        let lock = NSLock()
        var done = false
        return {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { body() }
        }
    }

    /// Fire-and-forget delivery receipt.
    ///
    /// Never throws into the notification path: this method's job is to handle
    /// a message, and telemetry must not be able to stop it.
    ///
    /// COVERAGE, stated plainly: this fires when the app process is running -
    /// foreground, or backgrounded with content-available. A notification
    /// delivered while the app is fully suspended is handled by the
    /// Notification Service Extension, which runs in a SEPARATE process without
    /// the SDK's endpoint or key, so it cannot report from there today. Closing
    /// that gap needs an App Group the host app configures, so the SDK can
    /// share its config with the extension. Until then iOS delivery is a
    /// LOWER BOUND, and undercounting is the right direction for a metric whose
    /// whole purpose is to stop overstating delivery.
    private func sendDeliveryReceipt(trackingId: String) async {
        guard !trackingId.isEmpty else { return }
        guard canReport() else {
            logger.debug("Push receipt not reported: opted out or consent not granted")
            return
        }
        do {
            try await networkClient.reportPushDelivered(trackingId: trackingId)
        } catch {
            logger.debug("Delivery receipt failed: \(error.localizedDescription)")
        }
    }

    /// Report a delivery by trackingId, for a host that received the push itself.
    ///
    /// Split out of the userInfo variant above rather than duplicated: an app
    /// with its own notification handling never routes through ours, so it has
    /// the trackingId but not our extraction. Android has exposed exactly this
    /// (Joryio.reportPushDelivered) all along; iOS had the capability and no
    /// public way in.
    func reportDelivered(trackingId: String) {
        Task { [weak self] in await self?.sendDeliveryReceipt(trackingId: trackingId) }
    }

    /// Handle notification tap/interaction
    func didReceiveNotificationResponse(
        _ response: UNNotificationResponse,
        completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        logger.debug("User interacted with notification: \(response.actionIdentifier)")

        // Track push click if tracking ID is present. A payload without one
        // is not a Joryio-tracked send and there is nothing honest to record:
        // the "fallback" that used to sit in an else-branch here only logged.
        if let trackingId = PushPayloadKeys.extractTrackingId(userInfo) {
            handlePushClick(trackingId: trackingId)
        }

        // Show anything triggered by the tap. Fire-and-forget: a
        // push_notification_tap campaign is a bonus on top of the tap, and a
        // failure here must not affect the deep link below.
        Task { await Joryio.shared.handlePushTapped() }

        // Open the tap target. ONE key: the composer has one on-tap URL. A
        // second `jry_url` key used to be read here as a fallback, and the
        // backend sent neither, so no campaign link ever opened.
        if PushPayloadKeys.isJoryio(userInfo),
           let deepLink = userInfo[PushPayloadKeys.deepLink] as? String,
           !deepLink.isEmpty {
            handleDeepLink(deepLink)
        }

        completionHandler()
    }

    /// Track push notification click via backend endpoint
    private func trackPushClick(trackingId: String) async {
        do {
            try await networkClient.trackPushClick(trackingId: trackingId)
            logger.info("Tracked push click successfully")

            // Trigger in-app campaign sync after push click
            // This allows showing related in-app messages (e.g., coupon details after push about 20% off)
            await inAppMessaging?.syncCampaigns()
            logger.debug("Triggered in-app sync after push click")
        } catch {
            logger.error("Failed to track push click: \(error.localizedDescription)")
        }
    }

    /// Handle notification content (for silent push or background processing)
    private func handleNotificationContent(userInfo: [AnyHashable: Any]) async {
        // Check for silent push data sync
        if let syncType = userInfo[PushPayloadKeys.sync] as? String {
            logger.debug("Processing silent push sync: \(syncType)")

            switch syncType {
            case "campaigns", "in_app":
                // This branch used to log "Syncing campaigns" and DO NOTHING -
                // the comment said trigger, and there was no call. A silent
                // push woke the app and it went straight back to sleep.
                logger.debug("Silent push: syncing in-app campaigns")
                await Joryio.shared.syncInAppCampaigns()
            default:
                // Named rather than silently ignored: an unknown type means the
                // backend and the SDK disagree. A "user_attributes" branch used
                // to sit here as a no-op (audit 2026-09-26, I14); the backend
                // never sends it and Android has never had it, so it is gone.
                logger.debug("Unknown jry_sync type: \(syncType)")
            }
        }
    }

    /// Handle deep link
    private func handleDeepLink(_ deepLink: String) {
        guard let url = URL(string: deepLink) else {
            logger.error("Invalid deep link URL: \(deepLink)")
            return
        }

        logger.info("Opening deep link: \(deepLink)")

        Task { @MainActor in
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
            } else {
                logger.error("Cannot open deep link: \(deepLink)")
            }
        }
    }

    // MARK: - Badge Management

    /// Update app badge count
    func updateBadgeCount(_ count: Int) {
        Task { @MainActor in
            UIApplication.shared.applicationIconBadgeNumber = count
            logger.debug("Updated badge count to: \(count)")
        }
    }

    /// Clear app badge
    func clearBadge() {
        updateBadgeCount(0)
    }

    // MARK: - Public API

    func permissionStatus() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Joryio.pushPermissionStatus(settings.authorizationStatus)
    }

    /// Check if push notifications are enabled - exactly when the permission
    /// status is `granted` (provisional and ephemeral included).
    func isPushEnabled() async -> Bool {
        await permissionStatus() == "granted"
    }

    /// Get notification settings
    func getNotificationSettings() async -> UNNotificationSettings {
        let center = UNUserNotificationCenter.current()
        return await center.notificationSettings()
    }

    /// Unregister from push notifications - on the BACKEND first, then with
    /// the OS.
    ///
    /// This used to stop at `UIApplication.unregisterForRemoteNotifications()`
    /// and a local delete. The server kept the token as reachable and went on
    /// sending to it; Android and web have always called
    /// `POST /v1/push/unregister`. Best-effort: the local state is cleared
    /// whether or not the request succeeds, because the user asked to stop.
    ///
    /// DURABLE (SDK contract 22): the decision is stored, and the token the OS
    /// hands over on later launches is kept but not registered, until the app
    /// calls `registerPushToken(_:)` or `requestPushPermission()` again.
    func unregister() {
        storage.setPushUnregistered(true)
        forgetToken(alsoWithOS: true)
    }

    /// `wipeData()`: the token is removed on the server and on the device, and
    /// the device then stays off push until the app asks again
    /// (`registerPushToken(_:)` or `requestPushPermission()`) - the same on
    /// every Joryio SDK. A token the OS hands over on a later launch is kept
    /// but not registered, so an erasure is not silently undone at next launch.
    func wipe() {
        storage.setPushUnregistered(true)
        forgetToken(alsoWithOS: false)
        storage.clearReportedPushPermission()
    }

    /// Unregistering from the OS - replaced in tests, which have no
    /// UIApplication.
    var unregisterWithOS: () -> Void = {
        DispatchQueue.main.async { UIApplication.shared.unregisterForRemoteNotifications() }
    }

    private func forgetToken(alsoWithOS: Bool) {
        // Captured BEFORE anything is cleared: the server files the token
        // under this identity.
        let token = deviceToken ?? storage.getDeviceToken()
        // A withdrawal: the user held while tracking was not allowed (D-b),
        // else the identified one.
        let userId = identityManager.withdrawalUserId()
        let anonymousId = identityManager.getAnonymousId()

        deviceToken = nil
        storage.clearDeviceToken()
        storage.clearRegisteredPushKey()

        if let token {
            let request = UnregisterPushTokenRequest(userId: userId, anonymousId: anonymousId, token: token, platform: "ios")
            if let data = try? JSONEncoder().encode(request), let body = String(data: data, encoding: .utf8) {
                // Kept and sent even when opted out, consent denied or after
                // wipeData() - a withdrawal (contract v4, 36).
                unregisterOutbox.add(OutboxEntry(kind: .pushUnregister, path: "/v1/push/unregister", body: body, userId: userId,
                                                 anonymousId: anonymousId, withdrawal: true))
                unregisterOutbox.kick(force: true)
            }
        }
        if alsoWithOS { unregisterWithOS() }
        logger.info("Unregistered from push notifications")
    }
}

// MARK: - UNUserNotificationCenterDelegate

/// The SDK becomes the notification-center delegate at initialize(), and it
/// used to do so by simply REPLACING whatever the app had set - with no
/// forwarding. An app with its own push stack (Firebase Messaging, another
/// vendor, its own handling) stopped receiving taps, and `willPresent` showed
/// every foreground notification, other providers' included.
///
/// Now: the previous delegate is kept, the SDK acts only on Joryio payloads
/// (marker `joryio`), and everything else is forwarded untouched.
extension PushNotificationManager: UNUserNotificationCenterDelegate {
    /// Handle notification when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        guard PushPayloadKeys.isJoryio(userInfo) else {
            if let previous = previousDelegate,
               previous.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))) {
                previous.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
            } else {
                // No owner: iOS's own default for a foreground notification.
                completionHandler([])
            }
            return
        }

        logger.debug("Will present Joryio notification in foreground")
        completionHandler([.banner, .list, .sound, .badge])
    }

    /// Handle notification tap
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard PushPayloadKeys.isJoryio(userInfo) else {
            if let previous = previousDelegate,
               previous.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))) {
                previous.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
            } else {
                completionHandler()
            }
            return
        }
        didReceiveNotificationResponse(response, completionHandler: completionHandler)
    }

    /// The SDK has no settings screen of its own; the app's delegate decides.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        openSettingsFor notification: UNNotification?
    ) {
        previousDelegate?.userNotificationCenter?(center, openSettingsFor: notification)
    }
}
