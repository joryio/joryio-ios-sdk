import XCTest
@testable import JoryioUI

/**
 Guards Dynamic Type against the two ways a message font can be wrong.

 Both are invisible at the default text size and only hurt readers who have
 turned text size up - which is exactly the group Dynamic Type exists for, and
 the group whose screenshots nobody takes.

 1. **Double scaling.** `UIFontMetrics.scaledFont(for:)` expects a base sized
    for the DEFAULT setting. `UIFont.preferredFont(forTextStyle:)` returns one
    that is already scaled. Combining them - the obvious way to write it, and
    how this renderer was written first - scales twice.

 2. **Deriving Apple's sizes.** They are a hand-tuned table, not a multiple:
    `.body` runs 17 -> 47 at AX5, where proportional scaling of 17 gives 43. A
    message that derives its own size sits four points off every other label in
    the app.
 */
final class FontScalingTests: XCTestCase {
    private let ax = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraLarge)
    private let standard = UITraitCollection(preferredContentSizeCategory: .large)

    func testNoAuthorSizeMatchesThePlatformExactly() {
        for style in [UIFont.TextStyle.body, .headline, .callout] {
            for traits in [standard, ax] {
                let ours = JoryioFontScaling.font(
                    size: nil, textStyle: style, weight: .regular, family: nil, compatibleWith: traits
                )
                let platform = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)

                XCTAssertEqual(
                    ours.pointSize, platform.pointSize, accuracy: 0.01,
                    "\(style) at \(traits.preferredContentSizeCategory.rawValue)"
                )
            }
        }
    }

    func testTheTableIsNotAMultiple() {
        // The control for the test above: if Apple's sizes WERE proportional,
        // deriving them would be harmless and that test would pass either way.
        let base = UIFont.preferredFont(forTextStyle: .body, compatibleWith: standard).pointSize
        let derived = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .systemFont(ofSize: base), compatibleWith: ax).pointSize
        let actual = UIFont.preferredFont(forTextStyle: .body, compatibleWith: ax).pointSize

        XCTAssertNotEqual(derived, actual, accuracy: 0.01)
    }

    func testAnAuthorSizeStillGrowsForTheReader() {
        // A campaign sets a size at the default setting; it must not pin the
        // text and override someone's accessibility choice.
        let atDefault = JoryioFontScaling.font(
            size: 14, textStyle: .body, weight: .regular, family: nil, compatibleWith: standard
        )
        let atAccessibility = JoryioFontScaling.font(
            size: 14, textStyle: .body, weight: .regular, family: nil, compatibleWith: ax
        )

        XCTAssertEqual(atDefault.pointSize, 14, accuracy: 0.01)
        XCTAssertGreaterThan(atAccessibility.pointSize, atDefault.pointSize)
    }

    func testAnAuthorSizeIsScaledOnceNotTwice() {
        // Double scaling is detectable as "bigger than scaling the same number
        // once". Written as its own assertion so a regression names itself.
        let once = JoryioFontScaling.font(
            size: 17, textStyle: .body, weight: .regular, family: nil, compatibleWith: ax
        ).pointSize
        let alreadyScaled = UIFont.preferredFont(forTextStyle: .body, compatibleWith: ax).pointSize
        let twice = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .systemFont(ofSize: alreadyScaled), compatibleWith: ax).pointSize

        XCTAssertLessThan(once, twice)
    }

    func testAnUnavailableFamilyKeepsTheAppsTypeface() {
        // Substituting an arbitrary font looks worse than ignoring the override.
        let font = JoryioFontScaling.font(
            size: 14, textStyle: .body, weight: .regular,
            family: "NoSuchFontShipsWithThisApp", compatibleWith: standard
        )

        XCTAssertEqual(font.familyName, UIFont.systemFont(ofSize: 14).familyName)
    }
}
