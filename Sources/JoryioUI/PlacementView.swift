#if canImport(UIKit)
import UIKit
import WebKit
import SwiftUI
#if SWIFT_PACKAGE
// SwiftPM: JoryioUI is its own module. CocoaPods: Joryio/UI is a subspec
// compiled INTO the Joryio module, where this import is a warning that
// fails `pod lib lint` (and so `pod trunk push`).
import Joryio
@_spi(JoryioInternal) import Joryio
#endif

/**
 A placement inside your layout (docs/PLACEMENTS_PLAN.md, D444):

 ```swift
 let hero = PlacementView(placementKey: "home_hero")
 stack.addArrangedSubview(hero)
 ```

 The SDK fills it for the signed-in person, draws native items as a card and
 HTML items (delivered only with `allowHtmlJsInAppMessages`) in a web view
 with no script, measures viewability - at least
 `Placements.PLACEMENT_VIEWABLE_FRACTION` of an item inside the window for
 `InAppDisplay.IN_APP_DISPLAY_DWELL_MS` while the app is active - and reports
 impressions, clicks and dismissals. A held-out person sees nothing and the
 empty spot reports `in_app.control_viewed` the same way.

 Content is never swapped while the view is on screen: a newer answer is
 applied when it next leaves the screen or moves to a window again.

 Empty: `collapse` gives the view no intrinsic height; `keep_space` keeps the
 height it last had.

 Recommended products (an item's `products`) are drawn as a horizontal row of
 cards - image, title, price (the compare-at price struck through) and, with
 `productButtonText`, a button - below the item's content, or alone for a
 data item. A tap reports `clicked` with `Placements.placementProductElementId`
 and opens the product's link like a `deep_link` button, through
 `Joryio.shared.setLinkHandler` first (source `placement`). Colours and fonts
 are the system's semantic ones and the view's `tintColor`, so the app's theme,
 dark mode and Dynamic Type apply. `showProducts = false` leaves the products
 to you.
 */
public final class PlacementView: UIView, PlacementHost {
    public private(set) var placementKey: String

    /// Called after the view (re)drew, with what it drew.
    public var onRender: ((Placement) -> Void)?

    /// A `deep_link` button with an app link (`myapp://cart`) was tapped:
    /// route it in your app (the click is already reported). An http(s) link
    /// is opened by the view instead, and any other scheme (javascript:,
    /// data:, intent:, ...) is refused - it reaches neither this handler nor
    /// the system. A handler set with `Joryio.shared.setLinkHandler` sees
    /// every link first; this one is called when it returns false.
    public var onDeepLink: ((URL, PlacementItem) -> Void)?

    /// Draw an item's recommended products as a row of cards (default true).
    /// Set before the view is on screen; it applies from the next draw.
    public var showProducts: Bool = true
    /// Label of a button on every product card; nil = no button (the whole card opens the product).
    public var productButtonText: String?
    /// Width of one product card, in points.
    public var productCardWidth: CGFloat = CGFloat(Placements.PLACEMENT_PRODUCT_CARD_WIDTH)

    private let stack = UIStackView()
    private var drawn: [(UIView, PlacementItem)] = []
    private var pending: Placement?
    private var keptHeight: CGFloat = 0
    private var heightConstraint: NSLayoutConstraint?
    private var timer: Timer?
    /// Attached to the SDK (false until Joryio is initialized: retried on every tick).
    private var attached = false

    private let viewability = ViewabilityTracker()

    public init(placementKey: String) {
        self.placementKey = placementKey
        super.init(frame: .zero)
        setUp()
    }

    public required init?(coder: NSCoder) {
        self.placementKey = ""
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Point the view at another placement (also the Interface Builder route).
    public func setPlacementKey(_ key: String) {
        guard key != placementKey else { return }
        Joryio.shared.detachPlacementHost(self)
        attached = false
        placementKey = key
        pending = nil
        clear()
        if window != nil { attach() }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if let p = pending { render(p) }
            attach()
            startTimer()
        } else {
            Joryio.shared.detachPlacementHost(self)
            attached = false
            stopTimer()
            viewability.resetDwell()
        }
    }

    private func attach() {
        guard !attached, !placementKey.isEmpty else { return }
        attached = Joryio.shared.attachPlacementHost(self)
    }

    // MARK: PlacementHost

    public func shownIds() -> [String] { drawn.map { $0.1.id } }

    public func clearPlacement() {
        pending = nil
        clear()
        heightConstraint?.isActive = false
        heightConstraint = nil
        invalidateIntrinsicContentSize()
    }

    public func onPlacementUpdated(_ placement: Placement) {
        // Never under the reader's eyes.
        if !drawn.isEmpty, visibleFraction(self) > 0 {
            pending = placement
            return
        }
        render(placement)
    }

    // MARK: Drawing

    private func clear() {
        viewability.removeAll()
        drawn.forEach { $0.0.removeFromSuperview() }
        drawn = []
    }

    private func render(_ placement: Placement) {
        pending = nil
        let previous = bounds.height
        clear()
        for item in placement.items {
            guard let v = view(for: item) else { continue }
            stack.addArrangedSubview(v)
            drawn.append((v, item))
            viewability.add(v) { item.markDisplayed() }
        }
        heightConstraint?.isActive = false
        heightConstraint = nil
        if drawn.isEmpty {
            keptHeight = placement.emptyBehavior == Placements.keepSpace ? previous : 0
            let c = heightAnchor.constraint(greaterThanOrEqualToConstant: keptHeight)
            c.priority = .defaultHigh
            c.isActive = true
            heightConstraint = c
            // A held-out spot reports control_viewed; on any empty spot it also tells
            // the SDK the spot was viewable (a deferred control of a Show when campaign).
            viewability.add(self) { placement.markDisplayed() }
        }
        accessibilityElementsHidden = drawn.isEmpty
        invalidateIntrinsicContentSize()
        onRender?(placement)
    }

    private func view(for item: PlacementItem) -> UIView? {
        var node: UIView?
        if let content = item.content {
            switch content.kind {
            case "native": node = nativeCard(item, content)
            case "html": node = htmlView(item, content)
            default: return nil
            }
        }
        // Recommended products: a row of cards below the content, or alone for
        // a data item (without products a data item is the app's to draw).
        let products = showProducts ? item.products : []
        guard !products.isEmpty else { return node }
        let row = productRow(item, products)
        guard let node else { return row }
        let box = UIStackView(arrangedSubviews: [node, row])
        box.axis = .vertical
        box.spacing = 8
        return box
    }

    // MARK: Product cards

    private func productRow(_ item: PlacementItem, _ products: [PlacementProduct]) -> UIView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.accessibilityIdentifier = "joryio-placement-products:\(item.id)"
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .top
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 12, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            // The row is as tall as its cards: the scroll view takes that height.
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        let width = productCardWidth > 0 ? productCardWidth : CGFloat(Placements.PLACEMENT_PRODUCT_CARD_WIDTH)
        for p in products { row.addArrangedSubview(productCard(item, p, width: width)) }
        return scroll
    }

    private func productCard(_ item: PlacementItem, _ p: PlacementProduct, width: CGFloat) -> UIView {
        let card = UIStackView()
        card.axis = .vertical
        card.spacing = 4
        card.accessibilityIdentifier = "joryio-placement-product:\(p.id)"
        card.widthAnchor.constraint(equalToConstant: width).isActive = true
        if let url = p.imageUrl {
            let image = UIImageView()
            image.contentMode = .scaleAspectFill
            image.clipsToBounds = true
            image.layer.cornerRadius = 8
            image.backgroundColor = .secondarySystemBackground
            image.heightAnchor.constraint(equalTo: image.widthAnchor).isActive = true
            card.addArrangedSubview(image)
            ImageLoader.load(url, into: image)
        }
        if let title = p.title, !title.isEmpty {
            let label = UILabel()
            label.text = title
            label.numberOfLines = 2
            label.textColor = .label
            label.font = UIFont.preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            card.addArrangedSubview(label)
        }
        if let price = p.price, !price.isEmpty {
            let label = UILabel()
            let text = NSMutableAttributedString(string: price, attributes: [.foregroundColor: UIColor.label])
            if let was = p.compareAtPrice, !was.isEmpty {
                text.append(NSAttributedString(string: " "))
                text.append(NSAttributedString(string: was, attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: UIColor.secondaryLabel,
                ]))
            }
            label.attributedText = text
            label.font = UIFont.preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
            label.adjustsFontForContentSizeCategory = true
            card.addArrangedSubview(label)
        }
        guard p.url != nil else { return card }
        if let text = productButtonText, !text.isEmpty {
            let button = UIButton(type: .system)
            button.setTitle(text, for: .normal)
            button.contentHorizontalAlignment = .leading
            button.addAction(UIAction { [weak self, weak item] _ in
                guard let item else { return }
                self?.productTapped(item, p)
            }, for: .touchUpInside)
            card.addArrangedSubview(button)
        } else {
            card.isAccessibilityElement = true
            card.accessibilityTraits = .link
            card.accessibilityLabel = [p.title, p.price].compactMap { $0 }.joined(separator: ", ")
        }
        card.isUserInteractionEnabled = true
        card.addGestureRecognizer(ProductTap(target: self, action: #selector(productCardTapped(_:)), item: item, product: p))
        return card
    }

    @objc private func productCardTapped(_ tap: UITapGestureRecognizer) {
        guard let tap = tap as? ProductTap, let item = tap.item else { return }
        productTapped(item, tap.product)
    }

    /// A product card: report the click as `product:<id>`, then open its link like a `deep_link` button.
    func productTapped(_ item: PlacementItem, _ p: PlacementProduct) {
        buttonAction(item, id: Placements.placementProductElementId(p.id), action: "deep_link", url: p.url)
    }

    private func nativeCard(_ item: PlacementItem, _ content: PlacementContent) -> UIView {
        let card = UIStackView()
        card.axis = .vertical
        card.spacing = 6
        card.isLayoutMarginsRelativeArrangement = true
        card.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        card.accessibilityIdentifier = "joryio-placement-card:\(item.id)"
        if let url = content.imageUrl {
            let image = UIImageView()
            image.contentMode = .scaleAspectFit
            image.clipsToBounds = true
            card.addArrangedSubview(image)
            ImageLoader.load(url, into: image)
        }
        if let title = content.title, !title.isEmpty {
            let label = UILabel()
            label.text = title
            label.numberOfLines = 0
            label.font = UIFont.preferredFont(forTextStyle: .headline)
            label.adjustsFontForContentSizeCategory = true
            card.addArrangedSubview(label)
        }
        if let body = content.body, !body.isEmpty {
            let label = UILabel()
            label.text = body
            label.numberOfLines = 0
            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            card.addArrangedSubview(label)
        }
        if !content.buttons.isEmpty {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            row.distribution = .fillEqually
            for b in content.buttons {
                let button = UIButton(type: .system)
                button.setTitle(b.text, for: .normal)
                button.addAction(UIAction { [weak self, weak item] _ in
                    guard let item else { return }
                    self?.buttonAction(item, id: b.id, action: b.action, url: b.url)
                }, for: .touchUpInside)
                row.addArrangedSubview(button)
            }
            card.addArrangedSubview(row)
        }
        // Inline content has no close control unless the author asked for one.
        if content.closeButton {
            let close = UIButton(type: .close)
            close.accessibilityLabel = "Close"
            close.addAction(UIAction { [weak item] _ in item?.markDismissed() }, for: .touchUpInside)
            card.addArrangedSubview(close)
        }
        return card
    }

    /// Report the click, then act. An inline item stays after a click; only `dismiss` removes it.
    private func buttonAction(_ item: PlacementItem, id: String, action: String, url: String?) {
        item.markClicked(elementId: id)
        switch Self.linkRoute(action: action, url: url, hasDeepLinkHandler: onDeepLink != nil || LinkRouter.hasHandler) {
        case .open(let url):
            open(url, item)
        case .deepLink(let url):
            // The app routes its own links: the app-wide link handler first,
            // then this view's onDeepLink.
            LinkRouter.route(url, source: .placement, placementKey: placementKey, itemId: item.id) { [weak self, weak item] in
                guard let self, let item else { return }
                self.onDeepLink?(url, item)
            }
        case .none:
            if action == "dismiss" || action == "close" { item.markDismissed() }
        }
    }

    /// Where a button's link goes.
    enum LinkRoute: Equatable {
        case open(URL)
        case deepLink(URL)
        case none
    }

    /// A `url` / `deep_link` button: http(s) opens through `isSafeUrl`; a
    /// `deep_link` app link goes to the app's handler only when
    /// `isAppDeepLink` says so; anything else is refused silently.
    static func linkRoute(action: String, url: String?, hasDeepLinkHandler: Bool) -> LinkRoute {
        guard action == "url" || action == "deep_link", let s = url, let parsed = URL(string: s) else { return .none }
        if isSafeUrl(parsed) { return .open(parsed) }
        if action == "deep_link", hasDeepLinkHandler, isAppDeepLink(s) { return .deepLink(parsed) }
        return .none
    }

    /// http(s) only - nothing else is handed to the system.
    static func isSafeUrl(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "https" || scheme == "http"
    }

    /// http(s), through the app-wide link handler first; then the system (or
    /// the app's universal-link handling with `forwardUniversalLinks`).
    private func open(_ url: URL, _ item: PlacementItem?) {
        guard Self.isSafeUrl(url) else { return }
        LinkRouter.route(url, source: .placement, placementKey: placementKey, itemId: item?.id) {
            LinkRouter.openExternally(url)
        }
    }

    /// HTML without script: the document draws, links open outside (and count as clicks).
    private func htmlView(_ item: PlacementItem, _ content: PlacementContent) -> UIView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = PlacementWebView(frame: .zero, configuration: config)
        web.onLink = { [weak self, weak item] url in
            item?.markClicked(elementId: "link_click")
            self?.open(url, item)
        }
        let css = (content.css ?? "").replacingOccurrences(of: "</", with: "<\\/")
        let doc = "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src https: data:; font-src https: data:; media-src https: data:; form-action 'none'; base-uri 'none'\">"
            + "<style>html,body{margin:0;padding:0}img,video{max-width:100%;height:auto}\(css)</style></head><body>\(content.html ?? "")</body></html>"
        web.loadHTMLString(doc, baseURL: nil)
        return web
    }

    // MARK: Viewability

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func visibleFraction(_ v: UIView) -> Double { JoryioViewability.visibleFraction(v) }

    private func tick() {
        if !attached { attach() }
        if let p = pending, visibleFraction(self) == 0 {
            render(p)
            return
        }
        viewability.tick()
    }
}

/// A tap on a product card, carrying the card's item and product.
final class ProductTap: UITapGestureRecognizer {
    weak var item: PlacementItem?
    let product: PlacementProduct

    init(target: Any?, action: Selector?, item: PlacementItem, product: PlacementProduct) {
        self.item = item
        self.product = product
        super.init(target: target, action: action)
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let d = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: d, size: 0)
    }
}

/// A script-free web view that sizes to its document and hands links out.
final class PlacementWebView: WKWebView, WKNavigationDelegate {
    var onLink: ((URL) -> Void)?
    private var height: CGFloat = 0

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        navigationDelegate = self
        scrollView.isScrollEnabled = false
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: height) }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // An app-side measurement: the document's own script stays disabled.
        evaluateJavaScript("document.body.scrollHeight") { [weak self] value, _ in
            guard let self, let h = value as? NSNumber else { return }
            self.height = CGFloat(truncating: h)
            self.invalidateIntrinsicContentSize()
        }
    }

    /// The loadHTMLString document has been allowed: every later navigation is cancelled.
    private var loadedDocument = false

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(Self.policy(for: action.navigationType, url: action.request.url, isMainFrame: action.targetFrame?.isMainFrame ?? false, loadedDocument: &loadedDocument, onLink: onLink))
    }

    /**
     The navigation rule, testable without a web view: the first main-frame
     load of about:blank (our loadHTMLString) is allowed once; a tap on a link
     counts as a click and opens outside (PlacementView applies the http(s)
     rule); everything else - a meta refresh, a form, a redirect - is cancelled.
     */
    static func policy(for type: WKNavigationType, url: URL?, isMainFrame: Bool, loadedDocument: inout Bool, onLink: ((URL) -> Void)?) -> WKNavigationActionPolicy {
        if !loadedDocument, isMainFrame, type == .other, url?.absoluteString == "about:blank" {
            loadedDocument = true
            return .allow
        }
        if type == .linkActivated, let url {
            onLink?(url)
        }
        return .cancel
    }
}

/**
 A Joryio placement in SwiftUI (docs/PLACEMENTS_PLAN.md, D444):

 ```swift
 JoryioPlacement("home_hero")
 ```

 The same view as `PlacementView` - fetching, caching, viewability, holdout
 exposure and the reports - so a SwiftUI screen and a UIKit screen behave
 identically.
 */
public struct JoryioPlacement: UIViewRepresentable {
    public let placementKey: String
    public var onRender: ((Placement) -> Void)?
    /// Draw an item's recommended products as a row of cards (`PlacementView.showProducts`).
    public var showProducts: Bool
    /// Label of a button on every product card; nil = no button.
    public var productButtonText: String?
    /// Width of one product card, in points.
    public var productCardWidth: CGFloat

    public init(
        _ placementKey: String,
        showProducts: Bool = true,
        productButtonText: String? = nil,
        productCardWidth: CGFloat = CGFloat(Placements.PLACEMENT_PRODUCT_CARD_WIDTH),
        onRender: ((Placement) -> Void)? = nil
    ) {
        self.placementKey = placementKey
        self.showProducts = showProducts
        self.productButtonText = productButtonText
        self.productCardWidth = productCardWidth
        self.onRender = onRender
    }

    public func makeUIView(context: Context) -> PlacementView {
        let view = PlacementView(placementKey: placementKey)
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        apply(to: view)
        return view
    }

    public func updateUIView(_ view: PlacementView, context: Context) {
        view.setPlacementKey(placementKey)
        apply(to: view)
    }

    private func apply(to view: PlacementView) {
        view.onRender = onRender
        view.showProducts = showProducts
        view.productButtonText = productButtonText
        view.productCardWidth = productCardWidth
    }
}
#endif
