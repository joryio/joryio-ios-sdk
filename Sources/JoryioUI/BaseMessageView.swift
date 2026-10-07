import UIKit
#if SWIFT_PACKAGE
// SwiftPM: JoryioUI is its own module. CocoaPods: Joryio/UI is a subspec
// compiled INTO the Joryio module, where this import is a warning that
// fails `pod lib lint` (and so `pod trunk push`).
import Joryio
#endif

// MARK: - Base Message View

class BaseMessageView: UIView {
    let campaign: InAppCampaign
    weak var delegate: InAppMessageViewDelegate?

    init(campaign: InAppCampaign, delegate: InAppMessageViewDelegate?) {
        self.campaign = campaign
        self.delegate = delegate
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The part of the message that takes touches when it does not block
    /// the screen (the card or container). Set by the subclass.
    var interactionArea: UIView?

    /// Whether the message blocks the app behind it (modal and fullscreen do;
    /// banner and slide-up do not). Set by the subclass.
    var blocksBackground = true

    /**
     Touches outside a NON-BLOCKING message belong to the app.

     The presenter pins every message view to the whole window, so a banner
     or slide-up was a full-screen transparent view sitting on top of the app:
     it swallowed every tap anywhere on screen while it was up, and the app
     looked frozen. Returning false here outside the card makes UIKit pass
     the touch through to the views underneath.
     */
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !blocksBackground else { return super.point(inside: point, with: event) }
        guard let area = interactionArea, area.superview != nil else { return false }
        return area.point(inside: convert(point, to: area), with: event)
    }

    func show() {
        alpha = 0
        UIView.animate(withDuration: 0.3) {
            self.alpha = 1
        } completion: { _ in
            self.delegate?.messageViewDidAppear(self.campaign.id)
        }
    }

    /// `dismiss()` already ran: a close from the message's script and a tap
    /// on the backdrop within the animation used to report `dismissed`
    /// twice (scan 5, N4).
    private(set) var isDismissing = false

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        UIView.animate(withDuration: 0.3) {
            self.alpha = 0
        } completion: { _ in
            self.removeFromSuperview()
            self.delegate?.messageViewDidDismiss(self.campaign.id)
        }
    }
}
