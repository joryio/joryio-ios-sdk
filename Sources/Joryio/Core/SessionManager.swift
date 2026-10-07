import Foundation

/// Manages user session lifecycle.
///
/// Thread-safe: `track()` renews the session from whichever thread the host
/// calls it on, while the lifecycle observers and in-app tasks read it, so
/// `currentSession` is only touched under `lock`.
class SessionManager {
    private let storage: StorageManager
    private let logger: Logger
    private let sessionTimeout: TimeInterval
    private let lock = NSLock()
    private var currentSession: SessionInfo
    /// True when this launch CONTINUED an unexpired session from the previous
    /// one. Such a launch sends no Session Start: the session it belongs to
    /// was announced when it began (SDK contract 32).
    let resumedAtLaunch: Bool

    init(storage: StorageManager, logger: Logger, sessionTimeout: TimeInterval) {
        self.storage = storage
        self.logger = logger
        self.sessionTimeout = sessionTimeout

        // Load existing session or create new one
        if let session = storage.getSession(), !session.isExpired(timeout: sessionTimeout) {
            self.currentSession = session
            self.resumedAtLaunch = true
            logger.info("Resumed existing session: \(session.sessionId)")
        } else {
            self.currentSession = SessionInfo()
            self.resumedAtLaunch = false
            storage.setSession(currentSession)
            logger.info("Started new session: \(currentSession.sessionId)")
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Session Access

    func getSession() -> SessionInfo {
        withLock { currentSession }
    }

    func getSessionId() -> String {
        withLock { currentSession.sessionId }
    }

    // MARK: - Session Lifecycle

    func updateActivity() {
        let session: SessionInfo = withLock {
            currentSession.updateActivity()
            return currentSession
        }
        storage.setSession(session)
    }

    /// Renew the session if it timed out, otherwise record activity.
    ///
    /// - Returns: true when a NEW session started. The caller emits
    ///   "Session Start" on that answer. The foreground handler used to call
    ///   this and THEN ask how long it had been since the last activity - but
    ///   renewing resets that clock, so the answer was always ~0 and no
    ///   Session Start was ever sent after a timeout.
    @discardableResult
    func checkAndRenewSession() -> Bool {
        let (session, renewed): (SessionInfo, Bool) = withLock {
            if currentSession.isExpired(timeout: sessionTimeout) {
                currentSession = SessionInfo()
                return (currentSession, true)
            }
            currentSession.updateActivity()
            return (currentSession, false)
        }
        storage.setSession(session)
        if renewed {
            logger.info("Session expired, started new session: \(session.sessionId)")
        }
        return renewed
    }

    func startNewSession() {
        let session: SessionInfo = withLock {
            currentSession = SessionInfo()
            return currentSession
        }
        storage.setSession(session)
        logger.debug("New session started: \(session.sessionId)")
    }

    func resetSession() {
        storage.clearSession()
        startNewSession()
    }

    // MARK: - Session Info

    func getSessionDuration() -> TimeInterval {
        withLock { Date().timeIntervalSince(currentSession.sessionStart) }
    }

    func getTimeSinceLastActivity() -> TimeInterval {
        withLock { Date().timeIntervalSince(currentSession.lastActivity) }
    }

    func isSessionActive() -> Bool {
        withLock { !currentSession.isExpired(timeout: sessionTimeout) }
    }
}
