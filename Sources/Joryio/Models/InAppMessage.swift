import Foundation

/**
 In-app campaign, as `/v1/in-app/sync` actually returns it.

 WHY THIS FILE WAS REWRITTEN
 ---------------------------
 The previous version modelled a STRUCTURED native message - `title`, `body`,
 `imageUrl`, `buttons` - nested under a `message` object. The server has never
 sent that. It sends `template { html, css, assets }` (plus `renderedHtml` when
 Liquid personalisation is on), because the campaign editor is HTML-based and
 produces HTML. There was no `message` key in the payload at all, so decoding
 could not succeed: in-app messaging was not degraded on iOS, it was inert.

 WHY HTML AND NOT NATIVE VIEWS
 -----------------------------
 Mature in-app SDKs commonly offer both - native slideup/modal/full types
 alongside an HTML type - and that split is the right end
 state. But nothing in this product AUTHORS structured content today, so a
 native renderer would be dead code shipped to every customer. `InAppContent`
 is therefore an enum rather than a bare string: adding a `.native` case later
 is additive instead of a rewrite of every call site.
 */
/// A display condition the DEVICE evaluates - never an eligibility rule, which
/// the server already decided by sending the campaign at all.
public struct InAppTrigger: Codable {
    /// immediate | event | attribute_change | attribute_threshold | push_notification_tap
    public let type: String
    /// Event name, for `event` triggers.
    public let event: String?
    /// Optional property condition on that event ("add_to_cart where value > 100").
    public let attribute: String?
    /// Backticked: `operator` is a Swift keyword.
    public let `operator`: String?
    public let value: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case type, event, attribute, value
        case `operator`
    }

    /// The type a trigger gets when the server sent one this SDK cannot
    /// read. It matches nothing - in particular it is not `immediate`.
    static let unreadableType = "unreadable"

    init(type: String, event: String? = nil, attribute: String? = nil, operator op: String? = nil, value: AnyCodable? = nil) {
        self.type = type
        self.event = event
        self.attribute = attribute
        self.operator = op
        self.value = value
    }

    /**
     Tolerant per trigger, and FAIL CLOSED (scan 5, N1): one trigger without a
     readable `type` used to fail the whole list, which then read as "no
     triggers" - and a campaign with no triggers displays on sync. It now
     stays in the list as an unreadable trigger that matches nothing.
     */
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decode(String.self, forKey: .type)) ?? Self.unreadableType
        event = try? c.decode(String.self, forKey: .event)
        attribute = try? c.decode(String.self, forKey: .attribute)
        self.operator = try? c.decode(String.self, forKey: .operator)
        value = try? c.decode(AnyCodable.self, forKey: .value)
    }
}

public struct InAppCampaign: Codable {
    public let id: String
    public let name: String

    /// Presentation, NOT content. Decides placement; a `custom` campaign is
    /// still HTML, it simply asks the host app to place it.
    public let type: MessageType

    public let priority: Int
    public let evaluationMode: String

    /// What to render. ONE field, discriminated on `kind`.
    ///
    /// Replaced `template` + `renderedHtml` + `liquidEnabled`, which expressed
    /// one message three ways and left each SDK to pick - and they picked
    /// differently. The server now sends exactly what should appear on screen,
    /// Liquid already resolved, so no SDK needs a Liquid engine (iOS and
    /// Android never had one) and every platform shows the same thing.
    public let contentPayload: ContentPayload?
    public let targeting: Targeting?
    public let frequencyCap: FrequencyCap?
    public let watchedAttributes: [String]?
    /**
     Conditions under which to display, evaluated ON DEVICE.

     The server has sent these all along; this model simply did not decode
     them, so `event` triggers could not fire locally on iOS and a message set
     to "show when the user does add_to_cart" waited for the next sync instead
     of appearing at the moment they did it. Web and Android both carried the
     field; iOS was the odd one out.
     */
    public let triggers: [InAppTrigger]?
    /**
     Synced as triggers WITHOUT content: ask the server at display time.

     Set per campaign in the editor. Costs offline display for this campaign -
     with no content held, a trigger firing without a network shows nothing,
     which is the intent: the marketer chose not to show it on stale data.
     */
    public let reevaluateBeforeDisplay: Bool?

    /// Seconds to wait after the trigger fires before showing this message.
    ///
    /// The server sends it as `delay`. It was documented and collected in the
    /// dashboard for a long time while nothing sent or read it, so a
    /// marketer's "wait 30 seconds" displayed immediately.
    public let delay: Int?

    /**
     Signed proof that the SERVER served this exact message, to this subject, for
     this campaign/variant. Issued per delivery in the sync response.

     MUST be echoed back verbatim on every track call. The server takes tenant,
     campaign, variant and subject FROM THE TOKEN and ignores the equivalent body
     fields, and permits each transition exactly once per delivery. That is what
     stops a holder of the publishable SDK key reporting interactions with content
     that was never served, or replaying one to inflate campaign and A/B metrics.

     Treat it as opaque - never construct, parse, or reuse one across messages.
     It is cached with the campaign, which matters: in-app is a PULL channel, so a
     device may sync, go offline, display, and only report days later. The token
     has to still be there when it does.

     `nil` for an anonymous visitor with no resolvable subject, and for servers
     predating the token.
     */
    public let deliveryToken: String?

    /// The content to render, resolved from the wire fields.
    ///
    /// `nil` means the campaign carries no usable document. Callers must treat
    /// that as "do not display" rather than showing an empty container: a blank
    /// modal the user has to dismiss is worse than no message, and counting an
    /// impression for it inflates the campaign's reach.
    public var content: InAppContent? {
        guard let c = contentPayload else { return nil }
        switch c.kind {
        case "html":
            guard let html = c.html, !html.isEmpty else { return nil }
            return .html(html: html, css: c.css ?? "")

        case "native":
            guard let body = c.body, !body.isEmpty else { return nil }
            return .native(
                NativeContent(
                    title: c.title?.isEmpty == false ? c.title : nil,
                    body: body,
                    imageUrl: c.imageUrl?.isEmpty == false ? c.imageUrl : nil,
                    buttons: (c.buttons ?? []).compactMap { b in
                        guard let text = b.text, !text.isEmpty else { return nil }
                        return NativeContent.Button(
                            id: b.id ?? "",
                            text: text,
                            action: ButtonAction(raw: b.action),
                            url: b.url
                        )
                    },
                    closeButton: c.closeButton ?? true,
                    backdropDismissible: c.backdropDismissible ?? true,
                    style: c.style.map {
                        NativeContent.NativeStyle(
                            backgroundColor: $0.backgroundColor,
                            textColor: $0.textColor,
                            primaryButtonColor: $0.primaryButtonColor,
                            primaryButtonTextColor: $0.primaryButtonTextColor,
                            cornerRadius: $0.cornerRadius,
                            fontSize: $0.fontSize,
                            titleWeight: $0.titleWeight,
                            textAlign: $0.textAlign,
                            fontFamily: $0.fontFamily
                        )
                    }
                )
            )

        default:
            // A kind this SDK version does not know. Skip rather than guess -
            // a half-rendered message is worse than none.
            return nil
        }
    }

    /**
     The widest this HTML message may be, in points, or nil when its type is
     not content-sized (banner, fullscreen, custom) or its content is native.

     The server sends the resolved value as `content.maxWidth`; a payload that
     predates the field gets the same per-type default every SDK uses
     (`InAppSizing.defaultMaxWidth`). The renderer gives the message
     min(maxWidth, screen width - its margins), so a design authored at 680
     stays 680 on an iPad instead of stretching edge to edge, and fits the
     screen on a phone.
     */
    public var maxWidth: Double? {
        guard type == .modal || type == .slideup,
              let c = contentPayload, c.kind == "html" else { return nil }
        if let mw = c.maxWidth, mw.isFinite, mw > 0 { return mw.rounded(.down) }
        return InAppSizing.defaultMaxWidth(for: type)
    }

    public enum MessageType: String, Codable {
        case modal
        case banner
        case slideup
        case fullscreen
        /// Host app decides placement; content is still HTML.
        case custom

        /// Unknown values decode to `.custom` rather than throwing.
        ///
        /// A server that adds a presentation type must not break every shipped
        /// app - an old SDK should hand the campaign to the host app, not fail
        /// to decode the whole sync response and drop every campaign in it.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = MessageType(rawValue: raw) ?? .custom
        }
    }

    /// Wire shape of the `content` field.
    public struct ContentPayload: Codable {
        public let kind: String

        // kind = "html"
        public let html: String?
        public let css: String?
        /// Widest the message may be, in points. Sent for `modal` and
        /// `slideup`; read through `InAppCampaign.maxWidth`.
        public let maxWidth: Double?

        // kind = "native"
        public let title: String?
        public let body: String?
        public let imageUrl: String?
        public let buttons: [ButtonPayload]?
        public let closeButton: Bool?
        public let backdropDismissible: Bool?
        public let style: StylePayload?

        public struct StylePayload: Codable {
            public let backgroundColor: String?
            public let textColor: String?
            public let primaryButtonColor: String?
            public let primaryButtonTextColor: String?
            public let cornerRadius: Double?
            public let fontSize: Double?
            public let titleWeight: String?
            public let textAlign: String?
            public let fontFamily: String?
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
            html = try? c.decode(String.self, forKey: .html)
            css = try? c.decode(String.self, forKey: .css)
            maxWidth = try? c.decode(Double.self, forKey: .maxWidth)
            title = try? c.decode(String.self, forKey: .title)
            body = try? c.decode(String.self, forKey: .body)
            imageUrl = try? c.decode(String.self, forKey: .imageUrl)
            buttons = try? c.decode([ButtonPayload].self, forKey: .buttons)
            closeButton = try? c.decode(Bool.self, forKey: .closeButton)
            style = try? c.decode(StylePayload.self, forKey: .style)
            backdropDismissible = try? c.decode(Bool.self, forKey: .backdropDismissible)
        }

        enum CodingKeys: String, CodingKey {
            case kind, html, css, maxWidth, title, body, imageUrl, buttons, closeButton, backdropDismissible, style
        }
    }

    public struct ButtonPayload: Codable {
        public let id: String?
        public let text: String?
        public let action: String?
        public let url: String?

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try? c.decode(String.self, forKey: .id)
            text = try? c.decode(String.self, forKey: .text)
            action = try? c.decode(String.self, forKey: .action)
            url = try? c.decode(String.self, forKey: .url)
        }

        enum CodingKeys: String, CodingKey { case id, text, action, url }
    }

    public struct FrequencyCap: Codable {
        /**
         How many times, or `nil` for UNLIMITED.

         Nullable because the composer sends null for it. "Allow this campaign
         to show more than once per user" with no number means no ceiling, and
         the backend and web SDK have always read a missing/null value that way.

         It was `Int` here, and Swift cannot decode null into a non-optional -
         so `try? decode(FrequencyCap.self)` threw and the WHOLE cap came back
         nil. With no cap, iOS fell through to its show-once-ever set, and a
         marketer who explicitly asked for unlimited got exactly one display.
         The setting did the opposite of what it said.
         */
        public let maxImpressions: Int?
        public let timeWindow: String
        public let minDelayBetweenImpressions: Int?
    }

    public struct Targeting: Codable {
        public let segments: [String]?

        enum CodingKeys: String, CodingKey { case segments }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            segments = try? c.decode([String].self, forKey: .segments)
        }
    }

    // Defaulted so a payload missing an optional scalar still decodes. The
    // whole sync response is one document: a strict decode of one field would
    // discard every campaign in it, not just the affected one.
    enum CodingKeys: String, CodingKey {
        case id, name, type, priority, evaluationMode
        // Property is contentPayload (the computed `content` takes that name),
        // so the wire key is mapped explicitly - without this Swift cannot
        // synthesize encode(to:) and the type silently loses Encodable, which
        // the on-disk campaign cache needs.
        case contentPayload = "content"
        case targeting, frequencyCap, watchedAttributes, delay, triggers
        case reevaluateBeforeDisplay
        // MUST be listed: this type has an explicit CodingKeys enum, so a field
        // missing from it never decodes - the token would silently always be nil
        // and every impression would look unverifiable to the server.
        case deliveryToken
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        type = (try? c.decode(MessageType.self, forKey: .type)) ?? .custom
        priority = (try? c.decode(Int.self, forKey: .priority)) ?? 0
        evaluationMode = (try? c.decode(String.self, forKey: .evaluationMode)) ?? "session-start-only"
        contentPayload = try? c.decode(ContentPayload.self, forKey: .contentPayload)
        targeting = try? c.decode(Targeting.self, forKey: .targeting)
        frequencyCap = try? c.decode(FrequencyCap.self, forKey: .frequencyCap)
        watchedAttributes = try? c.decode([String].self, forKey: .watchedAttributes)
        delay = try? c.decode(Int.self, forKey: .delay)
        // Tolerant like every field here: a trigger type this SDK version does
        // not know must not discard the whole sync response.
        if let decoded = try? c.decode([InAppTrigger].self, forKey: .triggers) {
            triggers = decoded
        } else if c.contains(.triggers), (try? c.decodeNil(forKey: .triggers)) != true {
            // Present but not a list of triggers: never "display on sync".
            triggers = [InAppTrigger(type: InAppTrigger.unreadableType)]
        } else {
            triggers = nil
        }
        reevaluateBeforeDisplay = try? c.decode(Bool.self, forKey: .reevaluateBeforeDisplay)
        // Tolerant like every field here: a server that predates the delivery
        // token simply yields nil, which the track path treats as "omit".
        deliveryToken = try? c.decode(String.self, forKey: .deliveryToken)
    }
}

/**
 What a campaign renders.

 An enum on purpose. Today there is exactly one case and a `String` would have
 been shorter - but the next content type (native title/body/image, once the
 editor can author it) then becomes a breaking change to every switch in the
 SDK and in host apps. This way it is a new case.
 */
public enum InAppContent {
    /// An HTML document plus its stylesheet, rendered in a WKWebView.
    case html(html: String, css: String)

    /// Structured content rendered with the app's OWN UIKit views.
    ///
    /// No markup, no interpreter - which is the point. An app that disallows
    /// HTML in-app messages can still show these, and they inherit the host
    /// app's Dynamic Type, dark mode and VoiceOver behaviour for free.
    ///
    /// The strings here are TEXT, never markup: the server does not
    /// HTML-escape native fields (escaping would show the user `A &amp; B`),
    /// so putting any of them into a web view would reintroduce exactly the
    /// injection native exists to avoid.
    case native(NativeContent)
}

public struct NativeContent {
    public let title: String?
    public let body: String
    public let imageUrl: String?
    public let buttons: [Button]
    public let closeButton: Bool
    public let backdropDismissible: Bool

    /// Optional presentation overrides set by the campaign author.
    ///
    /// Every field is optional and nil means INHERIT the host app's look, which
    /// is the reason to choose native at all. A campaign sets a colour when it
    /// needs a brand moment; otherwise the app's theme wins.
    public let style: NativeStyle?

    /// Author overrides.
    ///
    /// `fontFamily` is BEST EFFORT: an app can only render a font it ships, so
    /// a name this app does not have leaves the app's own typeface rather than
    /// substituting something arbitrary. Size, weight and alignment need no
    /// font file and always apply.
    public struct NativeStyle {
        public let backgroundColor: String?
        public let textColor: String?
        public let primaryButtonColor: String?
        public let primaryButtonTextColor: String?
        public let cornerRadius: Double?
        /// Body size in points; the headline scales from it.
        public let fontSize: Double?
        /// regular | medium | semibold | bold - the HEADLINE's weight.
        public let titleWeight: String?
        /// auto | start | center | end. `auto` follows the message's own text.
        public let textAlign: String?
        /// Applied only if this app ships the font; otherwise the app's own.
        public let fontFamily: String?
    }

    public struct Button {
        public let id: String
        public let text: String
        public let action: ButtonAction
        public let url: String?
    }
}

/// What a native button does when tapped.
public enum ButtonAction {
    case dismiss
    case url
    case deepLink

    /// Ask for notification permission - the "push primer" button.
    ///
    /// iOS allows exactly one system prompt, so the value of a primer is that a
    /// "no" here costs nothing while a "no" to the system dialog is permanent.
    /// The campaign makes the case; only a yes spends the real prompt.
    case requestPushPermission

    /// Unknown actions become `.dismiss` rather than throwing.
    ///
    /// A server that adds an action must not make older apps crash or - worse -
    /// render a button that does nothing when tapped, trapping the user in a
    /// modal they cannot close.
    init(raw: String?) {
        switch raw?.lowercased() {
        case "url": self = .url
        case "deep_link": self = .deepLink
        case "request_push_permission": self = .requestPushPermission
        default: self = .dismiss
        }
    }
}

// MARK: - Wire types

/// Session sync request.
public struct SessionSyncRequest: Codable {
    public let userId: String
    public let anonymousId: String
    public let sessionId: String
    public let attributes: [String: AnyCodable]?
    /**
     Attributes written locally that the server has not acknowledged yet.

     PRESENCE of this key (even empty) tells the backend this SDK keeps a
     durable attribute queue, so the stored profile is authoritative and only
     these few keys may override it. An older SDK omits the key entirely and
     keeps the previous behaviour, where everything in `attributes` wins.

     That distinction cannot be made from `attributes` alone - an old SDK
     sending its whole set and a new one sending nothing pending are
     indistinguishable without it.
     */
    public let pendingAttributes: [String: AnyCodable]?

    /**
     What this build can render, e.g. `["content.native", "content.html"]`.

     The server stores it per app purely so the campaign editor can warn a
     marketer that an HTML campaign will not display on some of their apps,
     instead of letting them publish into silence. It never gates delivery -
     this device still decides what it shows.

     Omitted by older builds, and the server records that absence as "unknown"
     rather than "cannot", so nothing warns about an integration that simply
     predates the field.
     */
    public let capabilities: [String]?

    public init(
        userId: String,
        anonymousId: String,
        sessionId: String,
        attributes: UserAttributes? = nil,
        pendingAttributes: UserAttributes? = nil,
        capabilities: [String]? = nil
    ) {
        self.userId = userId
        self.anonymousId = anonymousId
        self.sessionId = sessionId
        self.attributes = attributes?.mapValues { AnyCodable($0) }
        // Always encoded (empty when nothing is pending) so the backend can
        // detect the capability rather than infer it.
        self.pendingAttributes = (pendingAttributes ?? [:]).mapValues { AnyCodable($0) }
        self.capabilities = capabilities
    }
}

/// Session sync response.
public struct SessionSyncResponse: Codable {
    public let success: Bool
    public let campaigns: [InAppCampaign]
    public let evaluatedAt: String
    /// DEPRECATED and unused: no SDK ever acted on it. Optional so the server
    /// can stop sending it without breaking decode - as a non-optional String
    /// its absence made JSONDecoder throw, which fails the WHOLE response and
    /// leaves the app with no campaigns at all.
    public let nextEvaluationStrategy: String?
    public let delayBetweenCampaigns: Int?
    public let error: String?
}

/// Track impression request.
public struct TrackImpressionRequest: Codable {
    public let campaignId: String
    public let userId: String
    public let anonymousId: String
    public let sessionId: String
    public let action: String
    public let timestamp: Date

    /// STRUCTURED MARKERS, matching what the web SDK sends.
    ///
    /// This request used to carry the interaction ONLY in `action`, while the
    /// web SDK set displayedAt / clicked+clickedAt / dismissedAt. The backend
    /// gate that decides whether to emit `in_app.displayed` reads those markers,
    /// so on mobile every call fell through to "this is a display" - one message
    /// displayed, clicked and dismissed emitted THREE in_app.displayed events,
    /// inflating mobile display counts up to 3x and over-crediting revenue
    /// attribution, which joins on that event.
    ///
    /// The backend now understands both shapes, so this is not what fixes it -
    /// it removes the second shape, which is what allowed it. One event, one
    /// wire format, whichever SDK reports it.
    ///
    /// Synthesized Codable omits nil, so only the markers relevant to this call
    /// are sent. ISO-8601 to match web; the backend also tolerates epoch millis.
    public let displayedAt: String?
    public let clicked: Bool?
    public let clickedAt: String?
    public let dismissedAt: String?
    public let converted: Bool?
    public let convertedAt: String?

    /// Echoed from `InAppCampaign.deliveryToken` - see that field. Synthesized
    /// Codable omits a nil optional entirely, which is what the server needs:
    /// an explicit null would be read as a malformed token rather than as absent.
    public let deliveryToken: String?

    /// WHICH button or link was clicked - the message's own name for it (a
    /// button id, a link's `data-action`). Separate from `action`, which must be
    /// a vocabulary word (`clicked`): the backend refuses an unknown action as a
    /// client bug, so a click reported as `action: "buy_now"` was never
    /// recorded at all.
    public let elementId: String?

    /// Everything after `action` defaults, so existing callers keep compiling.
    public init(
        campaignId: String,
        userId: String,
        anonymousId: String,
        sessionId: String,
        action: String,
        displayedAt: String? = nil,
        clicked: Bool? = nil,
        clickedAt: String? = nil,
        dismissedAt: String? = nil,
        converted: Bool? = nil,
        convertedAt: String? = nil,
        timestamp: Date = Date(),
        deliveryToken: String? = nil,
        elementId: String? = nil
    ) {
        self.campaignId = campaignId
        self.userId = userId
        self.anonymousId = anonymousId
        self.sessionId = sessionId
        self.action = action
        self.displayedAt = displayedAt
        self.clicked = clicked
        self.clickedAt = clickedAt
        self.dismissedAt = dismissedAt
        self.converted = converted
        self.convertedAt = convertedAt
        self.timestamp = timestamp
        self.deliveryToken = deliveryToken
        self.elementId = elementId
    }
}

/// What host-app callbacks receive.
///
/// `InAppConfig`'s onMessageDisplay/Click/Dismiss took an `InAppMessage` - the
/// old structured model. The campaign IS the message now, so this is an alias
/// rather than a second type: two shapes describing one payload is how the
/// SDKs drifted from the server in the first place.
public typealias InAppMessage = InAppCampaign

/// Body of `POST /v1/in-app/resolve` - the display-time re-check.
public struct ResolveRequest: Codable {
    public let userId: String
    public let anonymousId: String
    public let sessionId: String
    public let campaignId: String
    public let attributes: [String: AnyCodable]?
    public let pendingAttributes: [String: AnyCodable]?

    public init(
        userId: String,
        anonymousId: String,
        sessionId: String,
        campaignId: String,
        attributes: UserAttributes? = nil,
        pendingAttributes: UserAttributes? = nil
    ) {
        self.userId = userId
        self.anonymousId = anonymousId
        self.sessionId = sessionId
        self.campaignId = campaignId
        self.attributes = attributes?.mapValues { AnyCodable($0) }
        self.pendingAttributes = (pendingAttributes ?? [:]).mapValues { AnyCodable($0) }
    }
}

/// `eligible: false` is a NORMAL answer - the user no longer qualifies - and
/// must be distinguishable from a transport failure, which is why it is a
/// 200 body rather than a 404.
public struct ResolveResponse: Codable {
    public let eligible: Bool
    public let campaign: InAppCampaign?
}

// MARK: - Forms inside messages (landing pages phase C, 2026-09-26)

/// A form value as the message serialises it: a string, or the list a
/// checkbox group produces. Encoded as a JSON string or array.
enum InAppFormValue: Encodable {
    case string(String)
    case list([String])

    // Internal on purpose: the SDK's no-ambiguous-overloads tripwire counts
    // every `public func` across files, and Event.swift already has an encode.
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .list(let l): try c.encode(l)
        }
    }
}

/// What the SDK posts when a form inside a message is submitted: the values,
/// with THIS SDK's identity so the backend writes them to the right person.
struct InAppFormSubmitRequest: Encodable {
    let campaignId: String
    let userId: String?
    let anonymousId: String
    let values: [String: InAppFormValue]
}

/// The server's verdict, handed back to the message runtime as it is.
public struct InAppFormSubmitResponse: Codable {
    public let ok: Bool
    public let message: String?
    public let redirect: String?
    public let errors: [String]?

    public init(ok: Bool, message: String? = nil, redirect: String? = nil, errors: [String]? = nil) {
        self.ok = ok
        self.message = message
        self.redirect = redirect
        self.errors = errors
    }
}


/**
 Sizing of content-sized (modal / slideup) HTML messages. The same numbers as
 the backend contract (`IN_APP_DEFAULT_MAX_WIDTH`) and every other SDK.
 */
public enum InAppSizing {
    /// Fallback when the payload carries no `maxWidth`: modal 600, slideup 400.
    public static func defaultMaxWidth(for type: InAppCampaign.MessageType) -> Double? {
        switch type {
        case .modal: return 600
        case .slideup: return 400
        default: return nil
        }
    }

    /// The height a partial (non-fullscreen) HTML message is given: what the
    /// content reported, at least 1pt, at most `cap`. Follows the content
    /// down as well as up.
    public static func contentHeight(reported: Double, cap: Double) -> Double {
        min(max(reported, 1), cap)
    }

    /// min(maxWidth, available - margin on each side), never negative.
    public static func frameWidth(maxWidth: Double, available: Double, margin: Double) -> Double {
        max(0, min(maxWidth, available - 2 * margin))
    }
}
