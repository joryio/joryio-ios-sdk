import Foundation

/**
 Click-link identity: the token a tracked message link carries.

 When someone clicks a tracked link in a Joryio message, the click redirect
 appends an opaque, signed token as `jr_t`. An app opened by that link (a
 universal link / deep link) hands the URL to `Joryio.shared.identifyFromLink(_:)`,
 which sends the token with this SDK's anonymous id to `/v1/identify-link`.
 The server uses it only to attribute this visitor's events to the contact
 the message was sent to - attribution only: it never identifies the person
 or merges this visitor into the contact (only identify() does that).

 The wire values are byte-identical on all five SDKs (pinned by the backend
 spec sdk-click-identity-parity.spec.ts): the query parameter `jr_t`, the
 path `/v1/identify-link`, a body of exactly `token` and `anonymousId`.

 The token is a credential for one person's identity: it is never logged
 above debug, never persisted, and held in memory only.
 */
enum ClickIdentity {
    /// The query parameter the click redirect appends.
    static let clickIdentityParam = "jr_t"

    /// Appended to the API endpoint, like every other SDK route.
    static let identifyLinkPath = "/v1/identify-link"

    /// Most tokens held while consent is pending (memory only).
    static let maxHeldTokens = 20

    private static let tokenAlphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")

    /// The `jr_t` value of `url`'s query, or nil when there is none or it is
    /// malformed (`^[A-Za-z0-9_-]{16,512}$`).
    static func token(from url: URL?) -> String? {
        guard let url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let value = items.first(where: { $0.name == clickIdentityParam })?.value
        else { return nil }
        return isWellFormed(value) ? value : nil
    }

    static func isWellFormed(_ token: String) -> Bool {
        let scalars = token.unicodeScalars
        guard scalars.count >= 16, scalars.count <= 512 else { return false }
        return scalars.allSatisfy { tokenAlphabet.contains($0) }
    }
}

/// Body of `POST /v1/identify-link`: exactly these two keys, on every SDK.
struct IdentifyLinkRequest: Encodable {
    let token: String
    let anonymousId: String
}
