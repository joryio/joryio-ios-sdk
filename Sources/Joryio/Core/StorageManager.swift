import Foundation
import SQLite

/// Manages local storage for events, user data, and SDK state
class StorageManager {
    private let sdkKey: String
    private let logger: Logger
    private let userDefaults: UserDefaults
    private let keychain: SecureStore
    private let kcPendingAttributesAccount = "pending_attributes"
    private var db: Connection?

    // Keychain account names for the identity-linking secrets. These are stored
    // in the Keychain (device-only, after-first-unlock) rather than UserDefaults.
    // See getUserId/getDeviceToken below for the rationale on WHY only these two
    // move to the Keychain while anonymousId/session/deviceId stay in UserDefaults.
    private let kcUserIdAccount = "user_id"
    private let kcDeviceTokenAccount = "device_token"

    // Legacy UserDefaults key for the APNs token (was global/unprefixed in
    // PushNotificationManager). Kept only so we can migrate + clean it up.
    private let legacyDeviceTokenKey = "jry_device_token"

    // Serial queue that owns ALL SQLite access. SQLite.swift's Connection is not
    // safe for concurrent use; funnelling every DB operation through one serial
    // queue both serializes access and keeps the work off the main thread (the
    // queue manager's flush now runs off the main actor and blocks on this
    // queue instead of blocking the UI thread). Only LEAF db methods enter this
    // queue — never call one wrapped method from inside another (would deadlock).
    private let dbQueue = DispatchQueue(label: "com.joryio.sdk.storage")

    // UserDefaults keys
    private let anonymousIdKey: String
    private let userIdKey: String
    private let sessionKey: String
    private let attributesKey: String
    private let deviceIdKey: String

    /// Overrides where the SQLite file lives. Tests only: production always
    /// uses Application Support/Joryio.
    private let databaseDirectoryOverride: URL?

    init(
        sdkKey: String,
        logger: Logger,
        databaseDirectory: URL? = nil,
        userDefaults: UserDefaults = .standard,
        secureStore: SecureStore? = nil
    ) {
        self.sdkKey = sdkKey
        self.logger = logger
        self.databaseDirectoryOverride = databaseDirectory
        self.userDefaults = userDefaults
        self.keychain = secureStore ?? KeychainHelper(sdkKey: sdkKey, logger: logger)

        // Prefix keys with SDK key for multi-instance support. `jry_`, the
        // product's prefix everywhere (D-c, 2026-10-07): an older name was
        // still here, visible in every integrator's preferences plist. Nothing
        // had shipped under it, so there is no migration.
        let prefix = "jry_\(sdkKey)"
        self.anonymousIdKey = "\(prefix)_anonymous_id"
        self.userIdKey = "\(prefix)_user_id"
        self.sessionKey = "\(prefix)_session"
        self.attributesKey = "\(prefix)_attributes"
        self.deviceIdKey = "\(prefix)_device_id"

        initializeDatabase()

        // MUST run before anything reads the Keychain (the migration below,
        // IdentityManager's userId read). See wipeKeychainIfReinstalled.
        wipeKeychainIfReinstalled()

        // One-time migration of the identity-linking secrets out of UserDefaults
        // and into the Keychain. UserDefaults is already Data-Protection encrypted
        // at rest, so this is defense-in-depth + consistency: existing installs'
        // plaintext-in-UserDefaults copies are copied to the Keychain and then
        // removed from UserDefaults.
        migrateSecretToKeychain(userDefaultsKey: userIdKey, keychainAccount: kcUserIdAccount)
        migrateSecretToKeychain(userDefaultsKey: legacyDeviceTokenKey, keychainAccount: kcDeviceTokenAccount)
    }

    // MARK: - Reinstall detection

    /**
     Keychain items SURVIVE an app uninstall; UserDefaults does not.

     So after delete-and-reinstall the userId, the APNs token and any queued
     attribute writes of the previous install came straight back: a fresh
     install reported as the last signed-in user, and a person who deleted the
     app to "log out" was not logged out. The fix is the usual one - a marker in
     UserDefaults, which the uninstall removes. Marker absent means this is a
     new install, and every Keychain item this SDK owns is deleted before
     anything reads one.

     An install upgrading from a build that predates the marker is NOT a
     reinstall: it still has its anonymous id in UserDefaults, which is the
     evidence that the defaults domain survived. Only then is the marker
     written without wiping.
     */
    private var installMarkerKey: String { "jry_\(sdkKey)_install_marker" }

    private func wipeKeychainIfReinstalled() {
        // A launch BEFORE THE FIRST UNLOCK after a reboot (a background push,
        // a location wake) cannot read UserDefaults: every key reads as absent,
        // the install marker included, and the Keychain items are locked. That
        // launch looked exactly like a fresh install, so the SDK deleted the
        // signed-in user's Keychain items. Decide nothing until the device is
        // unlocked; the next launch decides.
        guard keychain.isProtectedDataAvailable() else {
            logger.debug("Protected data is not available yet (device not unlocked since boot); reinstall check deferred")
            return
        }
        guard !userDefaults.bool(forKey: installMarkerKey) else { return }
        if !hasStoredAnonymousId() {
            keychain.removeAll()
            logger.debug("New install: cleared Keychain items left by a previous install")
        }
        userDefaults.set(true, forKey: installMarkerKey)
    }

    // MARK: - Database Setup

    private func initializeDatabase() {
        // Create the connection + tables on the DB queue so the Connection is
        // only ever touched from that queue.
        dbQueue.sync { _ = openDatabaseLocked() }
    }

    /**
     The connection, opened now if it is not open yet. Caller is ON `dbQueue`.

     A launch before the first unlock after a reboot (a background push, a
     location wake) cannot open a file protected until first authentication,
     and the SDK used to keep that nil connection for the whole process - every
     event was then lost until the app was killed. The SDK now defers its whole
     initialisation until protected data is available (scan 3, S1); this lazy
     reopen is the second line, for any other transient open failure.
     */
    private func openDatabaseLocked() -> Connection? {
        if let db { return db }
        do {
            let dbURL = try getDatabaseURL()

            // Migrate an existing DB from the old Documents location before
            // we open the connection, so queued events survive the move.
            migrateLegacyDatabaseIfNeeded(to: dbURL)

            let connection = try Connection(dbURL.path)
            self.db = connection
            try createTables()

            // Encrypt at rest with an explicit protection class and keep the
            // DB out of device backups. Done AFTER the file exists on disk.
            applyAtRestProtection(to: dbURL)

            logger.debug("Database initialized at \(dbURL.path)")
            return connection
        } catch {
            self.db = nil
            logger.error("Failed to open the database (will retry on next use): \(error.localizedDescription)")
            return nil
        }
    }

    /// Directory that holds the SQLite DB: Application Support/Joryio.
    ///
    /// Application Support (rather than Documents) keeps the event DB out of the
    /// user-visible Documents area. Combined with the explicit
    /// isExcludedFromBackup flag set in applyAtRestProtection(), the queue DB
    /// never lands in an iCloud/iTunes backup.
    private func getDatabaseDirectory() throws -> URL {
        if let override = databaseDirectoryOverride {
            try FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Joryio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func getDatabaseURL() throws -> URL {
        return try getDatabaseDirectory().appendingPathComponent("joryio.db")
    }

    /// Old (pre-hardening) location: Documents/joryio.db.
    private func legacyDatabaseURL() -> URL? {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }
        return documents.appendingPathComponent("joryio.db")
    }

    /// If a DB exists at the legacy Documents path and none exists at the new
    /// Application Support path, MOVE it so existing installs keep their queued
    /// events. Falls back gracefully (log + continue with a fresh DB) if the
    /// move fails.
    private func migrateLegacyDatabaseIfNeeded(to newURL: URL) {
        let fm = FileManager.default
        guard let legacyURL = legacyDatabaseURL() else { return }
        guard fm.fileExists(atPath: legacyURL.path) else { return }
        guard !fm.fileExists(atPath: newURL.path) else { return }

        do {
            try fm.moveItem(at: legacyURL, to: newURL)
            // Move any SQLite sidecar files (WAL/SHM) alongside the DB if present.
            for suffix in ["-wal", "-shm"] {
                let oldSidecar = URL(fileURLWithPath: legacyURL.path + suffix)
                let newSidecar = URL(fileURLWithPath: newURL.path + suffix)
                if fm.fileExists(atPath: oldSidecar.path) && !fm.fileExists(atPath: newSidecar.path) {
                    try? fm.moveItem(at: oldSidecar, to: newSidecar)
                }
            }
            logger.info("Migrated event DB from Documents to Application Support")
        } catch {
            // Non-fatal: a new empty DB will be created at newURL.
            logger.error("Failed to migrate legacy event DB, starting fresh: \(error.localizedDescription)")
        }
    }

    /// Exclude the DB directory from backups and set the file protection class.
    private func applyAtRestProtection(to dbURL: URL) {
        let fm = FileManager.default

        // Exclude the whole Joryio directory (and thus the DB + its WAL/SHM
        // sidecar files) from iCloud/iTunes device backups.
        if let dir = try? getDatabaseDirectory() {
            var dirURL = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            do {
                try dirURL.setResourceValues(values)
            } catch {
                logger.error("Failed to exclude DB directory from backup: \(error.localizedDescription)")
            }
        }

        #if os(iOS)
        // Explicit protection class: completeUntilFirstUserAuthentication.
        //
        // NOT .complete: the SDK writes events from background / app-terminate
        // flushes when the device may be locked. .complete would make the file
        // inaccessible while locked and break those background writes.
        // .completeUntilFirstUserAuthentication keeps the file encrypted at rest
        // yet readable/writable once the device has been unlocked at least once
        // since boot — the right trade-off for a background event queue.
        do {
            try fm.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: dbURL.path
            )
        } catch {
            logger.error("Failed to set DB file protection: \(error.localizedDescription)")
        }
        #endif
    }

    private func createTables() throws {
        guard let db = db else { return }

        // Events queue table
        let events = Table("events")
        let id = Expression<Int64>("id")
        let eventData = Expression<String>("event_data")
        let createdAt = Expression<Date>("created_at")

        try db.run(events.create(ifNotExists: true) { t in
            t.column(id, primaryKey: .autoincrement)
            t.column(eventData)
            t.column(createdAt)
        })

        // In-app campaigns cache
        let campaigns = Table("in_app_campaigns")
        let campaignId = Expression<String>("campaign_id")
        let campaignData = Expression<String>("campaign_data")
        let cachedAt = Expression<Date>("cached_at")

        try db.run(campaigns.create(ifNotExists: true) { t in
            t.column(campaignId, primaryKey: true)
            t.column(campaignData)
            t.column(cachedAt)
        })

        // Small key-value store for durable state too large for the Keychain:
        // the write outbox (identify, aliases, subscription changes).
        let kv = Table("kv")
        let kvKey = Expression<String>("key")
        let kvValue = Expression<String>("value")
        try db.run(kv.create(ifNotExists: true) { t in
            t.column(kvKey, primaryKey: true)
            t.column(kvValue)
        })

        logger.debug("Database tables created")
    }

    // MARK: - Anonymous ID

    func getAnonymousId() -> String {
        if let existingId = userDefaults.string(forKey: anonymousIdKey) {
            return existingId
        }

        let newId = UUID().uuidString
        userDefaults.set(newId, forKey: anonymousIdKey)
        logger.debug("Generated new anonymous ID: \(newId)")
        return newId
    }

    /// Whether an anonymous id has been persisted yet. Lets a caller-supplied
    /// id seed storage without `getAnonymousId()` generating one first.
    func hasStoredAnonymousId() -> Bool {
        return userDefaults.string(forKey: anonymousIdKey) != nil
    }

    func setAnonymousId(_ id: String) {
        userDefaults.set(id, forKey: anonymousIdKey)
    }

    /// Forget the stored anonymous id; the next `getAnonymousId()` mints a new
    /// one. Part of `wipeData()`, which erases the profile this id names.
    func clearAnonymousId() {
        userDefaults.removeObject(forKey: anonymousIdKey)
        logger.debug("Anonymous ID cleared")
    }

    // MARK: - Device ID

    func getDeviceId() -> String {
        if let existingId = userDefaults.string(forKey: deviceIdKey) {
            return existingId
        }

        let newId = UUID().uuidString
        userDefaults.set(newId, forKey: deviceIdKey)
        logger.debug("Generated new device ID: \(newId)")
        return newId
    }

    /// Forget the device id; the next `getDeviceId()` mints a new one. Part of
    /// `wipeData()`: the device id is the key the server's device row is
    /// filed under.
    func clearDeviceId() {
        userDefaults.removeObject(forKey: deviceIdKey)
    }

    // MARK: - User ID
    //
    // The userId is an identity-linking secret, so it lives in the Keychain
    // (encrypted at rest, device-only, available after first unlock) rather than
    // UserDefaults. anonymousId / session / deviceId deliberately STAY in
    // UserDefaults: they are already encrypted at rest by Data Protection, and
    // moving anonymous ids to the Keychain would change reinstall-persistence
    // semantics — Keychain items can survive an app uninstall, which would leak
    // an "anonymous" id across installs.

    func getUserId() -> String? {
        return keychain.getString(forKey: kcUserIdAccount)
    }

    func setUserId(_ userId: String?) {
        if let userId = userId {
            keychain.setString(userId, forKey: kcUserIdAccount)
            logger.debug("User ID set: \(userId)")
        } else {
            keychain.removeItem(forKey: kcUserIdAccount)
            logger.debug("User ID cleared")
        }
    }

    // MARK: - Registered push token

    /// The token+identity pair last CONFIRMED registered by the backend.
    ///
    /// Written only after a successful response: an optimistic marker would
    /// remember a FAILED registration as done and leave the device silently
    /// unreachable by push.
    func getRegisteredPushKey() -> String? {
        userDefaults.string(forKey: "joryio_registered_push_key")
    }

    func clearRegisteredPushKey() {
        userDefaults.removeObject(forKey: "joryio_registered_push_key")
    }

    func setRegisteredPushKey(_ value: String) {
        userDefaults.set(value, forKey: "joryio_registered_push_key")
    }

    // MARK: - Reported push permission

    /// The push-permission value most recently reported to the backend.
    ///
    /// Kept so the attribute is sent only when it CHANGES. Reporting on every
    /// launch and foreground would spend a request per app open restating a
    /// value that moves maybe twice in an install's lifetime. UserDefaults, not
    /// the Keychain: it is not a secret, and it should die with the app.
    func getReportedPushPermission() -> String? {
        userDefaults.string(forKey: "joryio_reported_push_permission")
    }

    func setReportedPushPermission(_ value: String) {
        userDefaults.set(value, forKey: "joryio_reported_push_permission")
    }

    func clearReportedPushPermission() {
        userDefaults.removeObject(forKey: "joryio_reported_push_permission")
    }

    // MARK: - Push unregistered by the app
    //
    // `unregisterPush()` is a decision, and it has to outlive the process. The
    // OS hands the app a token on EVERY launch (Apple asks apps to call
    // registerForRemoteNotifications each time), and the SDK registered that
    // token again - so an unregister lasted until the next launch. Cleared only
    // by an explicit `registerPushToken(_:)` or `requestPushPermission()`.
    private let pushUnregisteredKey = "joryio_push_unregistered"

    func isPushUnregistered() -> Bool {
        userDefaults.bool(forKey: pushUnregisteredKey)
    }

    func setPushUnregistered(_ value: Bool) {
        if value {
            userDefaults.set(true, forKey: pushUnregisteredKey)
        } else {
            userDefaults.removeObject(forKey: pushUnregisteredKey)
        }
    }

    // MARK: - APNs Device Token
    //
    // The APNs device token is an identity-linking, per-device secret and is
    // stored in the Keychain with ThisDeviceOnly accessibility (never synced to
    // iCloud Keychain, never migrated to another device via backup).

    // MARK: - Tracking opt-out
    //
    // PERSISTED. optOut() used to flip an in-memory flag only, so the next app
    // launch read the flag from config and the user was silently opted back in
    // - a consent bug, not a hygiene one. A withdrawal of consent has to
    // outlive the process that received it.
    //
    // Not PII (a boolean), so UserDefaults rather than the Keychain, and read
    // at init before anything is collected.
    //
    // NOT scoped by SDK key: rotating the SDK key - a new key in the next
    // app release - must not opt an opted-out user back in. The choice
    // belongs to the person on this device, not to a credential.
    static let optOutKey = "joryio_opted_out"

    func getOptedOut() -> Bool {
        userDefaults.bool(forKey: Self.optOutKey)
    }

    func setOptedOut(_ value: Bool) {
        userDefaults.set(value, forKey: Self.optOutKey)
    }

    // MARK: - Tracking consent (SDK contract 24, consent model A)
    //
    // Only `denied` is persisted. It is lifted ONLY by an explicit
    // `updateConsent(.granted)` or an explicit `trackingConsent: .granted` in
    // the config - never by a launch that simply passes no consent. `pending`
    // is never stored: it applies to one launch. Global, like the opt-out: a
    // decision of the person on this device, not of an SDK key.
    static let consentDeniedKey = "joryio_consent_denied"

    func getConsentDenied() -> Bool {
        userDefaults.bool(forKey: Self.consentDeniedKey)
    }

    func setConsentDenied(_ denied: Bool) {
        if denied {
            userDefaults.set(true, forKey: Self.consentDeniedKey)
        } else {
            userDefaults.removeObject(forKey: Self.consentDeniedKey)
        }
    }

    // MARK: - The opt-out record (SDK contract 33)
    //
    // The `tracking_opted_out` value the server last ACKNOWLEDGED. The record
    // is sent only when the opt-out differs from it, and retried until it is
    // acknowledged. Absent means the server holds no record: the same as
    // `false`, so an install that never opted out sends nothing.
    static let optOutMarkerAckedKey = "joryio_opt_out_marker_acked"

    func getOptOutMarkerAcked() -> Bool {
        userDefaults.bool(forKey: Self.optOutMarkerAckedKey)
    }

    func setOptOutMarkerAcked(_ value: Bool) {
        userDefaults.set(value, forKey: Self.optOutMarkerAckedKey)
    }

    // MARK: - Durable write outbox

    /// The identify / alias / subscription / opt-out-record outbox. In the
    /// SQLite file, which has the same protection class as the event queue
    /// and already holds the same ids. Nil when the database cannot be opened.
    func getValue(forKey key: String) -> String? {
        dbQueue.sync {
            guard let db = openDatabaseLocked() else { return nil }
            let kv = Table("kv")
            let kvKey = Expression<String>("key")
            let kvValue = Expression<String>("value")
            return (try? db.pluck(kv.filter(kvKey == key)))?[kvValue]
        }
    }

    /// Like `getValue`, but tells "nothing stored" from "could not read".
    /// The write outbox needs the difference: it used to read an unopenable
    /// database as an EMPTY outbox and then save over the stored one with
    /// its first new write (scan 4, M4).
    func readValue(forKey key: String) -> WriteOutbox.Load {
        dbQueue.sync {
            guard let db = openDatabaseLocked() else { return .unavailable }
            let kv = Table("kv")
            let kvKey = Expression<String>("key")
            let kvValue = Expression<String>("value")
            do {
                return .value(try db.pluck(kv.filter(kvKey == key))?[kvValue])
            } catch {
                logger.error("Failed to read \(key): \(error.localizedDescription)")
                return .unavailable
            }
        }
    }

    func setValue(_ value: String?, forKey key: String) {
        dbQueue.sync {
            guard let db = openDatabaseLocked() else { return }
            let kv = Table("kv")
            let kvKey = Expression<String>("key")
            let kvValue = Expression<String>("value")
            do {
                if let value {
                    try db.run(kv.insert(or: .replace, kvKey <- key, kvValue <- value))
                } else {
                    try db.run(kv.filter(kvKey == key).delete())
                }
            } catch {
                logger.error("Failed to store \(key): \(error.localizedDescription)")
            }
        }
    }

    /// Push unregisters the server has not acknowledged (SDK contract 22,
    /// scan 3 S2). In the Keychain: each one carries a device token, which
    /// the SDK keeps nowhere else.
    private let kcPendingPushUnregisterAccount = "pending_push_unregister"

    func getPendingPushUnregisters() -> String? {
        keychain.getString(forKey: kcPendingPushUnregisterAccount)
    }

    func setPendingPushUnregisters(_ json: String?) {
        if let json, !json.isEmpty {
            keychain.setString(json, forKey: kcPendingPushUnregisterAccount)
        } else {
            keychain.removeItem(forKey: kcPendingPushUnregisterAccount)
        }
    }

    // MARK: - Pending attribute writes (outbound queue)
    //
    // DELIBERATELY separate from the trait bag, which is never persisted. This
    // is not a cache of who the user is - it is UNDELIVERED WORK: the few keys
    // the app wrote that the server has not acknowledged. Lose it and the write
    // never happens; lose the trait bag and the server already has it.
    //
    // Keychain (device-only, after-first-unlock) rather than UserDefaults, for
    // the same reason the identity-linking secrets moved there. Cleared the
    // moment the server acks and purged on reset/opt-out, so it holds PII only
    // between a failed send and the next successful one.
    func getPendingAttributes() -> String? {
        return keychain.getString(forKey: kcPendingAttributesAccount)
    }

    func setPendingAttributes(_ json: String?) {
        guard let json, !json.isEmpty else {
            _ = keychain.setString("", forKey: kcPendingAttributesAccount)
            return
        }
        _ = keychain.setString(json, forKey: kcPendingAttributesAccount)
    }

    func clearPendingAttributes() {
        _ = keychain.setString("", forKey: kcPendingAttributesAccount)
    }

    // MARK: - Held user id (owner decision D-b, 2026-10-07)
    //
    // identify() made while consent is denied or the person opted out: no
    // network, no profile write, no tracking - the id is only kept so a
    // withdrawal (an unsubscribe, the opt-out record, a push unregister)
    // carries the right user. Keychain, like the user id itself.
    private let kcHeldUserIdAccount = "held_user_id"

    func getHeldUserId() -> String? {
        keychain.getString(forKey: kcHeldUserIdAccount)
    }

    /// The held user id, and whether the answer can be trusted: an absent
    /// item reads as nil, and so does a Keychain that is not readable yet
    /// (before the first unlock) - only the first is "no held user".
    func readHeldUserId() -> (userId: String?, reliable: Bool) {
        let value = keychain.getString(forKey: kcHeldUserIdAccount)
        return (value, value != nil || keychain.isProtectedDataAvailable())
    }

    func setHeldUserId(_ userId: String?) {
        if let userId {
            keychain.setString(userId, forKey: kcHeldUserIdAccount)
        } else {
            keychain.removeItem(forKey: kcHeldUserIdAccount)
        }
    }

    // MARK: - Retired SDK-authentication tokens (owner decision D-a)
    //
    // A logged-out user's token, kept bound to the writes and events that
    // user left queued until they are delivered or dropped - across a
    // restart too: in memory only, a process death between logout and the
    // queue draining sent them with no token and they were refused for good.
    // Keychain (this device only, after first unlock): it is a credential.
    private let kcRetiredAuthTokensAccount = "retired_auth_tokens"

    func getRetiredAuthTokens() -> String? {
        keychain.getString(forKey: kcRetiredAuthTokensAccount)
    }

    func setRetiredAuthTokens(_ json: String?) {
        if let json {
            keychain.setString(json, forKey: kcRetiredAuthTokensAccount)
        } else {
            keychain.removeItem(forKey: kcRetiredAuthTokensAccount)
        }
    }

    /// Does the event queue still hold an event of this user? A LIKE over the
    /// stored JSON: a false positive only keeps a token a little longer.
    func hasQueuedEvents(forUserId userId: String) -> Bool {
        guard let encodedId = try? JSONEncoder().encode([userId]),
              var fragment = String(data: encodedId, encoding: .utf8) else { return true }
        fragment = String(fragment.dropFirst().dropLast()) // ["x"] -> "x"
        let needle = "\"userId\":" + fragment
        let escaped = needle
            .replacingOccurrences(of: "!", with: "!!")
            .replacingOccurrences(of: "%", with: "!%")
            .replacingOccurrences(of: "_", with: "!_")
        return dbQueue.sync {
            guard let db = openDatabaseLocked() else { return true }
            let events = Table("events")
            let eventData = Expression<String>("event_data")
            let count = (try? db.scalar(events.filter(eventData.like("%\(escaped)%", escape: "!")).count)) ?? 1
            return count > 0
        }
    }

    func getDeviceToken() -> String? {
        return keychain.getString(forKey: kcDeviceTokenAccount)
    }

    func setDeviceToken(_ token: String) {
        keychain.setString(token, forKey: kcDeviceTokenAccount)
    }

    func clearDeviceToken() {
        keychain.removeItem(forKey: kcDeviceTokenAccount)
    }

    // MARK: - Secret Migration

    /// Copy a secret from UserDefaults into the Keychain once, then remove the
    /// UserDefaults copy. No-op if the value is absent or already in the Keychain.
    private func migrateSecretToKeychain(userDefaultsKey: String, keychainAccount: String) {
        guard let legacyValue = userDefaults.string(forKey: userDefaultsKey) else { return }
        if keychain.getString(forKey: keychainAccount) == nil {
            keychain.setString(legacyValue, forKey: keychainAccount)
        }
        userDefaults.removeObject(forKey: userDefaultsKey)
        logger.debug("Migrated secret '\(keychainAccount)' from UserDefaults to Keychain")
    }

    // MARK: - Session

    func getSession() -> SessionInfo? {
        guard let data = userDefaults.data(forKey: sessionKey),
              let session = try? JSONDecoder().decode(SessionInfo.self, from: data) else {
            return nil
        }
        return session
    }

    func setSession(_ session: SessionInfo) {
        guard let data = try? JSONEncoder().encode(session) else {
            logger.error("Failed to encode session")
            return
        }
        userDefaults.set(data, forKey: sessionKey)
        logger.debug("Session saved: \(session.sessionId)")
    }

    func clearSession() {
        userDefaults.removeObject(forKey: sessionKey)
        logger.debug("Session cleared")
    }

    // MARK: - User Attributes
    //
    // The user-attribute trait bag (email/phone/name/custom) is PII and is
    // NEVER persisted at rest — it is held in memory by IdentityManager for the
    // session only. The only durable operation kept here is a purge, used both
    // as a one-time cleanup on init and on reset()/logout, so any bag written
    // by an older SDK build is removed from existing installs.

    func clearUserAttributes() {
        userDefaults.removeObject(forKey: attributesKey)
        logger.debug("User attributes cleared")
    }

    // MARK: - Event Queue

    func enqueueEvent(_ event: Event) throws {
        // Encode off the queue (pure work), then do the write on the DB queue.
        let encoder = WireJSON.encoder()
        let jsonData = try encoder.encode(event)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw StorageError.encodingFailed
        }

        try dbQueue.sync {
            guard let db = openDatabaseLocked() else {
                throw StorageError.databaseNotInitialized
            }

            let events = Table("events")
            let eventData = Expression<String>("event_data")
            let createdAt = Expression<Date>("created_at")

            try db.run(events.insert(
                eventData <- jsonString,
                createdAt <- Date()
            ))

            logger.debug("Event enqueued: \(event.type)")
        }
    }

    /// A queued event as stored: its row id and the exact JSON it was
    /// encoded to. The flush sends the JSON verbatim (no decode/re-encode),
    /// and deletes by the row ids it sent - never "the first N rows", which
    /// removed the wrong events whenever a trim or another write changed the
    /// head of the queue while a batch was in flight.
    struct QueuedEvent {
        let id: Int64
        let json: String
    }

    func dequeueEvents(limit: Int) throws -> [Event] {
        let decoder = WireJSON.decoder()
        return try dequeueQueuedEvents(limit: limit).compactMap { row in
            row.json.data(using: .utf8).flatMap { try? decoder.decode(Event.self, from: $0) }
        }
    }

    func dequeueQueuedEvents(limit: Int) throws -> [QueuedEvent] {
        return try dbQueue.sync {
            guard let db = openDatabaseLocked() else {
                throw StorageError.databaseNotInitialized
            }

            let events = Table("events")
            let id = Expression<Int64>("id")
            let eventData = Expression<String>("event_data")

            var result: [QueuedEvent] = []
            for row in try db.prepare(events.order(id).limit(limit)) {
                result.append(QueuedEvent(id: row[id], json: row[eventData]))
            }

            logger.debug("Dequeued \(result.count) events")
            return result
        }
    }

    /// Delete exactly these rows. Ids already gone (trimmed meanwhile) are a
    /// no-op, which is what makes deleting after a send safe.
    func deleteEvents(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.sync {
            guard let db = openDatabaseLocked() else {
                throw StorageError.databaseNotInitialized
            }
            let events = Table("events")
            let id = Expression<Int64>("id")
            try db.run(events.filter(ids.contains(id)).delete())
            logger.debug("Deleted \(ids.count) events from queue")
        }
    }

    /// Drop the OLDEST rows until at most `maxSize` remain, and return how many
    /// were dropped. This is the only path that discards undelivered events:
    /// a failed send, however many times it fails, never does.
    @discardableResult
    func trimQueue(toMax maxSize: Int) throws -> Int {
        return try dbQueue.sync {
            guard let db = openDatabaseLocked() else {
                throw StorageError.databaseNotInitialized
            }
            let events = Table("events")
            let id = Expression<Int64>("id")
            let count = try db.scalar(events.count)
            let overflow = count - max(0, maxSize)
            guard overflow > 0 else { return 0 }
            let idsToDelete = try db.prepare(events.select(id).order(id).limit(overflow)).map { $0[id] }
            try db.run(events.filter(idsToDelete.contains(id)).delete())
            return idsToDelete.count
        }
    }

    func getQueueSize() -> Int {
        return dbQueue.sync {
            guard let db = openDatabaseLocked() else { return 0 }

            let events = Table("events")
            return (try? db.scalar(events.count)) ?? 0
        }
    }

    func clearQueue() throws {
        try dbQueue.sync {
            guard let db = openDatabaseLocked() else {
                throw StorageError.databaseNotInitialized
            }

            let events = Table("events")
            try db.run(events.delete())
            logger.debug("Event queue cleared")
        }
    }

    // MARK: - In-App Campaigns Cache

    func cacheCampaign(_ campaign: InAppCampaign) throws {
        let encoder = WireJSON.encoder()
        let jsonData = try encoder.encode(campaign)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw StorageError.encodingFailed
        }

        try dbQueue.sync {
            guard let db = openDatabaseLocked() else {
                throw StorageError.databaseNotInitialized
            }

            let campaigns = Table("in_app_campaigns")
            let campaignId = Expression<String>("campaign_id")
            let campaignData = Expression<String>("campaign_data")
            let cachedAt = Expression<Date>("cached_at")

            try db.run(campaigns.insert(or: .replace,
                campaignId <- campaign.id,
                campaignData <- jsonString,
                cachedAt <- Date()
            ))

            logger.debug("Campaign cached: \(campaign.id)")
        }
    }

    func getCachedCampaigns() throws -> [InAppCampaign] {
        return try dbQueue.sync {
            guard let db = openDatabaseLocked() else {
                throw StorageError.databaseNotInitialized
            }

            let campaigns = Table("in_app_campaigns")
            let campaignData = Expression<String>("campaign_data")

            var result: [InAppCampaign] = []
            let decoder = WireJSON.decoder()

            for row in try db.prepare(campaigns) {
                if let data = row[campaignData].data(using: .utf8),
                   let campaign = try? decoder.decode(InAppCampaign.self, from: data) {
                    result.append(campaign)
                }
            }

            logger.debug("Retrieved \(result.count) cached campaigns")
            return result
        }
    }

    /// Get cached campaigns (returns empty array on error, for convenience)
    func getCachedCampaignsSafe() -> [InAppCampaign] {
        do {
            return try getCachedCampaigns()
        } catch {
            logger.error("Failed to get cached campaigns: \(error.localizedDescription)")
            return []
        }
    }

    /// Cache multiple campaigns at once
    func cacheCampaigns(_ campaigns: [InAppCampaign]) {
        for campaign in campaigns {
            do {
                try cacheCampaign(campaign)
            } catch {
                logger.error("Failed to cache campaign \(campaign.id): \(error.localizedDescription)")
            }
        }
    }

    func clearCampaignCache() throws {
        try dbQueue.sync {
            guard let db = openDatabaseLocked() else {
                throw StorageError.databaseNotInitialized
            }

            let campaigns = Table("in_app_campaigns")
            try db.run(campaigns.delete())
            logger.debug("Campaign cache cleared")
        }
    }

    // MARK: - Clear All Data

    func clearAllData() {
        // Clear UserDefaults
        userDefaults.removeObject(forKey: anonymousIdKey)
        userDefaults.removeObject(forKey: userIdKey)
        userDefaults.removeObject(forKey: sessionKey)
        userDefaults.removeObject(forKey: attributesKey)

        // Clear Keychain-stored secrets (userId + APNs device token)
        keychain.removeItem(forKey: kcUserIdAccount)
        keychain.removeItem(forKey: kcDeviceTokenAccount)

        // Clear database
        do {
            try clearQueue()
            try clearCampaignCache()
        } catch {
            logger.error("Failed to clear database: \(error.localizedDescription)")
        }

        logger.info("All SDK data cleared")
    }

    // MARK: - Errors

    enum StorageError: Error {
        case databaseNotInitialized
        case encodingFailed
        case decodingFailed
    }
}
