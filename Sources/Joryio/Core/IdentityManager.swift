import Foundation

/// Manages user identity and attributes.
///
/// Thread-safe: `identity` is read on the network and in-app tasks and written
/// from whatever thread the host app calls identify/reset/setAttributes on, so
/// every access goes through `lock`. It used to be a bare `var`, which is a
/// data race on a struct holding a dictionary - a crash, not just a stale read.
class IdentityManager {
    private let storage: StorageManager
    private let logger: Logger
    private let lock = NSLock()
    private var identity: UserIdentity

    /// The held (D-b) user id as last read or written - `withdrawalUserId()`
    /// is asked for every request while a token is kept, and each answer
    /// used to be a Keychain round-trip (scan 7, N3). Nil: not known yet.
    /// Written only together with the Keychain, under `heldLock`; a read
    /// that could not reach the Keychain (before the first unlock) is not
    /// cached, so the next one tries again.
    private let heldLock = NSLock()
    private var heldCache: String??

    /// Attributes written locally but not acknowledged by the server. Lives
    /// here because it is identity state, and because both the SDK facade (to
    /// flush it) and the in-app sync (to send it) already hold this manager.
    /// Built in init rather than `lazy`: lazy initialisation is not
    /// thread-safe, and this is first touched from concurrent tasks.
    let pending: PendingAttributes

    init(
        storage: StorageManager,
        logger: Logger,
        initialUserId: String? = nil,
        initialAnonymousId: String? = nil
    ) {
        self.storage = storage
        self.logger = logger
        self.pending = PendingAttributes(storage: storage)

        // A caller-supplied anonymous id SEEDS the stored one, exactly as the
        // web SDK does: it is used for this run, and persisted only when
        // nothing is stored yet, so an id set once at init survives the app
        // dropping the option later.
        if let seed = initialAnonymousId, !seed.isEmpty, !storage.hasStoredAnonymousId() {
            storage.setAnonymousId(seed)
        }

        // Attributes are the PII trait bag and are NEVER persisted at rest:
        // start empty each session (the server is the source of truth). Kept
        // in memory only for in-session reads.
        let anonymousId = (initialAnonymousId?.isEmpty == false ? initialAnonymousId : nil)
            ?? storage.getAnonymousId()
        let userId = initialUserId ?? storage.getUserId()
        // An explicit user id at init wins over one kept from an earlier
        // launch while tracking was off (D-b; SDK contract v6, 63).
        if let explicit = initialUserId, !explicit.isEmpty {
            storage.setHeldUserId(nil)
            heldCache = .some(nil)
        }

        self.identity = UserIdentity(
            userId: userId,
            anonymousId: anonymousId,
            attributes: [:]
        )

        // One-time purge: delete any attributes bag persisted by an older SDK
        // build so previously-stored PII is removed from existing installs.
        storage.clearUserAttributes()

        logger.info("Identity initialized - User: \(userId ?? "anonymous"), AnonymousId: \(anonymousId)")
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Identity Access

    func getIdentity() -> UserIdentity {
        withLock { identity }
    }

    func getUserId() -> String? {
        withLock { identity.userId }
    }

    func getAnonymousId() -> String {
        withLock { identity.anonymousId }
    }

    func getUserAttributes() -> UserAttributes {
        withLock {
            identity.attributes.reduce(into: [:]) { result, pair in
                result[pair.key] = pair.value.value
            }
        }
    }

    /// Get a single attribute's current value (nil if unset).
    func getAttribute(_ key: String) -> Any? {
        withLock { identity.attributes[key]?.value }
    }

    // MARK: - Identification

    func identify(userId: String) {
        logger.info("Identifying user: \(userId)")
        withLock { identity.userId = userId }
        storage.setUserId(userId)
        writeHeldUserId(nil)
    }

    /// identify() while consent is denied or the person opted out (owner
    /// decision D-b): kept on the device ONLY so withdrawals carry the
    /// right user. Not the identity: getUserId() does not return it, and
    /// nothing is tracked or written to a profile under it.
    func holdUserId(_ userId: String) {
        writeHeldUserId(userId)
    }

    func getHeldUserId() -> String? {
        heldLock.lock()
        defer { heldLock.unlock() }
        if let cached = heldCache { return cached }
        let read = storage.readHeldUserId()
        if read.reliable { heldCache = .some(read.userId) }
        return read.userId
    }

    func clearHeldUserId() {
        writeHeldUserId(nil)
    }

    private func writeHeldUserId(_ userId: String?) {
        heldLock.lock()
        defer { heldLock.unlock() }
        storage.setHeldUserId(userId)
        heldCache = .some(userId)
    }

    /// The user a WITHDRAWAL is sent for: one held while tracking was not
    /// allowed (D-b), else the identified user.
    func withdrawalUserId() -> String? {
        getHeldUserId() ?? getUserId()
    }

    /// The in-memory trait bag (identify() of a different user: the previous
    /// user's attributes are not the next one's).
    func clearTraitBag() {
        withLock { identity.attributes = [:] }
    }

    // MARK: - Attributes Management

    func setAttributes(_ attributes: UserAttributes) {
        logger.debug("Setting \(attributes.count) user attributes")
        // In memory only, NOT persisted (PII stays off durable storage).
        withLock {
            for (key, value) in attributes {
                identity.attributes[key] = AnyCodable(value)
            }
        }
    }

    func setAttribute(_ key: String, value: Any) {
        setAttributes([key: value])
    }

    func incrementAttribute(_ key: String, by value: Double) {
        logger.debug("Incrementing attribute: \(key) by \(value)")
        withLock {
            let current: Double
            if let number = identity.attributes[key]?.value as? NSNumber {
                current = number.doubleValue
            } else {
                current = 0
            }
            identity.attributes[key] = AnyCodable(current + value)
        }
    }

    func unsetAttribute(_ key: String) {
        logger.debug("Unsetting attribute: \(key)")
        _ = withLock { identity.attributes.removeValue(forKey: key) }
    }

    // MARK: - Reset

    /// Logout: a NEW anonymous identity, not just a cleared user id.
    ///
    /// The anonymous id used to survive reset, so everything the next person
    /// did on this device - before they signed in, or if they never did - was
    /// filed under the previous user's anonymous profile and merged into that
    /// person on the server. A shared device is exactly where reset() is
    /// called. SDK contract 6; matches web and Android.
    func reset() {
        logger.info("Resetting user identity")

        storage.setUserId(nil)
        writeHeldUserId(nil)
        storage.clearUserAttributes()
        storage.clearAnonymousId()
        let newAnonymousId = storage.getAnonymousId()

        withLock {
            identity.userId = nil
            identity.attributes = [:]
            identity.anonymousId = newAnonymousId
        }

        // Un-acked writes belonged to the OUTGOING user - sending them after a
        // reset would attribute one person's traits to the next.
        pending.clear()

        logger.debug("Identity reset complete; new anonymous id \(newAnonymousId)")
    }

    /// After `wipeData()` has cleared storage: drop the in-memory anonymous id
    /// and take the freshly minted one, so the wiped install reports under a
    /// new identity rather than the one it was asked to erase. A caller-supplied
    /// seed (`JoryioConfig.anonymousId`) is not re-applied: the seed must not
    /// outlive the data it seeded. Matches Android's `onDataWiped()`.
    func onDataWiped() {
        writeHeldUserId(nil)
        let fresh = storage.getAnonymousId()
        withLock {
            identity.anonymousId = fresh
            identity.userId = nil
            identity.attributes = [:]
        }
        logger.info("Anonymous ID regenerated after wipe: \(fresh)")
    }
}
