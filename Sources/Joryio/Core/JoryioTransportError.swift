import Foundation

/// A request the SDK could not complete.
///
/// Exposed so a host app can show what the SDK actually experienced rather than
/// only that it initialised. Those are different claims: initialisation says
/// the SDK was configured, not that the server accepts it. On 2026-08-12 a demo
/// app displayed a green "initialized" badge while every request was rejected
/// 401 for an ignored SDK key, and nothing in the app could have known.
public struct JoryioTransportError {

    /// Human-readable description, safe to display.
    public let message: String

    /// The server rejected our credentials (401). Distinguished from other
    /// failures because it is the one an integrator can FIX - a wrong SDK key,
    /// or a key for a different workspace - rather than wait out.
    public let isUnauthorized: Bool

    /// When it happened, so a stale error is not shown as current.
    public let at: Date

    /// Transient (offline, DNS, 5xx, 429): the next call may succeed. Mirrors
    /// `PushRegistrationResult.isRetryable`, so a host app that reads
    /// diagnostics gets the same distinction the callback gives.
    public let isRetryable: Bool

    public init(message: String, isUnauthorized: Bool, at: Date = Date(), isRetryable: Bool = false) {
        self.message = message
        self.isUnauthorized = isUnauthorized
        self.at = at
        self.isRetryable = isRetryable
    }
}
