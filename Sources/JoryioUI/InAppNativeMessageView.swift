import UIKit
#if SWIFT_PACKAGE
// SwiftPM: JoryioUI is its own module. CocoaPods: Joryio/UI is a subspec
// compiled INTO the Joryio module, where this import is a warning that
// fails `pod lib lint` (and so `pod trunk push`).
import Joryio
#endif

/**
 Renders a native in-app message with UIKit views.

 No web view, and that is the point rather than an optimisation:

 - **Security.** There is no interpreter, so a contact attribute containing
   markup is just text. An app whose policy forbids rendering authored HTML
   in a web view in-process can use in-app messaging at all.
 - **Look.** Dynamic Type, dark mode and VoiceOver come free from UIKit, and
   colours resolve from system semantic colours so the message matches the
   host app instead of shipping its own palette.
 - **Weight.** No WKWebView instantiation per message.

 Every string here is TEXT. The server does NOT HTML-escape native fields
 (escaping would display `A &amp; B` to the user), so putting any of them into
 a web view would reintroduce exactly the injection this path avoids.
 */
final class InAppNativeMessageView: BaseMessageView {
    private let content: NativeContent
    /// Author overrides; nil throughout means "inherit the app".
    private var style: NativeContent.NativeStyle? { content.style }
    private let backdrop = UIView()
    private let card = UIView()
    private let stack = UIStackView()
    private let close = UIButton(type: .system)

    /// Returns nil when there is nothing to show - an empty card the user has
    /// to dismiss is worse than no message, and it would still count an
    /// impression.
    static func make(
        campaign: InAppCampaign,
        delegate: InAppMessageViewDelegate?
    ) -> InAppNativeMessageView? {
        guard case let .native(content)? = campaign.content, !content.body.isEmpty else {
            return nil
        }
        return InAppNativeMessageView(campaign: campaign, delegate: delegate, content: content)
    }

    private init(
        campaign: InAppCampaign,
        delegate: InAppMessageViewDelegate?,
        content: NativeContent
    ) {
        self.content = content
        super.init(campaign: campaign, delegate: delegate)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        // Only the screen-blocking types dim. A banner that dimmed the screen
        // would read as blocking when its whole point is that the app stays
        // usable behind it.
        let dims = campaign.type == .modal || campaign.type == .fullscreen
        backdrop.backgroundColor = dims ? UIColor.black.withAlphaComponent(0.4) : .clear
        // A non-dimming message must not catch taps outside its card.
        backdrop.isUserInteractionEnabled = dims
        blocksBackground = dims
        interactionArea = card
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        if dims && content.backdropDismissible {
            backdrop.addGestureRecognizer(
                UITapGestureRecognizer(target: self, action: #selector(backdropTapped))
            )
        }

        // System semantic colours, so the card follows light/dark mode without
        // the SDK carrying a palette. An author override replaces the semantic
        // colour only where one was given - unset means inherit, which is the
        // reason to pick native over HTML at all.
        card.backgroundColor = UIColor(joryioHex: style?.backgroundColor) ?? .systemBackground
        if campaign.type == .fullscreen {
            // Fullscreen ignores a radius on purpose: rounded corners on an
            // edge-to-edge sheet leave the app showing through at the corners.
            card.layer.cornerRadius = 0
        } else {
            card.layer.cornerRadius = style?.cornerRadius.map { CGFloat($0) } ?? 14
        }
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        // Direction comes from the MESSAGE, not the app's language: one
        // workspace sends Hebrew and English from the same campaign list, so
        // an app-locale decision gets one of them wrong. Setting it on the card
        // also flips the button row, the padding and the image - a UIStackView
        // reverses its arrangement under a right-to-left semantic attribute.
        if content.body.joryioIsRightToLeft {
            card.semanticContentAttribute = .forceRightToLeft
            stack.semanticContentAttribute = .forceRightToLeft
        }

        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        if let urlString = content.imageUrl {
            let image = UIImageView()
            image.contentMode = .scaleAspectFill
            image.clipsToBounds = true
            // Decorative: the headline and body carry the meaning, so an
            // unlabelled image would just make VoiceOver announce "image".
            image.isAccessibilityElement = false
            image.translatesAutoresizingMaskIntoConstraints = false
            image.heightAnchor.constraint(equalToConstant: 140).isActive = true
            stack.addArrangedSubview(image)
            ImageLoader.load(urlString, into: image)
        }

        if let title = content.title {
            let label = UILabel()
            label.text = title
            // preferredFont + adjustsFontForContentSizeCategory is what makes
            // this honour the user's text-size setting. A hard-coded point size
            // would ignore Dynamic Type entirely.
            label.font = titleFont
            label.adjustsFontForContentSizeCategory = true
            label.textColor = UIColor(joryioHex: style?.textColor) ?? .label
            label.numberOfLines = 0
            label.textAlignment = resolvedAlignment
            label.accessibilityTraits.insert(.header)

            if content.closeButton {
                // The ✕ floats over the card's trailing corner, so a long
                // headline would run under it. A stack arranges its subviews
                // edge to edge, so the inset has to come from a container -
                // constraining the label against the button instead would
                // fight the fill alignment.
                let row = UIView()
                row.translatesAutoresizingMaskIntoConstraints = false
                label.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview(label)
                NSLayoutConstraint.activate([
                    label.topAnchor.constraint(equalTo: row.topAnchor),
                    label.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                    label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                    // Trailing-relative, so the gap lands on the LEFT for a
                    // right-to-left message - the same side as the button.
                    label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -32),
                ])
                stack.addArrangedSubview(row)
            } else {
                stack.addArrangedSubview(label)
            }
        }

        let bodyLabel = UILabel()
        bodyLabel.text = content.body
        bodyLabel.font = bodyFont
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.textAlignment = resolvedAlignment
        // Softened rather than the raw override: one flat colour for headline
        // and body throws away the hierarchy label/secondaryLabel gives free.
        bodyLabel.textColor = UIColor(joryioHex: style?.textColor)?.withAlphaComponent(0.78)
            ?? .secondaryLabel
        bodyLabel.numberOfLines = 0
        stack.addArrangedSubview(bodyLabel)

        if !content.buttons.isEmpty {
            // Side by side for two, stacked beyond that - three across truncate
            // their labels on a narrow phone.
            let row = UIStackView()
            row.axis = content.buttons.count <= 2 ? .horizontal : .vertical
            row.spacing = 8
            row.distribution = .fillEqually

            for (index, button) in content.buttons.enumerated() {
                // The author's order is preserved and the FIRST is primary -
                // the renderer does not decide which action leads.
                row.addArrangedSubview(makeButton(button, primary: index == 0))
            }
            stack.addArrangedSubview(row)
        }

        // An ✕ in the card's TRAILING corner, not a "Close" row under the
        // buttons. Three reasons it changed:
        //   - it is where people look to dismiss a card, on every platform;
        //   - the old row hardcoded the English word "Close", which is simply
        //     wrong in a Hebrew or Arabic message - a glyph needs no
        //     translation, only an accessibility label;
        //   - the web SDK already drew an ✕ for HTML messages while drawing
        //     "Close" for native ones, so one product had two dismiss designs.
        // A dismissible message must always have a visible way out; relying on
        // the backdrop alone traps fullscreen users, which have none.
        if content.closeButton {
            close.setImage(
                UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)),
                for: .normal
            )
            close.tintColor =
                UIColor(joryioHex: style?.textColor)?.withAlphaComponent(0.55) ?? .secondaryLabel
            // Icon-only, so VoiceOver would otherwise announce "button".
            close.accessibilityLabel = "Close"
            close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
            close.translatesAutoresizingMaskIntoConstraints = false
            // On the CARD, not in the stack: it floats over the corner rather
            // than taking a row, so the headline starts at the top as before.
            card.addSubview(close)
        }

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
        ])

        if content.closeButton {
            NSLayoutConstraint.activate([
                close.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
                // trailingAnchor, not right: the card carries a right-to-left
                // semanticContentAttribute for a Hebrew or Arabic message, so
                // this resolves to the LEFT corner there, which is where that
                // reader looks for it.
                close.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
                // 44x44 is Apple's minimum tap target; the glyph inside is 13pt.
                close.widthAnchor.constraint(equalToConstant: 44),
                close.heightAnchor.constraint(equalToConstant: 44),
            ])
        }

        applyPlacement()
    }

    /// Placement per type - shared semantics with the HTML renderer, because
    /// placement is a property of the message TYPE, not of its content.
    private func applyPlacement() {
        let guide = safeAreaLayoutGuide

        switch campaign.type {
        case .fullscreen:
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: topAnchor),
                card.bottomAnchor.constraint(equalTo: bottomAnchor),
                card.leadingAnchor.constraint(equalTo: leadingAnchor),
                card.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        case .banner:
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
                card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            ])
        case .slideup:
            NSLayoutConstraint.activate([
                card.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
                card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            ])
        case .modal, .custom:
            NSLayoutConstraint.activate([
                card.centerYAnchor.constraint(equalTo: centerYAnchor),
                card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            ])
        }
        // Height is intrinsic: the stack's content decides it, so a long body
        // grows the card instead of being clipped at a guessed height.
    }

    private func makeButton(_ button: NativeContent.Button, primary: Bool) -> UIButton {
        let view = UIButton(type: .system)
        view.setTitle(button.text, for: .normal)
        view.titleLabel?.font = buttonFont
        view.titleLabel?.adjustsFontForContentSizeCategory = true
        view.layer.cornerRadius = 8
        view.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        if primary {
            // The view's INHERITED tint, not UIColor.tintColor (iOS 15+). This
            // also picks up the host app's global tint, so the primary button
            // matches the app rather than the SDK.
            let fill = UIColor(joryioHex: style?.primaryButtonColor) ?? view.tintColor ?? .systemBlue
            view.backgroundColor = fill
            // No explicit label colour: derive one from the FILL rather than
            // defaulting to white. An author who picks a pale brand colour and
            // stops there would otherwise get white-on-pale - an invisible
            // label that still looks right in the editor preview.
            view.setTitleColor(
                UIColor(joryioHex: style?.primaryButtonTextColor) ?? fill.joryioReadableForeground,
                for: .normal
            )
        } else {
            view.backgroundColor = .clear
            view.setTitleColor(UIColor(joryioHex: style?.textColor) ?? .label, for: .normal)
            view.layer.borderWidth = 1
            view.layer.borderColor = UIColor.separator.cgColor
        }

        view.accessibilityIdentifier = button.id
        view.addAction(
            UIAction { [weak self] _ in self?.handle(button) },
            for: .touchUpInside
        )
        return view
    }

    // MARK: - Typography

    /// Alignment for the text labels.
    ///
    /// `.natural` is not "left": UIKit resolves it through the Unicode BiDi
    /// algorithm, so a Hebrew body aligns right and an English one left, per
    /// message. That is why it is the default rather than `.left`.
    private var resolvedAlignment: NSTextAlignment {
        switch style?.textAlign {
        case "center": return .center
        // start/end are direction-relative, and UIKit spells them natural and
        // the opposite of natural.
        case "start": return .natural
        case "end": return content.body.joryioIsRightToLeft ? .left : .right
        default: return .natural
        }
    }

    private var titleFont: UIFont {
        let weight: UIFont.Weight
        switch style?.titleWeight {
        case "regular": weight = .regular
        case "medium": weight = .medium
        case "semibold": weight = .semibold
        case "bold": weight = .bold
        default: weight = .semibold // matches .headline
        }
        // The headline scales from the body size so one control keeps the
        // hierarchy, matching the web renderer's 1.3 factor.
        let size = (style?.fontSize).map { $0 * 1.3 }
        return scaledFont(size: size, style: .headline, weight: weight)
    }

    private var bodyFont: UIFont {
        scaledFont(size: style?.fontSize, style: .body, weight: .regular)
    }

    private var buttonFont: UIFont {
        scaledFont(size: style?.fontSize, style: .callout, weight: .regular)
    }

    /**
     Builds a font that honours the author AND the reader.

     `UIFontMetrics` is the load-bearing part: a plain `systemFont(ofSize:)`
     would pin the message at a fixed size and quietly break Dynamic Type, so a
     campaign that set a size would make the app unreadable for someone who has
     turned text size up. Scaling the author's size keeps both.

     A named family is applied only when the app HAS it - `UIFont(name:)`
     returns nil otherwise, and falling back to the system font is a non-event
     next to rendering in something arbitrary.
     */
    private func scaledFont(size: Double?, style textStyle: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        JoryioFontScaling.font(
            size: size,
            textStyle: textStyle,
            weight: weight,
            family: style_fontFamily
        )
    }

    /// Trimmed family name, or nil when the author set none.
    private var style_fontFamily: String? {
        guard let family = style?.fontFamily?.trimmingCharacters(in: .whitespacesAndNewlines),
              !family.isEmpty else { return nil }
        return family
    }

    // MARK: - Actions

    private func handle(_ button: NativeContent.Button) {
        if button.action == .requestPushPermission {
            // The base SDK owns the permission flow; this view only reports the
            // tap. Fire and forget - the message dismisses either way, and a
            // refused prompt is a normal outcome, not an error.
            Task { _ = await Joryio.shared.requestPushPermission() }
        }
        delegate?.messageViewClicked(
            campaign.id,
            action: button.id.isEmpty ? "button" : button.id,
            url: button.action == .dismiss ? nil : button.url
        )
        // EVERY button dismisses. A message the user has acted on that stays on
        // screen reads as broken - and an unknown action decodes to .dismiss
        // precisely so a future action type cannot trap someone in a modal.
        dismiss()
    }

    @objc private func backdropTapped() {
        dismiss()
    }

    @objc private func closeTapped() {
        dismiss()
    }
}


// MARK: - Author colour parsing

extension UIColor {
    /**
     Parses an author-supplied colour string, returning nil for anything
     unusable so the caller falls back to the app's own theme.

     The value comes from a text box in the campaign editor, so it has to
     tolerate `#RGB`, `#RRGGBB`, `#RRGGBBAA` and the same without the hash. A
     typo must produce nil, never a crash and never a wrong-but-plausible
     colour: a message that renders in the app's palette is a non-event, a
     message that takes the app down is not.
     */
    convenience init?(joryioHex: String?) {
        guard var hex = joryioHex?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }

        // #RGB shorthand: each digit doubles.
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }

        let hasAlpha = hex.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    /// Black or white, whichever stays legible on the receiver.
    /// Rec. 709 luma - the weighting the WCAG contrast formula uses.
    var joryioReadableForeground: UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return .white }
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luma > 0.59 ? UIColor(red: 0.04, green: 0.07, blue: 0.25, alpha: 1) : .white
    }
}


// MARK: - Text direction

extension String {
    /**
     True when this text reads right to left.

     Decided by the FIRST STRONG character, which is what the Unicode BiDi
     algorithm does and what `dir="auto"` does on the web - so all three
     renderers agree on the same message. Leading punctuation, digits and emoji
     are neutral and skipped; a Hebrew message that opens with "!" is still
     Hebrew.
     */
    var joryioIsRightToLeft: Bool {
        for scalar in unicodeScalars {
            switch scalar.value {
            // Hebrew, Arabic, Syriac, Thaana, N'Ko, Samaritan + their
            // presentation forms.
            case 0x0590...0x05FF, 0x0600...0x07BF, 0x0800...0x085F,
                 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
                return true
            // Latin, Greek, Cyrillic and the rest of the strong LTR range.
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x058F,
                 0x0900...0x1FFF, 0x2C00...0xD7FF:
                return false
            default:
                continue // neutral: punctuation, digits, spaces, emoji
            }
        }
        return false
    }
}


// MARK: - Font scaling

/**
 Builds message fonts that respect BOTH the campaign and the reader.

 Two rules, and the difference between them matters:

 - **No author size** - use the platform's own font for the text style. Apple's
   sizes are a hand-tuned TABLE, not a multiple: `.body` goes 17 -> 47 at the
   largest accessibility setting, where proportional scaling of 17 gives 43. So
   deriving it ourselves would put the message four points off every other
   label in the app, only for readers with large text turned on.

 - **An author size** - scale it through `UIFontMetrics`, exactly once. An
   author size is a size at the DEFAULT setting, not a fixed size: a campaign
   must not be able to pin the text and override someone's accessibility choice.
   Scaling a size that is ALREADY scaled (which is what
   `UIFont.preferredFont(forTextStyle:).pointSize` returns) compounds instead -
   invisible at the default setting, badly wrong at accessibility sizes.

 A named family is applied only when the app HAS it: `UIFont(name:)` returns nil
 otherwise, and keeping the app's own typeface beats substituting an arbitrary
 one.
 */
enum JoryioFontScaling {
    static func font(
        size: Double?,
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight,
        family: String?,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        guard let size else {
            let preferred = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits)
            if let family, let named = UIFont(name: family, size: preferred.pointSize) {
                return named
            }
            return .systemFont(ofSize: preferred.pointSize, weight: weight)
        }

        let base: UIFont
        if let family, let named = UIFont(name: family, size: CGFloat(size)) {
            base = named
        } else {
            base = .systemFont(ofSize: CGFloat(size), weight: weight)
        }
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: base, compatibleWith: traits)
    }
}
