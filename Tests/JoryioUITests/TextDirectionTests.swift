import XCTest
@testable import JoryioUI

/**
 The rule that decides which way a message reads.

 Written because the direction work shipped on "it compiles" - and a rule that
 returns the wrong boolean produces a message that renders perfectly, just
 mirrored, which no build can notice.

 It must agree with the other three renderers: Android uses the same ranges and
 the web gets it from `dir="auto"`. All four implement FIRST STRONG CHARACTER,
 per the Unicode BiDi algorithm, so one message reads the same way everywhere.
 The Android cases in TextDirectionTest.kt are deliberately identical.
 */
final class TextDirectionTests: XCTestCase {

    func testHebrewAndArabicReadRightToLeft() {
        XCTAssertTrue("שלום, יש מקום פנוי".joryioIsRightToLeft)
        XCTAssertTrue("مرحبًا، هناك مكان شاغر".joryioIsRightToLeft)
    }

    func testLatinGreekAndCyrillicReadLeftToRight() {
        XCTAssertFalse("A place opened up".joryioIsRightToLeft)
        XCTAssertFalse("Άνοιξε μια θέση".joryioIsRightToLeft)
        XCTAssertFalse("Освободилось место".joryioIsRightToLeft)
    }

    func testLeadingNeutralsAreSkipped() {
        // A Hebrew message opening with punctuation, a digit or an emoji is
        // still Hebrew. Testing the first character alone gets all of these
        // backwards.
        XCTAssertTrue("!שלום".joryioIsRightToLeft)
        XCTAssertTrue("20% הנחה לחברים".joryioIsRightToLeft)
        XCTAssertTrue("🎉 שלום".joryioIsRightToLeft)
        XCTAssertTrue("   \n שלום".joryioIsRightToLeft)
    }

    func testTheFirstStrongCharacterDecidesNotTheMajority() {
        // "Hello שלום" is a left-to-right paragraph containing Hebrew;
        // "שלום Hello" is a right-to-left one containing English. Counting
        // characters instead would flip both.
        XCTAssertFalse("Hello שלום שלום שלום".joryioIsRightToLeft)
        XCTAssertTrue("שלום Hello Hello Hello".joryioIsRightToLeft)
    }

    func testNoStrongCharacterDefaultsToLeftToRight() {
        XCTAssertFalse("".joryioIsRightToLeft)
        XCTAssertFalse("123 !? 🎉".joryioIsRightToLeft)
    }
}
