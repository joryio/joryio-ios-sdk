import Foundation
import UIKit

/// Manages in-app messaging campaigns
class InAppMessagingManager {
    private let networkClient: NetworkClient
    private let storage: StorageManager
    private let identityManager: IdentityManager
    private let sessionManager: SessionManager
    private let logger: Logger

    // All mutable state below is shared across concurrent Tasks (foreground
    // sync, push-tap sync, event triggers, the host app's own calls). Every
    // read/write goes through `stateLock`, so the check-then-set of
    // `isDisplaying` is atomic (no two messages at once) and the dictionaries
    // can't hit an exclusive-access crash.
    private let stateLock = NSLock()
    private var activeCampaigns: [InAppCampaign] = []
    private var displayedCampaigns: Set<String> = []
    private var campaignImpressions: [String: [Date]] = [:]
    private var lastSyncTime: Date?
    private var isDisplaying = false
    /// Which campaign holds the display slot, so only that one can free it.
    private var slotCampaignId: String?
    /// The campaign a HOST renderer currently holds, until it reports
    /// displayed or dismissed (see trackHostImpression).
    private var hostHeldCampaignId: String?
    /// Bumped by clear(): a delayed display or a follow-up evaluation that
    /// wakes after a reset finds a different generation and does nothing.
    private var generation = 0
    /**
     Is a sync IN FLIGHT right now?

     Distinct from `lastSyncTime`, and both are needed. `lastSyncTime` is only
     written once the response comes back, so it says nothing about the window
     between issuing a request and receiving it - and that window is where two
     callers collide.

     Observed on production 2026-08-31: every launch produced a PAIR of
     `/v1/in-app/sync` requests 40ms apart. The web SDK has always claimed an
     in-flight flag before its request (`isSyncing`).
     */
    private var isSyncing = false
    /**
     Bumped whenever the answer a sync in flight would bring has become
     WRONG: reset(), wipeData(), identify(), a consent or opt-out change. A
     response that started under an older value is discarded (SDK contract
     26) - it used to install the previous user's campaigns for the next one.
     */
    private var syncEpoch = 0
    /**
     Bumped by `invalidate()` - identify() without a reset, an opt-out, a
     consent change - and by clear(). A message waiting on its display delay
     checks it when it wakes: one claimed for the previous identity, or
     before the person opted out, is not shown (contract v4, 43; scan 4,
     M5). Separate from `generation`, which also decides who may free the
     display slot: a message already ON SCREEN keeps the slot until it is
     dismissed.
     */
    private var displayEpoch = 0
    /// The host reported `displayed` for the campaign it holds: it keeps the
    /// display slot until it reports `dismissed` (no 30-second fallback).
    private var hostReportedDisplayed = false
    /// One per hand-off, so a fallback timer can only release the hand-off
    /// it was started for.
    private var hostHoldToken = 0
    /// A forced sync was asked for while one was in flight. That request
    /// used to be skipped, so the in-flight (stale) answer won; it now runs
    /// right after.
    private var syncAgainRequested = false

    // Configuration
    /// Minimum seconds between AUTOMATIC syncs (foreground, launch). From
    /// `InAppConfig.syncInterval`, which used to be accepted and ignored while
    /// a hardcoded 300 applied. A forced sync (identify, reset, a watched
    /// attribute, a push tap) bypasses it.
    private let syncInterval: TimeInterval
    /// `InAppConfig.enabled`. False: no sync, no display, nothing reported.
    private let enabled: Bool
    private let callbacks: InAppCallbacks

    /// Minimum gap between DIFFERENT campaigns, in seconds. A default the sync
    /// response overwrites with the workspace's configured gap.
    private var minDelayBetweenMessages: TimeInterval = 3

    /// Attributes that a differential-sync campaign is waiting on.
    private var watchedAttributes: Set<String> = []
    private var lastDisplayTime: Date?

    /// May the SDK talk to the server about in-app at all right now? False
    /// while opted out or while tracking consent is not granted: no sync, no
    /// impressions. Set by the SDK facade.
    var canSync: () -> Bool = { true }

    /// Run `body` while holding `stateLock`. NOT reentrant - never call another
    /// `withState` (or a locking method) from inside `body`.
    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// See InAppConfig.allowHtmlJsInAppMessages. Passed in rather than read
    /// from a global so the display path has no way to forget to check it.
    private let allowHtmlJsInAppMessages: Bool

    init(
        networkClient: NetworkClient,
        storage: StorageManager,
        identityManager: IdentityManager,
        sessionManager: SessionManager,
        logger: Logger,
        allowHtmlJsInAppMessages: Bool = false,
        enabled: Bool = true,
        syncInterval: TimeInterval = InAppConfig.defaultSyncInterval,
        callbacks: InAppCallbacks = InAppCallbacks()
    ) {
        self.networkClient = networkClient
        self.storage = storage
        self.identityManager = identityManager
        self.sessionManager = sessionManager
        self.logger = logger
        self.allowHtmlJsInAppMessages = allowHtmlJsInAppMessages
        self.enabled = enabled
        self.syncInterval = max(0, syncInterval)
        self.callbacks = callbacks

        loadCachedData()
    }

    // MARK: - Campaign Sync

    /// Sync in-app campaigns from backend.
    /// - Parameter force: skip the `syncInterval` throttle. Used when the
    ///   answer has just changed - identify, reset, a watched attribute, a
    ///   push tap. The in-flight guard still applies.
    func syncCampaigns(force: Bool = false) async {
        guard enabled else {
            logger.debug("In-app messaging is disabled (InAppConfig.enabled = false); not syncing")
            return
        }
        guard canSync() else {
            logger.debug("Not syncing in-app campaigns: opted out or consent not granted")
            return
        }
        let sessionId = sessionManager.getSessionId()

        // Check AND CLAIM in one locked block, exactly like the display slot in
        // evaluateAndDisplay. Reading the guard and taking it in separate steps
        // is what let two callers through.
        let claim = withState { () -> (skip: String?, epoch: Int) in
            if isSyncing {
                // Forced: the answer has changed; run again once this one is
                // done rather than letting the in-flight answer stand.
                if force { syncAgainRequested = true }
                return ("a sync is already in flight", syncEpoch)
            }
            if !force, let lastSync = lastSyncTime, Date().timeIntervalSince(lastSync) < syncInterval {
                return ("last sync was too recent", syncEpoch)
            }
            isSyncing = true
            return (nil, syncEpoch)
        }
        if let skipReason = claim.skip {
            logger.debug("Skipping sync, \(skipReason)")
            return
        }

        var stale = false
        do {
            // Released on EVERY exit - a sync that fails must not wedge the flag on.
            defer { withState { isSyncing = false } }
            stale = await performSync(sessionId: sessionId, epoch: claim.epoch)
        }

        // Read AFTER the release: a forced request that came in before it set
        // the flag; one that came in after it found the guard free and ran
        // its own sync.
        let again: Bool = withState {
            let again = syncAgainRequested
            syncAgainRequested = false
            return again
        }
        if again || stale {
            await syncCampaigns(force: true)
        }
    }

    /// The answer a sync in flight would bring, and a display waiting on its
    /// delay, are no longer the right ones: identify(), an opt-out or opt-in,
    /// a consent change. See `syncEpoch` and `displayEpoch`.
    func invalidate() {
        withState {
            syncEpoch += 1
            displayEpoch += 1
        }
    }

    /// - Returns: true when the answer was discarded as stale, so the caller
    ///   asks again for the current identity.
    @discardableResult
    private func performSync(sessionId: String, epoch: Int) async -> Bool {
        do {
            let request = SessionSyncRequest(
                userId: identityManager.getUserId() ?? "",
                anonymousId: identityManager.getAnonymousId(),
                sessionId: sessionId,
                attributes: identityManager.getUserAttributes(),
                // Only what the server has not acknowledged. Everything else
                // is already in the stored profile.
                pendingAttributes: identityManager.pending.pendingAttributes(),
                // Derived from the live flag, not hardcoded, so the server's
                // picture cannot drift from what this manager will actually do
                // when a campaign arrives. hostCapabilities wins when a host
                // renders: the list below describes THIS SDK's views.
                capabilities: hostCapabilities ?? (allowHtmlJsInAppMessages
                    ? ["content.native", "content.html"]
                    : ["content.native"])
            )

            logger.debug("Syncing in-app campaigns...")
            let response = try await networkClient.syncInAppCampaigns(request)

            if response.success {
                let current: Bool = withState {
                    guard syncEpoch == epoch else { return false }
                    activeCampaigns = response.campaigns
                    lastSyncTime = Date()
                    // Collect what differential-sync campaigns watch;
                    // setAttributes re-syncs when one of them changes.
                    watchedAttributes = Set(
                        response.campaigns
                            .filter { $0.evaluationMode == "differential-sync" }
                            .flatMap { $0.watchedAttributes ?? [] }
                    )
                    // The workspace's configured gap between campaigns, in SECONDS.
                    if let gap = response.delayBetweenCampaigns, gap >= 0 {
                        minDelayBetweenMessages = TimeInterval(gap)
                    }
                    return true
                }
                guard current else {
                    logger.debug("Discarding an in-app sync answer that started before a reset, identify or consent change")
                    return true
                }

                storage.cacheCampaigns(response.campaigns)
                logger.info("Synced \(response.campaigns.count) in-app campaigns")

                await evaluateAndDisplay()
            } else {
                logger.error("Campaign sync failed: \(response.error ?? "Unknown error")")
            }
        } catch {
            logger.error("Failed to sync campaigns: \(error.localizedDescription)")
        }
        return false
    }

    // MARK: - Campaign Evaluation

    /// Evaluate the campaigns that display ON SYNC and show the best one.
    private func evaluateAndDisplay() async {
        await displayFirstEligible(from: { Self.displaysOnSync($0) })
    }

    /**
     The ONE path to the screen.

     Every trigger - sync, an event, a push tap, an attribute threshold - goes
     through here, so every one of them is subject to the same gates: the
     single display slot, the gap between campaigns, the show-once default, the
     frequency cap, and impression recording.

     The event, push-tap and threshold triggers used to call presentCampaign
     directly. They skipped all of that: a "3 per day" campaign triggered by
     `add_to_cart` displayed every time the event fired, two messages could
     stack, and nothing was counted, so reporting showed zero displays for a
     message users saw constantly.
     */
    private func displayFirstEligible(from matches: (InAppCampaign) -> Bool) async {
        guard enabled, canSync() else { return }

        // Atomically decide whether we may display and, if so, claim the slot.
        // The display epoch the claim was made in (see `displayEpoch`).
        var claimEpoch = 0
        let claimed: (campaign: InAppCampaign, generation: Int)? = withState {
            guard !isDisplaying else {
                logger.debug("Already displaying a message, skipping evaluation")
                return nil
            }

            // Check minimum delay between messages
            if let lastDisplay = lastDisplayTime,
               Date().timeIntervalSince(lastDisplay) < minDelayBetweenMessages {
                logger.debug("Too soon since last message")
                return nil
            }

            // `displayedCampaigns` is a PERSISTED show-once-ever set. When a
            // campaign carries a frequency cap, THE CAP DECIDES; the show-once
            // default applies only to campaigns that specify nothing.
            let eligibleCampaigns = activeCampaigns
                .filter { $0.frequencyCap != nil || !displayedCampaigns.contains($0.id) }
                .filter { matches($0) }
                .filter { isEligibleForDisplayLocked($0) }
                .sorted { $0.priority > $1.priority }

            guard let campaign = eligibleCampaigns.first else {
                return nil
            }

            // Claim the display slot before releasing the lock. The slot only:
            // the frequency budget and the show-once record are spent when
            // the message is DISPLAYED (SDK contract 17), not here. Spending
            // them at the claim counted a message handed to a host that never
            // drew it, and one whose display delay was cut short by a reset.
            isDisplaying = true
            slotCampaignId = campaign.id
            lastDisplayTime = Date()
            claimEpoch = displayEpoch
            return (campaign, generation)
        }

        guard let claimed else {
            logger.debug("No eligible campaigns to display")
            return
        }
        let campaign = claimed.campaign
        let claimGeneration = claimed.generation

        logger.info("Displaying campaign: \(campaign.name) (\(campaign.type.rawValue))")

        // RENDER FIRST, then report. An impression means the view was actually
        // put on screen (or handed to the host that draws it).
        let outcome = await presentCampaign(campaign, generation: claimGeneration, displayEpoch: claimEpoch)

        switch outcome {
        case .presentedBySDK(let shown):
            // The SDK drew it, so the SDK reports it - and spends the budget.
            // Exactly one `displayed`.
            withState { recordDisplayedLocked(campaignId: campaign.id) }
            await trackImpression(campaignId: shown.id, kind: .display)
            fireCallback { $0.onMessageDisplay?(shown) }

        case .handedToHost:
            // The HOST reports `displayed` through trackInAppImpression, and
            // that report is what spends the budget. The SDK used to send its
            // own as well, so every host-rendered message counted twice.
            break

        case .notShown:
            // Release the slot, so a failed render does not lock in-app
            // messaging up. Nothing else to undo: nothing was spent.
            //
            // The release is here, once, for EVERY way presentation can fail.
            // The re-check branch (`reevaluateBeforeDisplay`) used to have
            // none, and one "no longer eligible" answer left `isDisplaying`
            // set for the rest of the process.
            //
            // ONLY if the slot is still this claim's. A message whose display
            // delay was cut short by reset() wakes up AFTER the next user's
            // message took the slot; releasing it then let a third message
            // stack on top of that one.
            withState { releaseSlotLocked(campaignId: campaign.id, generation: claimGeneration) }
        }
    }

    /// Spend the frequency budget and the show-once record for a message that
    /// was actually displayed. Caller MUST hold `stateLock`.
    private func recordDisplayedLocked(campaignId: String) {
        displayedCampaigns.insert(campaignId)
        recordImpressionLocked(campaignId: campaignId)
    }

    /// Free the display slot if `campaignId` (claimed in `generation`) still
    /// holds it. Caller MUST hold `stateLock`.
    private func releaseSlotLocked(campaignId: String, generation claimGeneration: Int) {
        guard generation == claimGeneration, slotCampaignId == campaignId else { return }
        isDisplaying = false
        slotCampaignId = nil
    }

    /**
     Does this campaign display on SYNC, or is it waiting for something?

     Displays on sync: no triggers at all (the historical default), or an
     `immediate` trigger. Anything waiting on an event, an attribute threshold
     or a push tap must not. Unknown trigger types WAIT rather than display.
     */
    static func displaysOnSync(_ campaign: InAppCampaign) -> Bool {
        guard let triggers = campaign.triggers, !triggers.isEmpty else { return true }
        return triggers.contains { $0.type == "immediate" }
    }

    /// Check if campaign is eligible for display based on frequency cap.
    /// Reads `campaignImpressions`; the caller MUST already hold `stateLock`.
    private func isEligibleForDisplayLocked(_ campaign: InAppCampaign) -> Bool {
        guard let frequencyCap = campaign.frequencyCap else {
            return true // No frequency cap
        }

        let impressions = campaignImpressions[campaign.id] ?? []

        // nil window = ALL TIME ('once' / 'lifetime' / 'session').
        let recentImpressions: [Date]
        if let windowSeconds = Self.parseTimeWindow(frequencyCap.timeWindow) {
            let cutoffTime = Date().addingTimeInterval(-windowSeconds)
            recentImpressions = impressions.filter { $0 > cutoffTime }
        } else {
            recentImpressions = impressions
        }

        // nil max = UNLIMITED.
        if let maxImpressions = frequencyCap.maxImpressions,
           recentImpressions.count >= maxImpressions {
            logger.debug("Campaign \(campaign.id) has reached frequency cap")
            return false
        }

        if let minDelay = frequencyCap.minDelayBetweenImpressions,
           let lastImpression = impressions.last {
            let timeSinceLastImpression = Date().timeIntervalSince(lastImpression)
            if timeSinceLastImpression < TimeInterval(minDelay) {
                logger.debug("Campaign \(campaign.id) min delay not met")
                return false
            }
        }

        return true
    }

    /**
     Seconds in a frequency-cap window, or `nil` for ALL TIME.

     The vocabulary is shared with the backend and the other SDKs - see
     backend `common/in-app-frequency-window.ts`. `min` is minutes and `m` is
     months, checked longest-first: "30min" ends with "m" too.
     */
    static func parseTimeWindow(_ timeWindow: String) -> TimeInterval? {
        let w = timeWindow.trimmingCharacters(in: .whitespaces).lowercased()

        switch w {
        case "once", "lifetime", "session":
            // 'session' is all-time here on purpose: counting MORE impressions
            // caps harder, the safe direction for a control against over-messaging.
            return nil
        case "day": return 86400
        case "week": return 604800
        case "month": return 2_592_000
        default: break
        }

        // Longest suffix first. "min" before "m", "mo" before "m".
        let units: [(String, TimeInterval)] = [
            ("min", 60),
            ("mo", 2_592_000),
            ("h", 3600),
            ("d", 86400),
            ("w", 604800),
            ("m", 2_592_000),
        ]
        for (suffix, seconds) in units where w.hasSuffix(suffix) {
            let numeric = String(w.dropLast(suffix.count))
            // Clamped: a server-supplied "9999999999999999d" must not trap.
            guard let parsed = Double(numeric), parsed > 0 else { break }
            return min(parsed, 3_650_000) * seconds
        }

        // Unparseable. One day, matching the backend.
        return 86400
    }

    // MARK: - Campaign Display

    enum PresentOutcome {
        case presentedBySDK(InAppCampaign)
        case handedToHost
        case notShown
    }

    /**
     Fetch a re-check campaign's content, re-verifying eligibility server-side.

     Returns nil when the user no longer qualifies OR the request fails. Both
     mean SHOW NOTHING, including offline.
     */
    private func resolveForDisplay(_ campaign: InAppCampaign) async -> InAppCampaign? {
        let epoch = withState { syncEpoch }
        do {
            let request = ResolveRequest(
                userId: identityManager.getUserId() ?? "",
                anonymousId: identityManager.getAnonymousId(),
                sessionId: sessionManager.getSessionId(),
                campaignId: campaign.id,
                attributes: identityManager.getUserAttributes(),
                pendingAttributes: identityManager.pending.pendingAttributes()
            )
            let response = try await networkClient.resolveInAppCampaign(request)
            // Asked for the previous user: their answer is not this one's.
            guard withState({ syncEpoch == epoch }) else {
                logger.debug("Discarding a re-check answer that started before a reset, identify or consent change")
                return nil
            }
            guard response.eligible, let resolved = response.campaign else {
                logger.info("Campaign \(campaign.id) not displayed: re-check said no")
                return nil
            }
            return resolved
        } catch {
            logger.warn("Re-check failed for \(campaign.id); not displaying: \(error.localizedDescription)")
            return nil
        }
    }

    /// Builds and shows the message view, so it MUST run on the main actor.
    /// The display slot has already been claimed by `displayFirstEligible`,
    /// which also releases it for every `.notShown` - nothing here touches it.
    @MainActor
    private func presentCampaign(_ campaign: InAppCampaign, generation claimGeneration: Int, displayEpoch claimEpoch: Int) async -> PresentOutcome {
        // Re-check mode: this campaign arrived WITHOUT content. Ask the server.
        var campaign = campaign
        if campaign.reevaluateBeforeDisplay == true {
            guard let resolved = await resolveForDisplay(campaign) else { return .notShown }
            campaign = resolved
        }

        let hostRenderer = withState { onMessageReadyHandler }

        // HTML runs in this SDK's web view only when the integration opted in.
        // THE FLAG IS ABOUT THIS SDK'S WEB VIEW, so it applies only when THIS
        // SDK is going to draw: with a host renderer set, the host decides what
        // it can draw (and declared it in hostCapabilities). Android passes the
        // flag into its presenter and never gates the handoff; this matches.
        let onMessageReady = hostRenderer
        if onMessageReady == nil {
            var isHtml = true
            if case .native = campaign.content { isHtml = false }
            if isHtml && !allowHtmlJsInAppMessages {
                logger.warn(
                    "Campaign \(campaign.id) is an HTML in-app message, but "
                        + "InAppConfig.allowHtmlJsInAppMessages is false and no host "
                        + "renderer is set - not displaying it."
                )
                return .notShown
            }
        }

        // Display delay, in SECONDS: applied after every eligibility gate and
        // before the presenter, so nothing is on screen during it.
        if let delaySeconds = campaign.delay, delaySeconds > 0 {
            logger.debug("Campaign \(campaign.id) waits \(delaySeconds)s before display")
            try? await Task.sleep(nanoseconds: Self.nanoseconds(seconds: Double(delaySeconds)))

            // The app may have reset (logout) while we waited; showing the
            // previous user's message to the next one is the failure to avoid.
            let stillCurrent = withState { generation == claimGeneration }
            guard !Task.isCancelled, stillCurrent else {
                return .notShown
            }
        }

        // Shown only while it may be (contract v4, 43): not after an
        // opt-out, a consent change or an identify() since the claim, and
        // not while consent is pending or denied. Returning .notShown frees
        // the slot.
        guard canSync(), withState({ displayEpoch == claimEpoch }) else {
            logger.debug("Campaign \(campaign.id) not shown: identity, opt-out or consent changed, or sending is not allowed")
            return .notShown
        }

        // A host callback wins; the SDK must not also draw the message.
        if let onMessageReady {
            // Bookkeeping BEFORE host code runs (SDK contract 34): whatever the
            // host's callback does, the slot is released by the fallback.
            let holdToken: Int = withState {
                hostHeldCampaignId = campaign.id
                hostReportedDisplayed = false
                hostHoldToken += 1
                return hostHoldToken
            }
            scheduleHostReleaseFallback(campaignId: campaign.id, generation: claimGeneration, holdToken: holdToken)
            onMessageReady(campaign)
            return .handedToHost
        }

        // Pick the window the user is actually LOOKING AT. A React Native app
        // has several UIWindows, and `.first` frequently returns one that is
        // not on screen (2026-08-12). Only the SDK's own renderer needs one.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow }
            ?? scene?.windows.first { !$0.isHidden && $0.alpha > 0 }
            ?? scene?.windows.first

        guard let window else {
            logger.error("No window available to display campaign")
            return .notShown
        }

        guard let presenter = Joryio.shared.inAppPresenter else {
            logger.debug("No in-app presenter (JoryioUI not linked); not displaying \(campaign.id)")
            return .notShown
        }

        // Trust the presenter's answer rather than assuming success.
        guard presenter.present(campaign: campaign, in: window, delegate: self) else {
            logger.warn("Campaign \(campaign.id) has no renderable content; skipping")
            return .notShown
        }

        return .presentedBySDK(campaign)
    }

    /// A host that never reports must not lock in-app messaging up for the
    /// rest of the process. 30 seconds is longer than any render takes and
    /// shorter than the next foreground sync. Seconds; tests shorten it.
    static var hostReportTimeoutSeconds: Double = 30
    /// A host that reported `displayed` and never `dismissed` (it reported
    /// only `clicked`, or forgot) holds the slot at most this long - the
    /// same 5 minutes as Android's per-campaign claim (SDK contract v5, 57).
    /// It used to hold it for the rest of the process: no other in-app
    /// message of any campaign was shown until the app restarted.
    static var hostDisplayedTimeoutSeconds: Double = 300

    private func scheduleHostReleaseFallback(campaignId: String, generation claimGeneration: Int, holdToken: Int) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, Self.hostReportTimeoutSeconds) * 1_000_000_000))
            guard let self else { return }
            enum Outcome { case released, displayed, gone }
            let outcome: Outcome = self.withState {
                guard self.generation == claimGeneration, self.hostHoldToken == holdToken,
                      self.hostHeldCampaignId == campaignId else { return .gone }
                // Reported `displayed`: the message is on screen, and holds the
                // slot until `dismissed` - up to the longer bound below.
                if self.hostReportedDisplayed { return .displayed }
                self.hostHeldCampaignId = nil
                self.releaseSlotLocked(campaignId: campaignId, generation: claimGeneration)
                return .released
            }
            switch outcome {
            case .gone:
                return
            case .released:
                self.logger.warn(
                    "In-app message \(campaignId) was handed to your callback and never reported as "
                        + "displayed or dismissed; releasing the display slot. Call "
                        + "trackInAppImpression(campaignId:action:) with \"displayed\" and \"dismissed\"."
                )
            case .displayed:
                let remaining = max(0, Self.hostDisplayedTimeoutSeconds - Self.hostReportTimeoutSeconds)
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                let released: Bool = self.withState {
                    guard self.generation == claimGeneration, self.hostHoldToken == holdToken,
                          self.hostHeldCampaignId == campaignId else { return false }
                    self.hostHeldCampaignId = nil
                    self.hostReportedDisplayed = false
                    self.releaseSlotLocked(campaignId: campaignId, generation: claimGeneration)
                    return true
                }
                if released {
                    self.logger.warn(
                        "In-app message \(campaignId) was reported displayed and never dismissed; releasing "
                            + "the display slot after \(Int(Self.hostDisplayedTimeoutSeconds))s. Report \"dismissed\" "
                            + "whenever the message leaves the screen, including after a click."
                    )
                }
            }
        }
    }

    // MARK: - Host-rendered display

    /// Set by Joryio.setInAppMessageCallback. When present, the host app draws
    /// the message and the SDK does not.
    var onMessageReady: ((InAppCampaign) -> Void)? {
        get { withState { onMessageReadyHandler } }
        set { withState { onMessageReadyHandler = newValue } }
    }
    private var onMessageReadyHandler: ((InAppCampaign) -> Void)?

    /// What the HOST can render, when the host renders instead of this SDK.
    /// Nil means nobody has said, and the SDK keeps describing its own
    /// renderer - correct while the SDK is the one drawing. Matches Android.
    var hostCapabilities: [String]? {
        get { withState { _hostCapabilities } }
        set { withState { _hostCapabilities = newValue } }
    }
    private var _hostCapabilities: [String]?

    /// ISO-8601 UTC with milliseconds - the format the web SDK sends and the
    /// backend canonicalises to (SDK contract 7: UTC with a real `Z`).
    /// A server-sent wait as nanoseconds, clamped to one day: a huge value
    /// overflowed the conversion and crashed the app (scan 5, N3).
    static func nanoseconds(seconds: Double) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(min(seconds, 86_400) * 1_000_000_000)
    }

    static func isoTimestamp() -> String { WireJSON.timestamp() }

    /// What a host reports, mapped onto the backend's vocabulary
    /// (backend `common/events/in-app-action-vocabulary.ts`). The same
    /// synonyms the server accepts; anything else is a client bug.
    static func impressionKind(for action: String) -> ImpressionKind? {
        switch action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "displayed", "display", "impression", "shown", "viewed": return .display
        case "clicked", "click", "cta_click", "link_click", "button_click", "tapped": return .click
        case "dismissed", "dismiss", "closed": return .dismiss
        case "converted", "convert", "conversion": return .convert
        default: return nil
        }
    }

    /// The host stops rendering: the SDK's own renderer takes over again, and
    /// a message the host held no longer occupies the display slot.
    func clearHostRenderer() {
        withState {
            onMessageReadyHandler = nil
            _hostCapabilities = nil
            if let held = hostHeldCampaignId {
                hostHeldCampaignId = nil
                hostReportedDisplayed = false
                releaseSlotLocked(campaignId: held, generation: generation)
            }
        }
    }

    /// Public entry point for a host that rendered the message itself.
    /// - Parameter elementId: which button or link, for a click.
    func trackHostImpression(campaignId: String, action: String, elementId: String? = nil) {
        guard let kind = Self.impressionKind(for: action) else {
            logger.error(
                "trackInAppImpression: unknown action '\(action)'. Use \"displayed\", \"clicked\", "
                    + "\"dismissed\" or \"converted\" - the server records nothing else."
            )
            return
        }
        // `displayed` spends the budget (contract 17); only `dismissed` frees
        // the slot - a message still on screen holds it (v4 43, scan 4 M6;
        // Android too), even while sending is blocked.
        if kind == .display || kind == .dismiss {
            withState {
                if kind == .display { recordDisplayedLocked(campaignId: campaignId) }
                if kind == .display, hostHeldCampaignId == campaignId { hostReportedDisplayed = true }
                if kind == .dismiss, hostHeldCampaignId == campaignId {
                    hostHeldCampaignId = nil
                    hostReportedDisplayed = false
                    releaseSlotLocked(campaignId: campaignId, generation: generation)
                }
            }
        }
        Task { await trackImpression(campaignId: campaignId, kind: kind, elementId: elementId) }
    }

    // MARK: - Impression Tracking

    enum ImpressionKind {
        case display, click, dismiss, convert

        /// The canonical spelling the backend prefers - one per meaning.
        var wireAction: String {
            switch self {
            case .display: return "displayed"
            case .click: return "clicked"
            case .dismiss: return "dismissed"
            case .convert: return "converted"
            }
        }
    }

    /// Track an impression to the backend.
    ///
    /// `action` is ALWAYS a vocabulary word. A click used to send the click's
    /// NAME as the action (`buy_now`, a `data-action` value), which the server
    /// refuses as `unknown_action` - so no in-app click from iOS was ever
    /// recorded. The name now rides in `elementId` (SDK contract 9).
    private func trackImpression(campaignId: String, kind: ImpressionKind, elementId: String? = nil) async {
        guard canSync() else {
            logger.debug("In-app \(kind.wireAction) not reported: opted out or consent not granted")
            return
        }
        let sessionId = sessionManager.getSessionId()

        // Echo the delivery token the server issued for this message.
        let deliveryToken = withState { activeCampaigns.first { $0.id == campaignId }?.deliveryToken }

        let nowIso = Self.isoTimestamp()
        let request = TrackImpressionRequest(
            campaignId: campaignId,
            userId: identityManager.getUserId() ?? "",
            anonymousId: identityManager.getAnonymousId(),
            sessionId: sessionId,
            action: kind.wireAction,
            displayedAt: kind == .display ? nowIso : nil,
            clicked: kind == .click ? true : nil,
            clickedAt: kind == .click ? nowIso : nil,
            dismissedAt: kind == .dismiss ? nowIso : nil,
            converted: kind == .convert ? true : nil,
            convertedAt: kind == .convert ? nowIso : nil,
            deliveryToken: deliveryToken,
            elementId: kind == .click ? Self.normalizedElementId(elementId) : nil
        )

        do {
            try await networkClient.trackImpression(request)
            logger.debug("Tracked \(kind.wireAction) for campaign \(campaignId)")
        } catch {
            logger.error("Failed to track impression: \(error.localizedDescription)")
        }
    }

    /// The backend bounds `elementId` at 128 characters; a generic name says
    /// nothing about WHICH element, so it is not sent.
    static func normalizedElementId(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if ["click", "clicked", "button", "link", "cta_click", "link_click", "button_click"].contains(raw.lowercased()) {
            return nil
        }
        return String(raw.prefix(128))
    }

    /// Build the request a click sends - exposed for tests, which assert the
    /// wire shape without a server.
    static func clickRequest(campaignId: String, elementId: String?, sessionId: String, anonymousId: String) -> TrackImpressionRequest {
        TrackImpressionRequest(
            campaignId: campaignId,
            userId: "",
            anonymousId: anonymousId,
            sessionId: sessionId,
            action: ImpressionKind.click.wireAction,
            clicked: true,
            clickedAt: isoTimestamp(),
            elementId: normalizedElementId(elementId)
        )
    }

    /// Record impression locally for frequency capping.
    /// Mutates `campaignImpressions`; the caller MUST already hold `stateLock`.
    private func recordImpressionLocked(campaignId: String) {
        var impressions = campaignImpressions[campaignId] ?? []
        impressions.append(Date())

        // Keep only last 100 impressions per campaign
        if impressions.count > 100 {
            impressions = Array(impressions.suffix(100))
        }

        campaignImpressions[campaignId] = impressions
        saveImpressionData()
    }

    private func fireCallback(_ body: @escaping (InAppCallbacks) -> Void) {
        let callbacks = self.callbacks
        DispatchQueue.main.async { body(callbacks) }
    }

    private func campaign(withId id: String) -> InAppCampaign? {
        withState { activeCampaigns.first { $0.id == id } }
    }

    // MARK: - Persistence

    private func loadCachedData() {
        // Load cached campaigns
        let cached = storage.getCachedCampaignsSafe()
        var impressions: [String: [Date]] = [:]
        var displayed: Set<String> = []

        if let data = UserDefaults.standard.data(forKey: "jry_campaign_impressions"),
           let decoded = try? JSONDecoder().decode([String: [Date]].self, from: data) {
            impressions = decoded
        }

        if let data = UserDefaults.standard.data(forKey: "jry_displayed_campaigns"),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            displayed = decoded
        }

        withState {
            activeCampaigns = cached
            campaignImpressions = impressions
            displayedCampaigns = displayed
        }
        logger.debug("Loaded \(cached.count) cached campaigns")
    }

    /// Caller MUST hold `stateLock`.
    private func saveImpressionData() {
        if let encoded = try? JSONEncoder().encode(campaignImpressions) {
            UserDefaults.standard.set(encoded, forKey: "jry_campaign_impressions")
        }

        if let encoded = try? JSONEncoder().encode(displayedCampaigns) {
            UserDefaults.standard.set(encoded, forKey: "jry_displayed_campaigns")
        }
    }

    // MARK: - Public API

    /// Trigger campaign evaluation manually
    func evaluateCampaigns() async {
        await evaluateAndDisplay()
    }

    /// Clear all displayed campaigns (for testing)
    func resetDisplayedCampaigns() {
        withState {
            displayedCampaigns.removeAll()
            saveImpressionData()
        }
        logger.debug("Reset displayed campaigns")
    }

    /// Clear all in-app state on identity reset/logout so the next user never
    /// sees the previous user's displayed campaigns or impression history -
    /// and cancel anything waiting (a display delay, a follow-up evaluation).
    func clear() {
        withState {
            generation += 1
            syncEpoch += 1
            displayEpoch += 1
            hostReportedDisplayed = false
            displayedCampaigns.removeAll()
            campaignImpressions.removeAll()
            activeCampaigns.removeAll()
            isDisplaying = false
            slotCampaignId = nil
            hostHeldCampaignId = nil
            lastDisplayTime = nil
            lastSyncTime = nil
            watchedAttributes = []
            saveImpressionData()
        }
        do {
            try storage.clearCampaignCache()
        } catch {
            logger.debug("Could not clear the campaign cache: \(error.localizedDescription)")
        }
        logger.debug("Cleared in-app messaging state")
    }

    /// Diagnostics for tests: whether the single display slot is held.
    var isDisplayingForTesting: Bool { withState { isDisplaying } }

    /// Diagnostics for tests: displays recorded against the frequency budget.
    func impressionCountForTesting(_ campaignId: String) -> Int {
        withState { campaignImpressions[campaignId]?.count ?? 0 }
    }

    /// Test seam: the gap between different campaigns.
    func setMinimumGapForTesting(_ seconds: TimeInterval) {
        withState { minDelayBetweenMessages = seconds }
    }

    /// Diagnostics for tests: the campaigns this device holds.
    var activeCampaignIdsForTesting: [String] { withState { activeCampaigns.map(\.id) } }

    /// Test seam: replace the campaigns without a server.
    func setActiveCampaignsForTesting(_ campaigns: [InAppCampaign]) {
        withState { activeCampaigns = campaigns }
    }
}

/// The host-app callbacks from `InAppConfig`, carried as one value.
struct InAppCallbacks {
    var onMessageDisplay: ((InAppMessage) -> Void)?
    var onMessageClick: ((InAppMessage, String) -> Void)?
    var onMessageDismiss: ((InAppMessage) -> Void)?
}

// MARK: - Message View Delegate

extension InAppMessagingManager: InAppMessageViewDelegate {
    func messageViewDidAppear(_ campaignId: String) {
        logger.debug("Message appeared: \(campaignId)")
    }

    func messageViewDidDismiss(_ campaignId: String) {
        logger.debug("Message dismissed: \(campaignId)")
        let (gap, currentGeneration) = withState { () -> (TimeInterval, Int) in
            // Only the message holding the slot frees it: a view left over
            // from before a reset() must not free the next user's message.
            releaseSlotLocked(campaignId: campaignId, generation: generation)
            return (minDelayBetweenMessages, generation)
        }
        if let campaign = campaign(withId: campaignId) {
            fireCallback { $0.onMessageDismiss?(campaign) }
        }

        Task { [weak self] in
            guard let self else { return }
            await self.trackImpression(campaignId: campaignId, kind: .dismiss)
            // Evaluate the next campaign after the configured gap - unless a
            // reset happened meanwhile.
            try? await Task.sleep(nanoseconds: Self.nanoseconds(seconds: gap))
            guard self.withState({ self.generation == currentGeneration }) else { return }
            await self.evaluateAndDisplay()
        }
    }

    func messageViewClicked(_ campaignId: String, action: String, url: String?) {
        logger.debug("Click on campaign \(campaignId): \(action)")
        if let campaign = campaign(withId: campaignId) {
            fireCallback { $0.onMessageClick?(campaign, action) }
        }

        Task {
            await trackImpression(campaignId: campaignId, kind: .click, elementId: action)

            // http(s) only - the view already filtered, this is defence in
            // depth. `javascript:`/`data:`/`file:` URLs are how authored
            // content escapes its container.
            guard
                let urlString = url,
                let target = URL(string: urlString),
                let scheme = target.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else { return }

            await MainActor.run {
                UIApplication.shared.open(target)
            }
        }
    }
}

// MARK: - Message View Protocol

public protocol InAppMessageViewDelegate: AnyObject {
    func messageViewDidAppear(_ campaignId: String)
    func messageViewDidDismiss(_ campaignId: String)
    /// A click inside the message. `action` is the element's own name (a
    /// button id, a link's `data-action`) - reported as `elementId`, never as
    /// the impression action. `url` is set for link activations, which the
    /// manager opens externally.
    func messageViewClicked(_ campaignId: String, action: String, url: String?)
}

// MARK: - Triggers

extension InAppMessagingManager {
    /**
     The user just tapped a push - show anything waiting on that.

     Syncs FIRST, deliberately: a push tap is a moment where the freshest
     eligibility matters, and the tap has just brought the app to the
     foreground anyway.

     This used to call `sync()` - which, with no such method on this class,
     resolved to the C library's `sync(2)` (flush file-system buffers). It
     compiled, did nothing useful, and the campaign list was never refreshed.
     */
    func onPushTapped() async {
        await syncCampaigns(force: true)
        await displayFirstEligible(from: { campaign in
            (campaign.triggers ?? []).contains { $0.type == "push_notification_tap" }
        })
    }

    /**
     An event just happened in the app - show anything waiting on it, through
     the same gates as every other display (see displayFirstEligible).

     NO server eligibility re-check: the server sent this campaign because the
     user matched it. The device evaluates only what the server cannot know.
     */
    func onEventTracked(_ eventName: String, properties: [String: Any]) {
        guard !eventName.isEmpty, enabled else { return }
        let candidates = withState { activeCampaigns }
        let hasMatch = candidates.contains { campaign in
            (campaign.triggers ?? []).contains { t in
                t.type == "event" && t.event == eventName && Self.triggerFilterMatches(t, properties)
            }
        }
        guard hasMatch else { return }
        Task {
            // One per event: a single action should not stack modals.
            await displayFirstEligible(from: { campaign in
                (campaign.triggers ?? []).contains { t in
                    t.type == "event" && t.event == eventName && Self.triggerFilterMatches(t, properties)
                }
            })
        }
    }

    /// A trigger's own property condition. No condition matches on the event
    /// name alone; an UNKNOWN operator does not match - failing closed.
    static func triggerFilterMatches(_ trigger: InAppTrigger, _ properties: [String: Any]) -> Bool {
        guard let attribute = trigger.attribute else { return true }
        let actual = properties[attribute]
        let expected = trigger.value?.value
        switch trigger.`operator` {
        case nil, "equals", "eq":
            return String(describing: actual ?? "") == String(describing: expected ?? "")
        case "not_equals", "neq":
            return String(describing: actual ?? "") != String(describing: expected ?? "")
        case "greater_than", "gt":
            return Self.number(actual) > Self.number(expected)
        case "less_than", "lt":
            return Self.number(actual) < Self.number(expected)
        case "contains":
            return String(describing: actual ?? "").contains(String(describing: expected ?? ""))
        case "exists":
            return actual != nil
        default:
            return false
        }
    }

    private static func number(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String, let d = Double(s) { return d }
        return .nan
    }

    /**
     Re-evaluate when an attribute changes.

     FAST PATH: a campaign already on this device whose attribute_threshold is
     now satisfied displays with no round trip. SLOW PATH: a WATCHED attribute
     can make the user newly eligible for a campaign the device has never been
     sent - only the server can know, so that forces a sync. Unwatched
     attributes cost nothing.
     */
    func attributesDidChange(_ keys: [String]) {
        guard enabled else { return }
        checkAttributeThresholds(keys)

        let watched = withState { watchedAttributes }
        guard !watched.isEmpty, keys.contains(where: { watched.contains($0) }) else { return }

        Task { await syncCampaigns(force: true) }
    }

    /// Display a held campaign whose `attribute_threshold` is now met -
    /// against the CURRENT value, through the common display gates.
    private func checkAttributeThresholds(_ changedKeys: [String]) {
        guard !changedKeys.isEmpty else { return }
        let attributes = identityManager.getUserAttributes()
        let matches: (InAppCampaign) -> Bool = { campaign in
            (campaign.triggers ?? []).contains { t in
                t.type == "attribute_threshold"
                    && t.attribute.map { changedKeys.contains($0) } == true
                    && Self.triggerFilterMatches(t, attributes)
            }
        }
        let candidates = withState { activeCampaigns }
        guard candidates.contains(where: matches) else { return }
        Task { await displayFirstEligible(from: matches) }
    }
}
