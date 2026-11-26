import Foundation
import MachO
import UIKit

/// `isAppDeepLink`, reachable where a member of the same name shadows it.
private func appDeepLink(_ url: String) -> Bool { isAppDeepLink(url) }

/// Where a link the SDK is about to open came from. The raw values are the
/// wire values, identical on every Joryio SDK (they cross the React Native and
/// Unity bridges as these strings), pinned by the backend spec
/// sdk-link-handler-parity.spec.ts.
public enum JoryioLinkSource: String {
    /// A button or link in an in-app message.
    case inApp = "in_app"
    /// A button or link in a placement (`PlacementView`).
    case placement
    /// A content card tap (`CardFeedViewController` / `JoryioCardFeed`).
    case card
    /// A push notification tap (its `jry_deep_link`).
    case push
}

/// A link the SDK is about to open, handed to the app's link handler first
/// (`Joryio.shared.setLinkHandler`).
///
/// `url` is either an http(s) link or an app deep link (`myapp://cart`, see
/// `isAppDeepLink`); a push link may also be any other scheme the system can
/// open (`mailto:`). A refused scheme (`javascript:`, `data:`, `file:`, ... -
/// the list every Joryio SDK shares) never reaches the handler.
public final class JoryioLink {
    public let url: URL
    public let source: JoryioLinkSource
    /// The in-app campaign, card campaign or push campaign, when known.
    public let campaignId: String?
    /// The placement the link was tapped in (source `placement`).
    public let placementKey: String?
    /// The placement item (source `placement`).
    public let itemId: String?
    /// The card (source `card`).
    public let cardId: String?

    private let fallback: () -> Void
    private var done = false

    init(url: URL, source: JoryioLinkSource, campaignId: String? = nil, placementKey: String? = nil,
         itemId: String? = nil, cardId: String? = nil, fallback: @escaping () -> Void) {
        self.url = url
        self.source = source
        self.campaignId = campaignId
        self.placementKey = placementKey
        self.itemId = itemId
        self.cardId = cardId
        self.fallback = fallback
    }

    /// True for an app-scheme link (`myapp://cart`), false for http(s).
    public var isAppDeepLink: Bool { appDeepLink(url.absoluteString) }

    /// Do what the SDK does when no handler takes the link: an http(s) link
    /// opens (through the app's own universal-link handling when
    /// `forwardUniversalLinks` is on and the host is one of the app's
    /// associated domains), an app deep link goes to the view's `onDeepLink`.
    /// For a handler that decides later (after a prompt, or across the React
    /// Native or Unity bridge). Runs at most once; on the main thread.
    public func openDefault() {
        let run = { [self] in
            guard !done else { return }
            done = true
            fallback()
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }
}

/// The app's link handler: return true to take the link over, false to let
/// the SDK open it as it would without a handler.
public typealias JoryioLinkHandler = (JoryioLink) -> Bool

/// The one way every SDK surface (in-app messages, placements, cards, push)
/// opens a link: refused schemes stop here, the app's handler goes first, then
/// the surface's own fallback. SDK-internal: apps use
/// `Joryio.shared.setLinkHandler`.
@_spi(JoryioInternal)
public enum LinkRouter {
    private static let lock = NSLock()
    private static var _handler: JoryioLinkHandler?
    private static var _forwardUniversalLinks = false
    static var logger = Logger(enabled: false, logLevel: .error)

    static var handler: JoryioLinkHandler? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }

    /// Whether the app set a handler (`setLinkHandler`).
    public static var hasHandler: Bool { handler != nil }

    /// `JoryioConfig.forwardUniversalLinks`, set by `initialize()`.
    public static var forwardUniversalLinks: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _forwardUniversalLinks }
        set { lock.lock(); _forwardUniversalLinks = newValue; lock.unlock() }
    }

    /// An http(s) URL the SDK may open itself.
    public static func isSafeHttpUrl(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "https" || scheme == "http"
    }

    /// A scheme no Joryio SDK ever opens nor hands on.
    public static func isRefusedScheme(_ url: URL) -> Bool {
        REFUSED_LINK_SCHEMES.contains(url.scheme?.lowercased() ?? "")
    }

    /**
     Route a link: the app's handler first, then `fallback`.

     `allowOtherSchemes` is for push only, whose link has always been opened by
     the system whatever its scheme (`mailto:`); everywhere else a link must be
     http(s) or an app deep link. A refused scheme never gets past here.
     Returns false when the link was refused.
     */
    @discardableResult
    public static func route(
        _ url: URL,
        source: JoryioLinkSource,
        campaignId: String? = nil,
        placementKey: String? = nil,
        itemId: String? = nil,
        cardId: String? = nil,
        allowOtherSchemes: Bool = false,
        fallback: @escaping () -> Void
    ) -> Bool {
        guard !isRefusedScheme(url),
              isSafeHttpUrl(url) || appDeepLink(url.absoluteString) || (allowOtherSchemes && url.scheme != nil)
        else {
            logger.debug("Link refused: \(url.scheme ?? "no scheme")")
            return false
        }
        let link = JoryioLink(url: url, source: source, campaignId: campaignId, placementKey: placementKey,
                              itemId: itemId, cardId: cardId, fallback: fallback)
        if let handler, handler(link) { return true }
        link.openDefault()
        return true
    }

    /// The http(s) fallback: the app's own universal-link handling when
    /// `forwardUniversalLinks` is on and the host is an associated domain,
    /// the system otherwise.
    public static func openExternally(_ url: URL) {
        guard isSafeHttpUrl(url) else { return }
        let open = {
            if forwardUniversalLinks, UniversalLinks.isOwnUniversalLink(url, logger: logger), UniversalLinks.continueInApp(url) {
                logger.debug("Universal link handed to the app: \(url.host ?? "")")
                return
            }
            UIApplication.shared.open(url)
        }
        if Thread.isMainThread { open() } else { DispatchQueue.main.async(execute: open) }
    }
}

/// The app's associated domains (`applinks:` entries), read once from its own
/// code signature, and the hand-off of a matching link to the app's own
/// universal-link handling.
enum UniversalLinks {
    private static let lock = NSLock()
    private static var loaded = false
    private static var cached: [String]?

    /// The `applinks:` hosts of this app, nil when the entitlements cannot be read.
    static func associatedDomains(logger: Logger) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        if !loaded {
            loaded = true
            cached = readEntitlements().map(applinkHosts(fromEntitlements:))
            if cached == nil {
                // Logged ONCE: every later link falls back to the system open.
                logger.warn("forwardUniversalLinks is on but the app's associated domains could not be read; links open with the system as before")
            }
        }
        return cached
    }

    static func isOwnUniversalLink(_ url: URL, logger: Logger) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host,
              let domains = associatedDomains(logger: logger) else { return false }
        return matches(host: host, domains: domains)
    }

    /// `host` is one of `domains` (`shop.com`), or a subdomain of a wildcard
    /// entry (`*.shop.com` matches `www.shop.com`, not `shop.com` itself -
    /// list the apex on its own, as Apple asks).
    static func matches(host: String, domains: [String]) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !h.isEmpty else { return false }
        for raw in domains {
            let d = raw.lowercased()
            if d.hasPrefix("*.") {
                let base = String(d.dropFirst(2))
                if !base.isEmpty, h.hasSuffix("." + base) { return true }
            } else if d == h {
                return true
            }
        }
        return false
    }

    /// The hosts of the `applinks:` entries of an entitlements dictionary:
    /// `applinks:shop.com?mode=developer` -> `shop.com`. Other services
    /// (`webcredentials:`) are not universal links.
    static func applinkHosts(fromEntitlements entitlements: [String: Any]) -> [String] {
        let entries = entitlements["com.apple.developer.associated-domains"] as? [String] ?? []
        return entries.compactMap { entry in
            guard entry.lowercased().hasPrefix("applinks:") else { return nil }
            var host = String(entry.dropFirst("applinks:".count))
            if let q = host.firstIndex(of: "?") { host = String(host[..<q]) }
            if let c = host.lastIndex(of: ":"), !host.hasPrefix("[") { host = String(host[..<c]) }
            host = host.trimmingCharacters(in: .whitespaces)
            return host.isEmpty ? nil : host
        }
    }

    /// The entitlements plist inside a code-signature SuperBlob (big-endian:
    /// magic 0xfade0cc0, count, then {type, offset} entries; slot 5 is the
    /// entitlements blob, magic 0xfade7171, its length, then the XML).
    static func entitlementsPlist(fromCodeSignature data: Data) -> Data? {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> UInt32? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            return UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
        }
        guard u32(0) == 0xfade0cc0, let count = u32(8), count < 64 else { return nil }
        for i in 0..<Int(count) {
            guard let type = u32(12 + i * 8), let offset = u32(16 + i * 8) else { return nil }
            guard type == 5 else { continue }
            let start = Int(offset)
            guard u32(start) == 0xfade7171, let length = u32(start + 4), length >= 8,
                  start + Int(length) <= bytes.count else { return nil }
            return Data(bytes[(start + 8)..<(start + Int(length))])
        }
        return nil
    }

    static func entitlements(fromPlist data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    /// This app's entitlements: the simulator's `__TEXT,__entitlements`
    /// section, else the code signature of the main executable on disk.
    private static func readEntitlements() -> [String: Any]? {
        if let header = _dyld_get_image_header(0) {
            var size: UInt = 0
            let raw = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
            if let section = getsectiondata(raw, "__TEXT", "__entitlements", &size), size > 0,
               let dict = entitlements(fromPlist: Data(bytes: section, count: Int(size))) {
                return dict
            }
        }
        guard let path = Bundle.main.executablePath, let signature = codeSignature(atPath: path),
              let plist = entitlementsPlist(fromCodeSignature: signature) else { return nil }
        return entitlements(fromPlist: plist)
    }

    /// The LC_CODE_SIGNATURE blob of a thin 64-bit Mach-O (what an installed
    /// app's executable is), read without loading the whole binary.
    private static func codeSignature(atPath path: String) -> Data? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        let header = file.readData(ofLength: MemoryLayout<mach_header_64>.size)
        guard header.count == MemoryLayout<mach_header_64>.size else { return nil }
        let mh = header.withUnsafeBytes { $0.load(as: mach_header_64.self) }
        guard mh.magic == MH_MAGIC_64, mh.sizeofcmds < 4_000_000 else { return nil }
        let commands = file.readData(ofLength: Int(mh.sizeofcmds))
        guard commands.count == Int(mh.sizeofcmds) else { return nil }
        var offset = 0
        for _ in 0..<Int(mh.ncmds) {
            guard offset + 8 <= commands.count else { return nil }
            let cmd = commands.withUnsafeBytes { $0.load(fromByteOffset: offset, as: load_command.self) }
            if cmd.cmd == UInt32(LC_CODE_SIGNATURE), offset + MemoryLayout<linkedit_data_command>.size <= commands.count {
                let sig = commands.withUnsafeBytes { $0.load(fromByteOffset: offset, as: linkedit_data_command.self) }
                guard sig.datasize < 16_000_000 else { return nil }
                file.seek(toFileOffset: UInt64(sig.dataoff))
                let data = file.readData(ofLength: Int(sig.datasize))
                return data.count == Int(sig.datasize) ? data : nil
            }
            guard cmd.cmdsize > 0 else { return nil }
            offset += Int(cmd.cmdsize)
        }
        return nil
    }

    /// Deliver `url` as the system delivers a universal link: an
    /// NSUserActivity of type browsing-web to the active scene's delegate
    /// (`scene(_:continue:)`), else the app delegate
    /// (`application(_:continue:restorationHandler:)`). False when neither
    /// takes it, and the caller opens it with the system instead.
    static func continueInApp(_ url: URL) -> Bool {
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = url
        let app = UIApplication.shared
        let scenes = Array(app.connectedScenes)
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        if let scene, let delegate = scene.delegate, delegate.scene?(scene, continue: activity) != nil {
            return true
        }
        if let delegate = app.delegate,
           let taken = delegate.application?(app, continue: activity, restorationHandler: { _ in }) {
            return taken
        }
        return false
    }
}
