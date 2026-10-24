import Foundation

/// Reason a customer-minted SDK-authentication JWT was rejected by the backend.
///
/// Mirrors the backend contract:
/// `401 { error: "sdk_authentication_error", reason: "missing"|"invalid"|"expired"|"sub_mismatch" }`.
public enum SdkAuthErrorReason: String {
    /// No `X-Joryio-Auth` header was present but the backend required one.
    case missing
    /// The token was malformed, had a bad signature, or failed verification.
    case invalid
    /// The token's `exp` has passed.
    case expired
    /// The token's `sub` does not match the identified user.
    case subMismatch = "sub_mismatch"
    /// The backend sent a reason string this SDK version does not recognise.
    case unknown

    /// Map a raw backend `reason` string onto the enum, defaulting to `.unknown`.
    init(backendReason: String?) {
        guard let raw = backendReason, let mapped = SdkAuthErrorReason(rawValue: raw) else {
            self = .unknown
            return
        }
        self = mapped
    }
}

/// Delivered to the app-supplied error handler when an ingest request is
/// rejected because of SDK authentication. The app should mint a fresh JWT and
/// call `Joryio.shared.setSdkAuthenticationToken(_:)` in response.
public struct SdkAuthError {
    /// Why the token was rejected.
    public let reason: SdkAuthErrorReason
    /// The ingest endpoint whose request was rejected (context for the app).
    public let endpoint: String
    /// Whether the SDK retried once with a refreshed token and still failed
    /// (or could not obtain a fresh token). When `true`, the request was left
    /// queued and no further automatic retry will happen for it this cycle.
    public let refreshExhausted: Bool
    /// The backend's ORIGINAL `reason` string, before it was mapped onto the
    /// enum above.
    ///
    /// Carried because `reason` collapses to `.unknown` for any value this SDK
    /// version does not know, which is precisely the case where a host most
    /// needs to see what the server actually said - a new backend reason is
    /// otherwise indistinguishable from a parse failure. Android has always
    /// exposed this; iOS parsed the string and threw it away.
    public let rawReason: String?

    public init(
        reason: SdkAuthErrorReason,
        endpoint: String,
        refreshExhausted: Bool,
        rawReason: String? = nil
    ) {
        self.reason = reason
        self.endpoint = endpoint
        self.refreshExhausted = refreshExhausted
        self.rawReason = rawReason
    }
}

/// Thread-safe holder for the SDK-authentication token and error handler.
///
/// The token is READ on the network thread (when building each ingest request)
/// and WRITTEN from the app thread (via `setSdkAuthenticationToken`), so every
/// access is guarded by a lock. A single shared instance is owned by `Joryio`
/// and handed to `NetworkClient`, so a token set through the public API is
/// immediately visible to in-flight and future requests.
final class SdkAuthTokenStore {
    /// Whether SDK authentication is on. When `false`, no header is ever
    /// attached and the refresh flow is inert.
    ///
    /// Turned on by config (`enableSdkAuthentication`) OR by supplying a
    /// token. It used to be fixed at init, so `setSdkAuthenticationToken` on
    /// an app that had not set the flag logged a warning and dropped the
    /// token - while Android, given the same call, opted in. Supplying a
    /// token is an unambiguous request to use it.
    ///
    /// Also on while a logged-out user's token is kept (SDK contract v6, 61):
    /// an app that turns authentication on only by setting a token at login
    /// starts the next process with the flag off, and a logout's leftovers
    /// went out with no token - refused and dropped - although the token
    /// they needed was right there in the Keychain.
    var enabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isEnabled || !retired.isEmpty
    }

    private let lock = NSLock()
    private var isEnabled: Bool
    private var token: String?
    private var handler: ((SdkAuthError) -> Void)?

    /// Where retired tokens are kept between launches (owner decision D-a:
    /// the Keychain). Nil: memory only (tests, and a store built before
    /// storage exists).
    private let persistRetired: ((String?) -> Void)?

    /// Seconds after it was retired before a token may be pruned for having
    /// nothing queued: an event tracked just before the logout may still be
    /// on its way into the queue (the same minute as Android).
    let settleGrace: TimeInterval
    /// Test seam: the clock retirement ages are measured on.
    private let now: () -> Date

    init(
        enabled: Bool,
        initialToken: String?,
        persistedRetired: String? = nil,
        persistRetired: ((String?) -> Void)? = nil,
        settleGrace: TimeInterval = SdkAuthTokenStore.settleGraceSeconds,
        now: @escaping () -> Date = Date.init
    ) {
        let seeded = initialToken.map { !$0.isEmpty } ?? false
        self.isEnabled = enabled || seeded
        self.token = initialToken
        self.persistRetired = persistRetired
        self.settleGrace = settleGrace
        self.now = now
        if let json = persistedRetired {
            let rows = Self.decodeRetired(json, now: now())
            self.retired = Array(rows.suffix(Self.maxRetiredTokens))
        }
        // Past the backend's 30-day window a token is of no use to anyone.
        let cutoff = now().addingTimeInterval(-Self.maxRetiredAge)
        if retired.contains(where: { $0.retiredAt < cutoff }) {
            retired.removeAll { $0.retiredAt < cutoff }
            persistRetiredLocked()
        }
    }

    private struct RetiredToken: Codable {
        let userId: String
        let token: String
        /// Seconds since 1970. Absent in rows written by an earlier build:
        /// those count from the launch that reads them.
        let retiredAt: Double?
        /// Set for the NEXT user before a reset() (see `Retired.standby`).
        let standby: Bool?
    }

    /// One row that does not decode must not lose the others.
    private struct LenientRow: Decodable {
        let row: RetiredToken?
        init(from decoder: Decoder) throws {
            row = try? RetiredToken(from: decoder)
        }
    }

    private static func decodeRetired(_ json: String, now: Date) -> [Retired] {
        guard let rows = try? JSONDecoder().decode([LenientRow].self, from: Data(json.utf8)) else { return [] }
        return rows.compactMap(\.row).compactMap { row in
            guard !row.userId.isEmpty, !row.token.isEmpty else { return nil }
            let at = row.retiredAt.map { Date(timeIntervalSince1970: $0) } ?? now
            return Retired(userId: row.userId, token: row.token, retiredAt: at, standby: row.standby ?? false)
        }
    }

    /// Caller holds the lock.
    private func persistRetiredLocked() {
        guard let persistRetired else { return }
        guard !retired.isEmpty else { persistRetired(nil); return }
        let rows = retired.map {
            RetiredToken(
                userId: $0.userId, token: $0.token, retiredAt: $0.retiredAt.timeIntervalSince1970,
                standby: $0.standby ? true : nil
            )
        }
        guard let data = try? JSONEncoder().encode(rows) else { return }
        persistRetired(String(data: data, encoding: .utf8))
    }

    /// The users whose token is retired, oldest first.
    var retiredUserIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return retired.map(\.userId)
    }

    /**
     Forget the retired tokens of users with nothing left on the device (D-a):
     a token lives exactly as long as the writes and events it is needed for,
     with a grace minute after it was retired (`settleGrace`), and never past
     `maxRetiredAge` - the backend accepts an expired token for withdrawals
     for 30 days, and never longer (SDK contract v6, 61; Android the same).

     `stillNeeded` is asked BEFORE the lock is taken (it reads the outbox and
     the event queue); the decision is applied under the lock to the entries
     exactly as they were when asked - a token retired again meanwhile (a
     new retirement) is kept.
     */
    func pruneRetired(stillNeeded: (String) -> Bool) {
        let snapshot: [Retired] = {
            lock.lock()
            defer { lock.unlock() }
            return retired
        }()
        guard !snapshot.isEmpty else { return }
        let at = now()
        let cutoff = at.addingTimeInterval(-Self.maxRetiredAge)
        let done = snapshot.filter { entry in
            if entry.retiredAt < cutoff { return true }
            // Waiting for its user to sign in: nothing is queued for them yet.
            if entry.standby { return false }
            return at.timeIntervalSince(entry.retiredAt) >= settleGrace && !stillNeeded(entry.userId)
        }
        guard !done.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let before = retired.count
        retired.removeAll { entry in done.contains { $0 == entry } }
        if retired.count != before { persistRetiredLocked() }
    }

    /// The `sub` claim of a JWT, read without verifying it - only to tell
    /// whose token the session holds. Nil when it is not a readable JWT.
    static func subject(ofJWT token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        if let sub = json["sub"] as? String { return sub }
        if let sub = json["sub"] as? NSNumber { return sub.stringValue }
        return nil
    }

    /// Current token, or nil if none set. Safe to call from any thread.
    func currentToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    /**
     Replace the token (called from the app thread when a fresh JWT is minted).

     A token for a DIFFERENT user (its `sub`) retires the one it replaces to
     THAT user's leftovers first (SDK contract v6, 61; Android the same): an
     app that switches accounts by setting B's token and then calling
     identify(B) - the natural order, B's identify needs B's token - used to
     send A's queued writes with B's token, refused `sub_mismatch` and
     dropped. A refresh for the same user just replaces.
     */
    func setToken(_ newToken: String) {
        lock.lock()
        defer { lock.unlock() }
        if let previous = token, previous != newToken,
           let previousSub = Self.subject(ofJWT: previous),
           previousSub != Self.subject(ofJWT: newToken) {
            retireLocked(userId: previousSub, token: previous)
        }
        token = newToken
        isEnabled = true
    }

    /// Forget the token - reset() (logout): it belonged to the user who left
    /// (contract v4, 39). Authentication stays on; anonymous writes need no
    /// token, and the next identify() comes with the next user's.
    func clearToken() {
        lock.lock()
        defer { lock.unlock() }
        token = nil
    }

    /// Logout (reset()): the session stops holding the token, but it stays
    /// bound to the outgoing user so THEIR queued events and writes still go
    /// out authenticated. Clearing it outright made every normal logout under
    /// SDK authentication drop that user's last events with a 401. Persisted
    /// in the Keychain (owner decision D-a) until that user's last queued
    /// item settles - see `pruneRetired`; the oldest is forgotten past
    /// `maxRetiredTokens`.
    ///
    /// Filed under the token's own `sub` when it can be read, so a token set
    /// for the NEXT user before this call is not filed under the outgoing
    /// one (Android the same).
    ///
    /// Such a token - its `sub` readable and not the outgoing user - is kept
    /// on standby for its own user: not pruned for having nothing queued
    /// (that user has not signed in yet), and the session's again at their
    /// identify() (`adoptRetired`). Pruned after the grace minute, an app
    /// that set B's token, called reset() and then identify(B) a minute
    /// later sent B's requests with no token (scan 7, N1).
    ///
    /// Also when nobody is identified (SDK contract v8, 82): a readable
    /// `sub` with no outgoing user is the next user's - "set B's token
    /// while anonymous, reset(), identify(B)" lost B's token after the
    /// grace minute (scan 8, N1). The caller passes the user whose
    /// withdrawals are queued (`withdrawalUserId()`, the held D-b user
    /// included), so a held user's own token is never mistaken for one.
    func retireToken(forUser userId: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let current = token {
            let sub = Self.subject(ofJWT: current)
            if let owner = sub ?? userId, !owner.isEmpty {
                let forNextUser = sub != nil && sub != userId
                retireLocked(userId: owner, token: current, standby: forNextUser)
            }
        }
        token = nil
    }

    /**
     The session moves from `outgoing` to `incoming` without a logout - an
     identify() of a different user, or one kept while tracking is off
     (D-b): the token goes with its owner's leftovers, unless it is already
     the incoming user's (the app set it first), which stays current.
     */
    func retireTokenOnSwitch(outgoing: String?, incoming: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = token else { return }
        let sub = Self.subject(ofJWT: current)
        if sub == incoming { return }
        guard let owner = sub ?? outgoing, !owner.isEmpty, owner != incoming else { return }
        retireLocked(userId: owner, token: current)
        token = nil
    }

    /// Caller holds the lock.
    private func retireLocked(userId: String, token: String, standby: Bool = false) {
        retired.removeAll { $0.userId == userId }
        retired.append(Retired(userId: userId, token: token, retiredAt: now(), standby: standby))
        if retired.count > Self.maxRetiredTokens {
            retired.removeFirst(retired.count - Self.maxRetiredTokens)
        }
        persistRetiredLocked()
    }

    /**
     The token a request about `subjectUserId` carries - routed by the
     token's own `sub` (SDK contract v7, 72; Android and web the same):

     - the session token when its `sub` is the request's user;
     - else the kept (retired) token whose `sub` is that user - a previous
       user's leftovers, a held (D-b) user's withdrawals, or the next user
       whose token was set before a reset();
     - else nothing: a token whose `sub` names someone else is never
       attached (the server would refuse it `sub_mismatch`, and the app's
       handler would be asked about a user who is not the one it signed
       in). The request goes without, and a 401 reaches the handler only
       for the current user.

     A session token whose `sub` cannot be read (not a JWT the SDK can
     decode) is used for the current user only. An anonymous request
     (`subjectUserId` nil) carries no token: the server checks none for an
     anonymous subject, and none names this visitor.

     It used to return the session token whenever the subject was the
     current user: between setSdkAuthenticationToken(B) and identify(B),
     the outgoing user's events went out with B's token, were refused
     `sub_mismatch`, and the app's handler was asked twice - the second time
     with `refreshExhausted`, the signal apps sign out on (scan 7, S2).
     */
    func token(forSubject subjectUserId: String?, currentUserId: () -> String?) -> String? {
        let (session, sessionSub, kept): (String?, String?, String?) = {
            lock.lock()
            defer { lock.unlock() }
            let kept = subjectUserId.flatMap { subject in retired.last(where: { $0.userId == subject })?.token }
            return (token, token.flatMap(Self.subject(ofJWT:)), kept)
        }()
        // Anonymous (contract v7 72, same on web and Android): the server
        // checks no token for an anonymous subject, and none names this visitor.
        guard let subject = subjectUserId, !subject.isEmpty else { return nil }
        if let session, sessionSub == subject { return session }
        if let kept { return kept }
        if let session, sessionSub == nil, subject == currentUserId() { return session }
        return nil
    }

    /// `token(forSubject:currentUserId:)` with the current user already known.
    func token(forSubject subjectUserId: String?, currentUserId: String?) -> String? {
        token(forSubject: subjectUserId, currentUserId: { currentUserId })
    }

    /**
     `userId` is the session's user again (an identify()): when the session
     holds no token and one is kept for that user - set for them before a
     reset(), or theirs from an earlier logout - it becomes the session's
     token again, so a refresh replaces it and pruning does not forget it
     while they are signed in (scan 7, N1).
     */
    func adoptRetired(forUser userId: String) {
        lock.lock()
        defer { lock.unlock() }
        guard token == nil, let index = retired.lastIndex(where: { $0.userId == userId }) else { return }
        token = retired.remove(at: index).token
        // Adopting a token is supplying one, as setToken does (SDK contract
        // v8, 81; Android the same). An app that turns authentication on
        // only by setting a token starts the next process with the flag off
        // and "enabled" only through the kept token: adopting the only one
        // emptied `retired`, switched authentication OFF, and that user's
        // requests went out with no token and their 401 never reached the
        // app's handler (scan 8, S1).
        isEnabled = true
        persistRetiredLocked()
    }

    /**
     wipeData(): forget every standby token (SDK contract v8, 82; Android
     and web the same). A standby token belongs to someone who has not
     signed in on this device and has nothing queued here - it serves no
     withdrawal of the person being erased, and it kept SDK authentication
     on and another person's JWT in the Keychain for up to 30 days (scan 8,
     N2). Tokens bound to queued withdrawals are kept (D-a).
     */
    ///
    /// A standby entry is kept when its user is the one being erased (a
    /// held D-b user whose only token came through standby: their queued
    /// unsubscribe went out with no token and was lost - scan 9, B1), when
    /// something is still queued for its user (`stillNeeded`), or when it
    /// holds `keepingToken` - the token supplied for this launch, which a
    /// pre-init wipe run inside initialize() filed as standby and then
    /// deleted, so the user signed in next had none (scan 9, S1; contract
    /// v9, 89). Android and web the same.
    func dropStandby(keepingUser: String? = nil, keepingToken: String? = nil, stillNeeded: (String) -> Bool = { _ in false }) {
        let snapshot: [Retired] = {
            lock.lock()
            defer { lock.unlock() }
            return retired
        }()
        let drop = snapshot.filter { entry in
            guard entry.standby else { return false }
            if let keepingUser, entry.userId == keepingUser { return false }
            if let keepingToken, entry.token == keepingToken { return false }
            return !stillNeeded(entry.userId)
        }
        guard !drop.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let before = retired.count
        retired.removeAll { entry in drop.contains { $0 == entry } }
        if retired.count != before { persistRetiredLocked() }
    }

    /// `userId` is held (D-b) - identify() while tracking is off, or restored
    /// so at launch: a token kept on standby for them is theirs now, bound
    /// to their withdrawals and pruned like any other once those settle -
    /// never dropped as someone else's at wipeData() (contract v9, 89).
    func clearStandby(forUser userId: String) {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for index in retired.indices where retired[index].userId == userId && retired[index].standby {
            retired[index].standby = false
            changed = true
        }
        if changed { persistRetiredLocked() }
    }

    /// True when there is any token to attach - the session's or a kept
    /// one. False: no request can carry a token, and the request body need
    /// not be read to route one (`NetworkClient.authToken`).
    var hasAnyToken: Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != nil || !retired.isEmpty
    }

    /// True when some logged-out user's token is still kept.
    var hasRetiredTokens: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !retired.isEmpty
    }

    static let maxRetiredTokens = 4
    /// The backend accepts an expired token for withdrawals for 30 days past
    /// its expiry, and never longer.
    static let maxRetiredAge: TimeInterval = 30 * 24 * 60 * 60
    static let settleGraceSeconds: TimeInterval = 60

    private struct Retired: Equatable {
        let userId: String
        let token: String
        let retiredAt: Date
        /// Set for the next user before a reset(), kept for them until they
        /// sign in (or the 30-day cap) rather than until their items settle.
        var standby = false
    }
    private var retired: [Retired] = []

    /// Register/replace the auth-error handler.
    func setHandler(_ newHandler: @escaping (SdkAuthError) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        handler = newHandler
    }

    /// Remove the auth-error handler.
    func clearHandler() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
    }

    /// Snapshot of the current handler, or nil if none registered.
    func currentHandler() -> ((SdkAuthError) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }
}
