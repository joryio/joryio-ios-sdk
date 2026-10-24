import Foundation

/// User identity information
public struct UserIdentity: Codable {
    public var userId: String?
    /// `var`, not `let`: `wipeData()` replaces it in place after clearing
    /// storage (IdentityManager.onDataWiped), which is the one time it changes.
    public var anonymousId: String
    public var attributes: [String: AnyCodable]

    public init(userId: String?, anonymousId: String, attributes: UserAttributes = [:]) {
        self.userId = userId
        self.anonymousId = anonymousId
        self.attributes = attributes.mapValues { AnyCodable($0) }
    }

    enum CodingKeys: String, CodingKey {
        case userId
        case anonymousId
        case attributes
    }
}

/// User identification request
public struct IdentifyRequest: Codable {
    public let userId: String
    /// The device's anonymous id, so the server stitches the pre-login history
    /// onto the person on identify - as Android's request always did. Without
    /// it the pre-login history stayed on a separate anonymous profile.
    public let anonymousId: String?
    public let attributes: [String: AnyCodable]

    public init(userId: String, anonymousId: String? = nil, attributes: UserAttributes) {
        self.userId = userId
        self.anonymousId = anonymousId
        self.attributes = attributes.mapValues { AnyCodable($0) }
    }
}

/// Labelled alias request (`POST /v1/alias/add`).
///
/// `anonymousId` is always sent and `userId` only when the person is
/// identified, so an anonymous visitor can carry an alias too (a loyalty card
/// scanned before sign-in). Byte-identical on every SDK.
public struct AddAliasRequest: Codable {
    public let anonymousId: String
    public let userId: String?
    public let aliasLabel: String
    public let aliasName: String

    public init(anonymousId: String, userId: String?, aliasLabel: String, aliasName: String) {
        self.anonymousId = anonymousId
        self.userId = userId
        self.aliasLabel = aliasLabel
        self.aliasName = aliasName
    }
}

/// Attribute-operations request (uses /v1/attributes to avoid $identify events).
///
/// Each section maps to an atomic backend operation; only the non-nil ones are
/// encoded (Swift omits nil optionals), so an increment sends a DELTA rather
/// than a locally-computed absolute and multi-device writes don't clobber:
///   - attributes: absolute `$set`
///   - increment:  `$inc`   (delta)
///   - append:     `$addToSet`
///   - remove:     `$pull`
///   - unset:      `$unset`
/*
 * Marketing subscription requests.
 *
 * Wire values byte-identical to the web and Android SDKs and the backend DTO:
 * status is camelCase `optedIn` (the API 400s on `opted_in`), action is
 * `subscribe` / `unsubscribe`. One state must not become two segment rules.
 */
public struct ChannelSubscriptionRequest: Codable {
    public let channel: String
    public let status: String
    public let userId: String?
    public let anonymousId: String?

    public init(channel: String, status: String, userId: String?, anonymousId: String?) {
        self.channel = channel
        self.status = status
        self.userId = userId
        self.anonymousId = anonymousId
    }
}

public struct SubscriptionGroupRequest: Codable {
    public let groupId: String
    public let channel: String
    public let action: String
    public let userId: String?
    public let anonymousId: String?

    public init(groupId: String, channel: String, action: String, userId: String?, anonymousId: String?) {
        self.groupId = groupId
        self.channel = channel
        self.action = action
        self.userId = userId
        self.anonymousId = anonymousId
    }
}

public struct SetAttributesRequest: Codable {
    public let userId: String?
    public let anonymousId: String
    public let attributes: [String: AnyCodable]?
    public let increment: [String: Double]?
    public let append: [String: AnyCodable]?
    public let remove: [String: AnyCodable]?
    public let unset: [String]?

    public init(
        userId: String?,
        anonymousId: String,
        attributes: UserAttributes? = nil,
        increment: [String: Double]? = nil,
        append: [String: Any]? = nil,
        remove: [String: Any]? = nil,
        unset: [String]? = nil
    ) {
        self.userId = userId
        self.anonymousId = anonymousId
        self.attributes = attributes.map { $0.mapValues { AnyCodable($0) } }
        self.increment = increment
        self.append = append.map { $0.mapValues { AnyCodable($0) } }
        self.remove = remove.map { $0.mapValues { AnyCodable($0) } }
        self.unset = unset
    }
}

/// Push token registration request
public struct PushTokenRequest: Codable {
    public let userId: String?
    public let anonymousId: String
    public let token: String
    public let platform: String

    /// Stable device identity, so the server attaches this token to the device
    /// row that already exists rather than inserting a second one keyed only by
    /// the token. Without it, first launch produced TWO rows seconds apart -
    /// one with the identity and no token, one with the token and no identity,
    /// nothing joining them. Reported from a production integration on Android,
    /// 2026-08-23; iOS matches so the split cannot appear here either.
    public let deviceId: String?

    public let deviceInfo: [String: AnyCodable]?

    public init(
        userId: String?,
        anonymousId: String,
        token: String,
        platform: String,
        deviceId: String? = nil,
        deviceInfo: [String: Any]
    ) {
        self.userId = userId
        self.anonymousId = anonymousId
        self.token = token
        self.platform = platform
        self.deviceId = deviceId
        self.deviceInfo = deviceInfo.isEmpty ? nil : deviceInfo.mapValues { AnyCodable($0) }
    }
}

/// Push token unregistration request (`POST /v1/push/unregister`).
public struct UnregisterPushTokenRequest: Codable {
    public let userId: String?
    public let anonymousId: String
    public let token: String
    public let platform: String

    public init(userId: String?, anonymousId: String, token: String, platform: String) {
        self.userId = userId
        self.anonymousId = anonymousId
        self.token = token
        self.platform = platform
    }
}
