import Foundation

/**
 Content cards (docs/PLACEMENTS_PLAN.md section 11, BACKLOG D444 Phase 3): a
 persistent feed per person - a message center inside the app. Cards come from
 card campaigns and the journey step "Add card".

 Draw the feed with `CardFeedViewController` (UIKit) or `JoryioCardFeed`
 (SwiftUI) from JoryioUI, or read it with `Joryio.shared.getCards()` and draw
 it yourself, reporting with `markCardViewed` / `markCardRead` /
 `markCardClicked` / `dismissCard`.

 The names and values are the same on every Joryio SDK, pinned by the
 backend's SDK parity spec.
 */
public enum Cards {
    /// The feed goes to the network at most once per this many seconds; extra calls coalesce.
    public static let CARD_MIN_REFRESH_SECONDS: Int = 30
    /// How long the feed is served from the device cache before it is asked for again (the answer's `ttlSeconds` wins).
    public static let CARD_FEED_TTL_SECONDS: Int = 300
    /// The capability a card-aware SDK declares.
    public static let capability = "cards"
    /// The silent push `jry_sync` value that refreshes the feed.
    public static let syncType = "cards"

    /// What the SDK reports about a card: the `action` of `POST /v1/in-app/track`. Wire values.
    public enum Action {
        public static let viewed = "viewed"
        public static let read = "read"
        public static let clicked = "clicked"
        public static let dismissed = "dismissed"
    }

    /// `stateScope` wire values.
    public enum StateScope {
        /// Read / clicked / dismissed are kept per person on the server, the same on every device.
        public static let server = "server"
        /// An anonymous visitor: this device keeps what was read and dismissed.
        public static let device = "device"
    }
}

/// One card of the person's feed.
public struct Card: Equatable {
    /// Stable id of this card for this person.
    public let id: String
    /// Campaign id, or `journey:<canvasId>:<nodeId>` for a journey card.
    public let campaignId: String
    public let variantId: String?
    public let title: String?
    public let body: String?
    public let imageUrl: String?
    /// Button label; nil = no button (the whole card opens `url` when set).
    public let buttonText: String?
    /// An http(s) URL or the app's own deep link; nil = nothing to open.
    public let url: String?
    public let pinned: Bool
    /// ISO 8601.
    public let createdAt: String
    /// ISO 8601, or nil.
    public let expiresAt: String?
    public let read: Bool
    public let clicked: Bool
    /// Signed token every report of this card carries. Internal: never shown, never logged.
    let deliveryToken: String

    init?(_ o: [String: Any]) {
        guard let id = o["id"] as? String, let token = o["deliveryToken"] as? String else { return nil }
        self.id = id
        campaignId = (o["campaignId"] as? String) ?? ""
        variantId = o["variantId"] as? String
        title = o["title"] as? String
        body = o["body"] as? String
        imageUrl = o["imageUrl"] as? String
        buttonText = o["buttonText"] as? String
        url = o["url"] as? String
        pinned = (o["pinned"] as? Bool) ?? false
        createdAt = (o["createdAt"] as? String) ?? ""
        expiresAt = o["expiresAt"] as? String
        read = (o["read"] as? Bool) ?? false
        clicked = (o["clicked"] as? Bool) ?? false
        deliveryToken = token
    }

    private init(copy c: Card, read: Bool, clicked: Bool) {
        id = c.id
        campaignId = c.campaignId
        variantId = c.variantId
        title = c.title
        body = c.body
        imageUrl = c.imageUrl
        buttonText = c.buttonText
        url = c.url
        pinned = c.pinned
        createdAt = c.createdAt
        expiresAt = c.expiresAt
        self.read = read
        self.clicked = clicked
        deliveryToken = c.deliveryToken
    }

    func with(read: Bool, clicked: Bool) -> Card { Card(copy: self, read: read, clicked: clicked) }

    /// The card as a JSON-ready dictionary for Joryio's React Native and Unity bridges (no delivery token).
    public func toJson() -> [String: Any] {
        [
            "id": id,
            "campaignId": campaignId,
            "variantId": variantId ?? NSNull(),
            "title": title ?? NSNull(),
            "body": body ?? NSNull(),
            "imageUrl": imageUrl ?? NSNull(),
            "buttonText": buttonText ?? NSNull(),
            "url": url ?? NSNull(),
            "pinned": pinned,
            "createdAt": createdAt,
            "expiresAt": expiresAt ?? NSNull(),
            "read": read,
            "clicked": clicked,
        ]
    }

    /// The wire form, token included (the disk cache only).
    func wireJson() -> [String: Any] {
        var o = toJson()
        o["deliveryToken"] = deliveryToken
        return o
    }
}

/// The person's feed (or one page of it).
public struct CardFeed: Equatable {
    /// Pinned first, then newest first.
    public let cards: [Card]
    /// Unread cards across the whole feed, not this page: the badge.
    public let unreadCount: Int
    /// Pass to `getCards(cursor:)` for the next page; nil on the last one.
    public let nextCursor: String?
    /// `Cards.StateScope.server` or `Cards.StateScope.device`.
    public let stateScope: String

    public static let empty = CardFeed(cards: [], unreadCount: 0, nextCursor: nil, stateScope: Cards.StateScope.server)

    /// The feed as a JSON-ready dictionary for Joryio's React Native and Unity
    /// bridges: `{ cards, unreadCount, nextCursor, stateScope }` - no delivery
    /// tokens (reports go back by card id).
    public func toJson() -> [String: Any] {
        [
            "cards": cards.map { $0.toJson() },
            "unreadCount": unreadCount,
            "nextCursor": nextCursor ?? NSNull(),
            "stateScope": stateScope,
        ]
    }
}

