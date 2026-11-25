import Foundation

/**
 Placements (docs/PLACEMENTS_PLAN.md, BACKLOG D444): named spots inside the
 app - `home_hero`, `cart_upsell` - that Joryio fills per person from placement
 campaigns and journey steps.

 Draw one with `PlacementView(placementKey:)` (UIKit) or `JoryioPlacement(_:)`
 (SwiftUI) from JoryioUI, or ask for the data with
 `Joryio.shared.getPlacements(_:)` and draw it yourself, reporting with
 `markDisplayed()` / `markClicked()` / `markDismissed()`.

 The names and values are the same on every Joryio SDK, pinned by the
 backend's sdk-placements-parity.spec.ts.
 */
public enum Placements {
    /// Share of an item that must be on screen for it to count as seen.
    public static let PLACEMENT_VIEWABLE_FRACTION: Double = 0.5
    /// A placement key is fetched from the network at most once per this many seconds.
    public static let PLACEMENT_MIN_REFRESH_SECONDS: Int = 30
    /// A request that got no answer (no connection, a 5xx) holds its keys back this
    /// many seconds instead of `PLACEMENT_MIN_REFRESH_SECONDS`: one failed request
    /// must not leave a placement empty for 30 s. A 429 keeps the full window.
    public static let PLACEMENT_RETRY_AFTER_FAILURE_SECONDS: Int = 3
    /// Keys asked for within this window go in one request.
    public static let PLACEMENT_BATCH_WINDOW_MS: Int = 50
    /// The serve endpoint takes 1-10 keys per request.
    public static let PLACEMENT_MAX_KEYS_PER_REQUEST: Int = 10
    /// How long an event-triggered item stays eligible after its event, when the server does not say.
    public static let PLACEMENT_DEFAULT_TRIGGER_WINDOW_SECONDS: Int = 1800
    /// A drawn product card's tap is reported as `clicked` with the elementId
    /// `product:<product id>` (at most 128 characters) - the same on every Joryio SDK.
    public static let PLACEMENT_PRODUCT_ELEMENT_PREFIX = "product:"
    /// Width of a drawn product card when the app does not set one (points; CSS px on web, dp on Android).
    public static let PLACEMENT_PRODUCT_CARD_WIDTH: Double = 160
    /// The elementId a product card's click is reported with - use it when you draw the cards yourself.
    public static func placementProductElementId(_ productId: String) -> String {
        String((PLACEMENT_PRODUCT_ELEMENT_PREFIX + productId).prefix(128))
    }
    /// `emptyBehavior` wire values.
    public static let collapse = "collapse"
    public static let keepSpace = "keep_space"
    /// "Show when" (BACKLOG D465): the moment a placement campaign's content is
    /// revealed on a screen - the `kind` values the wire may carry. An app
    /// honours `load`, `seconds` (foreground seconds on the screen) and `event`
    /// (tracked in this visit); `scroll` and `exit` are web-only and, like an
    /// unknown kind, are never shown.
    public static let SHOW_WHEN_KINDS: [String] = ["load", "seconds", "scroll", "exit", "event"]
}

/**
 A served "Show when" (BACKLOG D465) as an app honours it. Wire contract:
 packages/backend/src/common/show-when.ts - `{ kind: 'load' }` (also: no
 field), `{ kind: 'seconds', seconds: 1..3600 }`, `{ kind: 'event', event }`;
 `scroll` / `exit` (web only), an unknown kind or an invalid value become
 `never`: such content is not shown at all (never treated as `load`).
 */
enum ShowWhenMoment: Equatable {
    case load
    /// Foreground seconds on the current screen (the time_on_screen clock).
    case seconds(Double)
    /// The event was tracked in this visit (the SDK session).
    case event(String)
    case never

    static func parse(_ raw: Any?) -> ShowWhenMoment {
        if raw == nil || raw is NSNull { return .load }
        guard let o = raw as? [String: Any] else { return .never }
        switch o["kind"] as? String {
        case "load":
            return .load
        case "seconds":
            guard let n = o["seconds"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return .never }
            let d = n.doubleValue
            return d == d.rounded() && d >= 1 && d <= 3600 ? .seconds(d) : .never
        case "event":
            let e = ((o["event"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !e.isEmpty && e.utf16.count <= 255 ? .event(e) : .never
        default:
            // scroll / exit need a page; anything else is unknown.
            return .never
        }
    }
}

/// A button of a native item.
public struct PlacementButton {
    public let id: String
    public let text: String
    /// `url`, `deep_link`, `dismiss`, `request_push_permission`... (the in-app button actions).
    public let action: String
    public let url: String?
}

/// What the SDK can draw: a native card, or HTML (delivered only with allowHtmlJsInAppMessages).
public struct PlacementContent {
    /// `native` or `html`.
    public let kind: String
    public let title: String?
    public let body: String?
    public let imageUrl: String?
    public let buttons: [PlacementButton]
    public let closeButton: Bool
    public let html: String?
    public let css: String?
}

/// What the reporting calls reach (the manager).
protocol PlacementReporter: AnyObject {
    func report(_ generation: Int, _ key: String, _ item: PlacementItemWire, _ type: String, _ elementId: String?)
    func dismiss(_ generation: Int, _ key: String, _ item: PlacementItemWire)
    func reportControl(_ generation: Int, _ key: String)
}

/// A product card of a recommendation placement item (D444 Phase 2b). Same names on all five SDKs.
public struct PlacementProduct {
    public let id: String
    public let title: String?
    public let price: String?
    public let compareAtPrice: String?
    public let discountPercent: Double?
    public let imageUrl: String?
    public let url: String?

    init?(_ o: [String: Any]) {
        if let s = o["id"] as? String { id = s } else if let n = o["id"] as? NSNumber { id = n.stringValue } else { return nil }
        title = o["title"] as? String
        price = o["price"] as? String
        compareAtPrice = o["compareAtPrice"] as? String
        discountPercent = (o["discountPercent"] as? NSNumber)?.doubleValue
        imageUrl = o["imageUrl"] as? String
        url = o["url"] as? String
    }
}

/// One item to show, and the calls that report what the person did with it.
public final class PlacementItem {
    public let id: String
    public let variantId: String?
    /// `native`, `html` or `data`.
    public let kind: String
    /// The placement's fields, as authored and rendered for this person.
    public let data: [String: Any]
    public let content: PlacementContent?
    /// Products picked for the person by a recommendation model; empty when the item has none. Draw them as cards.
    public let products: [PlacementProduct]
    public let priority: Int?
    public let expiresAt: String?

    let placementKey: String
    let wire: PlacementItemWire
    weak var reporter: PlacementReporter?
    /// The person it was served for: after an identify / reset it reports nothing.
    let generation: Int

    init(placementKey: String, wire: PlacementItemWire, reporter: PlacementReporter?, generation: Int = 0) {
        self.generation = generation
        self.id = wire.id
        self.variantId = wire.variantId
        self.kind = wire.kind
        self.data = wire.data
        self.content = wire.content
        self.products = wire.products
        self.priority = wire.priority
        self.expiresAt = wire.expiresAt
        self.placementKey = placementKey
        self.wire = wire
        self.reporter = reporter
    }

    /// Report a viewable impression (your own UI drew it). Once per delivery.
    public func markDisplayed() {
        reporter?.report(generation, placementKey, wire, "displayed", nil)
    }

    /// Report a tap; `elementId` names the button or link.
    public func markClicked(elementId: String? = nil) {
        reporter?.report(generation, placementKey, wire, "clicked", elementId)
    }

    /// Report that the person closed it. The placement's dismissal rule applies on the server.
    public func markDismissed() {
        reporter?.dismiss(generation, placementKey, wire)
    }
}

/// A placement as the server answered it for this person.
public final class Placement {
    public let placementKey: String
    public let items: [PlacementItem]
    /// Held out (the placement's control group): nothing to show.
    public let isControl: Bool
    /// `collapse` or `keep_space`.
    public let emptyBehavior: String
    public let maxItems: Int
    public let ttlSeconds: Int
    weak var reporter: PlacementReporter?
    let generation: Int

    init(placementKey: String, items: [PlacementItem], isControl: Bool, emptyBehavior: String, maxItems: Int, ttlSeconds: Int, reporter: PlacementReporter?, generation: Int = 0) {
        self.generation = generation
        self.placementKey = placementKey
        self.items = items
        self.isControl = isControl
        self.emptyBehavior = emptyBehavior
        self.maxItems = maxItems
        self.ttlSeconds = ttlSeconds
        self.reporter = reporter
    }

    /**
     For a held-out person (`isControl`): report that the empty spot was
     viewable (`in_app.control_viewed`). PlacementView does it itself; an app
     drawing from getPlacements calls it when its spot was on screen.
     */
    public func markDisplayed() {
        reporter?.reportControl(generation, placementKey)
    }

    /// The placement as a JSON-ready dictionary, for Joryio's React Native and
    /// Unity bridges: `{ placementKey, isControl, emptyBehavior, maxItems,
    /// ttlSeconds, items: [{ id, variantId, kind, data, content }] }` - no
    /// delivery token (reports go back through this object's mark calls).
    public func toJson() -> [String: Any] {
        let items: [[String: Any]] = self.items.map { item in
            var o: [String: Any] = ["id": item.id, "kind": item.kind, "data": item.data]
            if let v = item.variantId { o["variantId"] = v }
            if let c = item.content {
                var content: [String: Any] = [
                    "kind": c.kind,
                    "closeButton": c.closeButton,
                    "buttons": c.buttons.map { b -> [String: Any] in
                        var bo: [String: Any] = ["id": b.id, "text": b.text, "action": b.action]
                        if let u = b.url { bo["url"] = u }
                        return bo
                    },
                ]
                if let t = c.title { content["title"] = t }
                if let t = c.body { content["body"] = t }
                if let t = c.imageUrl { content["imageUrl"] = t }
                if let t = c.html { content["html"] = t }
                if let t = c.css { content["css"] = t }
                o["content"] = content
            }
            // The bridges (React Native, Unity) read the item from here: products must cross too.
            if !item.products.isEmpty {
                o["products"] = item.products.map { p -> [String: Any] in
                    var po: [String: Any] = ["id": p.id]
                    if let v = p.title { po["title"] = v }
                    if let v = p.price { po["price"] = v }
                    if let v = p.compareAtPrice { po["compareAtPrice"] = v }
                    if let v = p.discountPercent { po["discountPercent"] = v }
                    if let v = p.imageUrl { po["imageUrl"] = v }
                    if let v = p.url { po["url"] = v }
                    return po
                }
            }
            return o
        }
        return [
            "placementKey": placementKey,
            "isControl": isControl,
            "emptyBehavior": emptyBehavior,
            "maxItems": maxItems,
            "ttlSeconds": ttlSeconds,
            "items": items,
        ]
    }
}

/// A view that draws a placement (PlacementView, the React Native view). For Joryio's own views.
public protocol PlacementHost: AnyObject {
    var placementKey: String { get }
    /// Item ids currently drawn (the `shown` list of the next request).
    func shownIds() -> [String]
    /// A newer answer for `placementKey`. Called on the main thread.
    func onPlacementUpdated(_ placement: Placement)
    /// The person changed (identify, reset, consent): remove what is drawn NOW, on screen or not.
    func clearPlacement()
}

