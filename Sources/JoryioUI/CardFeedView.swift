#if canImport(UIKit)
import UIKit
import SwiftUI
#if SWIFT_PACKAGE
// SwiftPM: JoryioUI is its own module. CocoaPods: Joryio/UI is a subspec
// compiled INTO the Joryio module, where this import is a warning that
// fails `pod lib lint` (and so `pod trunk push`).
import Joryio
@_spi(JoryioInternal) import Joryio
#endif

/**
 The person's content cards as a plain scrolling list (docs/PLACEMENTS_PLAN.md
 section 11, D444 Phase 3):

 ```swift
 navigationController?.pushViewController(CardFeedViewController(), animated: true)
 ```

 Each card shows its image (if any) on top, the title, the body, its button (if
 any), a "Pinned" marker, an unread dot and a dismiss control. Fonts follow
 Dynamic Type and colors are the system's semantic ones, so the host app's
 appearance (dark mode included) applies; there is no design of its own.

 Reporting is built in: a card at least half on screen for a second is reported
 `viewed` then `read` (the placement viewability rule); a tap on the card or its
 button reports `clicked` and opens its url - http(s) in the system, an app deep
 link through `onDeepLink` (an app-wide `Joryio.shared.setLinkHandler` sees
 every link first), anything else never; the dismiss control reports
 `dismissed`. The next page loads when the list is scrolled near its end.
 */
public final class CardFeedViewController: UIViewController {
    /// Shown when the feed is empty.
    public var emptyText: String = "No messages yet" {
        didSet { if isViewLoaded { render(feed) } }
    }
    /// The marker on a pinned card.
    public var pinnedLabel: String = "Pinned"
    /// The accessible label of the dismiss control.
    public var dismissLabel: String = "Dismiss"
    /// The accessible label of the unread dot.
    public var unreadLabel: String = "Unread"
    /// A card's url is an app deep link (`myapp://...`): route it in your app
    /// (the click is already reported). Without this only an http(s) link is
    /// opened; the view never hands any other scheme to the system.
    public var onDeepLink: ((URL, Card) -> Void)?
    /// Called after each draw with the feed drawn.
    public var onRender: ((CardFeed) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let viewability = ViewabilityTracker()
    private var subscription: JoryioSubscription?
    private var feed: CardFeed = .empty
    private var timer: Timer?
    private var loadingMore = false

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        render(feed)
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        attach()
        startTimer()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopTimer()
        viewability.resetDwell()
        subscription?.cancel()
        subscription = nil
    }

    private func attach() {
        guard subscription == nil else { return }
        guard let sub = Joryio.shared.attachCardFeedListener({ [weak self] in self?.render($0) }) else { return }
        subscription = sub
        Joryio.shared.getCards { [weak self] in self?.render($0) }
    }

    // MARK: Drawing

    private func render(_ next: CardFeed) {
        feed = next
        guard isViewLoaded else { return }
        viewability.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if next.cards.isEmpty {
            let label = UILabel()
            label.text = emptyText
            label.textAlignment = .center
            label.numberOfLines = 0
            label.textColor = .secondaryLabel
            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            let wrap = UIStackView(arrangedSubviews: [label])
            wrap.isLayoutMarginsRelativeArrangement = true
            wrap.layoutMargins = UIEdgeInsets(top: 32, left: 16, bottom: 32, right: 16)
            stack.addArrangedSubview(wrap)
        } else {
            for card in next.cards {
                let row = CardRowView(card: card, owner: self)
                stack.addArrangedSubview(row)
                viewability.add(row) {
                    Joryio.shared.markCardViewed(card)
                    Joryio.shared.markCardRead(card)
                }
            }
        }
        onRender?(next)
    }

    fileprivate func tapped(_ card: Card) {
        Joryio.shared.markCardClicked(card)
        guard let link = card.url?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty, let url = URL(string: link) else { return }
        // The app-wide link handler (`setLinkHandler`) sees it first.
        if PlacementView.isSafeUrl(url) {
            LinkRouter.route(url, source: .card, campaignId: card.campaignId, cardId: card.id) {
                LinkRouter.openExternally(url)
            }
        } else if isAppDeepLink(link) {
            LinkRouter.route(url, source: .card, campaignId: card.campaignId, cardId: card.id) { [weak self] in
                self?.onDeepLink?(url, card)
            }
        }
        // Anything else is refused: never opened, never handed on.
    }

    fileprivate func dismissed(_ card: Card) {
        Joryio.shared.dismissCard(card)
    }

    // MARK: Viewability + paging

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

    private func tick() {
        attach()
        viewability.tick()
        guard let cursor = feed.nextCursor, !loadingMore, !feed.cards.isEmpty else { return }
        let remaining = scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.bounds.height)
        if remaining < 200 {
            loadingMore = true
            Joryio.shared.getCards(cursor: cursor) { [weak self] _ in self?.loadingMore = false }
        }
    }
}

/// One card of the feed.
private final class CardRowView: UIStackView {
    private let card: Card
    private weak var owner: CardFeedViewController?

    init(card: Card, owner: CardFeedViewController) {
        self.card = card
        self.owner = owner
        super.init(frame: .zero)
        axis = .vertical
        spacing = 6
        isLayoutMarginsRelativeArrangement = true
        layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        accessibilityIdentifier = "joryio-card:\(card.id)"

        if let image = card.imageUrl, !image.isEmpty {
            let iv = UIImageView()
            iv.contentMode = .scaleAspectFit
            iv.clipsToBounds = true
            iv.isAccessibilityElement = false
            addArrangedSubview(iv)
            ImageLoader.load(image, into: iv)
        }

        let header = UIStackView()
        header.axis = .horizontal
        header.spacing = 6
        header.alignment = .center
        if !card.read {
            let dot = UILabel()
            dot.text = "\u{25CF}"
            dot.font = UIFont.preferredFont(forTextStyle: .caption2)
            dot.textColor = owner.view.tintColor
            dot.accessibilityLabel = owner.unreadLabel
            dot.setContentHuggingPriority(.required, for: .horizontal)
            header.addArrangedSubview(dot)
        }
        let title = UILabel()
        title.text = card.title
        title.numberOfLines = 0
        title.font = UIFont.preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .label
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(title)
        if card.pinned {
            let pinned = UILabel()
            pinned.text = owner.pinnedLabel
            pinned.font = UIFont.preferredFont(forTextStyle: .caption1)
            pinned.adjustsFontForContentSizeCategory = true
            pinned.textColor = .secondaryLabel
            pinned.setContentHuggingPriority(.required, for: .horizontal)
            header.addArrangedSubview(pinned)
        }
        let close = UIButton(type: .close)
        close.accessibilityLabel = owner.dismissLabel
        close.setContentHuggingPriority(.required, for: .horizontal)
        close.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.owner?.dismissed(self.card)
        }, for: .touchUpInside)
        header.addArrangedSubview(close)
        addArrangedSubview(header)

        if let body = card.body, !body.isEmpty {
            let label = UILabel()
            label.text = body
            label.numberOfLines = 0
            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .label
            addArrangedSubview(label)
        }
        if let text = card.buttonText, !text.isEmpty, let url = card.url, !url.isEmpty {
            let button = UIButton(type: .system)
            button.setTitle(text, for: .normal)
            button.contentHorizontalAlignment = .leading
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.owner?.tapped(self.card)
            }, for: .touchUpInside)
            addArrangedSubview(button)
        }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(rowTapped)))
        isUserInteractionEnabled = true
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func rowTapped() {
        owner?.tapped(card)
    }
}

/**
 The person's content cards in SwiftUI (docs/PLACEMENTS_PLAN.md section 11,
 D444 Phase 3):

 ```swift
 JoryioCardFeed()
 ```

 The same view as `CardFeedViewController` - the feed, paging, the unread dot,
 the dismiss control, the viewed / read / clicked / dismissed reports and the
 link rule - so a SwiftUI screen and a UIKit screen behave identically.
 */
public struct JoryioCardFeed: UIViewControllerRepresentable {
    /// Replaces "No messages yet".
    public var emptyText: String?
    /// Replaces "Pinned" (the marker on a pinned card).
    public var pinnedLabel: String?
    /// Replaces "Dismiss" (the accessible label of the dismiss control).
    public var dismissLabel: String?
    /// Replaces "Unread" (the accessible label of the unread dot).
    public var unreadLabel: String?
    public var onDeepLink: ((URL, Card) -> Void)?
    public var onRender: ((CardFeed) -> Void)?

    public init(
        emptyText: String? = nil,
        pinnedLabel: String? = nil,
        dismissLabel: String? = nil,
        unreadLabel: String? = nil,
        onDeepLink: ((URL, Card) -> Void)? = nil,
        onRender: ((CardFeed) -> Void)? = nil
    ) {
        self.emptyText = emptyText
        self.pinnedLabel = pinnedLabel
        self.dismissLabel = dismissLabel
        self.unreadLabel = unreadLabel
        self.onDeepLink = onDeepLink
        self.onRender = onRender
    }

    public func makeUIViewController(context: Context) -> CardFeedViewController {
        let vc = CardFeedViewController()
        apply(to: vc)
        return vc
    }

    public func updateUIViewController(_ vc: CardFeedViewController, context: Context) {
        apply(to: vc)
    }

    func apply(to vc: CardFeedViewController) {
        if let emptyText, vc.emptyText != emptyText { vc.emptyText = emptyText }
        if let pinnedLabel { vc.pinnedLabel = pinnedLabel }
        if let dismissLabel { vc.dismissLabel = dismissLabel }
        if let unreadLabel { vc.unreadLabel = unreadLabel }
        vc.onDeepLink = onDeepLink
        vc.onRender = onRender
    }
}
#endif
