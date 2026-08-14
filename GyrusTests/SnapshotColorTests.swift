import XCTest
@testable import Gyrus

/// Covers the color parsing behind the Design tab's palette.
///
/// The hsl() and oklch() branches exist because Chromium only serializes
/// computed styles back to rgb() for legacy color spaces; anything authored in a
/// modern space survives into getComputedStyle unchanged and used to be dropped
/// without a trace. The conversions are hand-written matrix math, which is
/// exactly the kind of code that should not be trusted without fixed points.
final class SnapshotColorTests: XCTestCase {

    private func hex(_ value: String) -> String? {
        SnapshotColor.normalize(value)?.hex
    }

    // MARK: - Hex

    func testSixDigitHexIsLowercased() {
        XCTAssertEqual(hex("#C9A94D"), "#c9a94d")
    }

    func testThreeDigitHexIsExpanded() {
        XCTAssertEqual(hex("#fff"), "#ffffff")
        XCTAssertEqual(hex("#0a0"), "#00aa00")
    }

    // MARK: - rgb()

    func testRGBAndRGBAAreParsed() {
        XCTAssertEqual(hex("rgb(20, 26, 26)"), "#141a1a")
        XCTAssertEqual(hex("rgba(255, 255, 255, 0.5)"), "#ffffff")
    }

    func testFullyTransparentIsDiscarded() {
        XCTAssertNil(hex("rgba(0, 0, 0, 0)"))
        XCTAssertNil(hex("transparent"))
    }

    func testKeywordsWithoutAColorAreDiscarded() {
        XCTAssertNil(hex("currentcolor"))
        XCTAssertNil(hex("none"))
        XCTAssertNil(hex(""))
    }

    // MARK: - hsl()

    func testHSLPrimaries() {
        XCTAssertEqual(hex("hsl(0, 100%, 50%)"), "#ff0000")
        XCTAssertEqual(hex("hsl(120, 100%, 50%)"), "#00ff00")
        XCTAssertEqual(hex("hsl(240, 100%, 50%)"), "#0000ff")
    }

    func testHSLSpaceSeparatedSyntax() {
        XCTAssertEqual(hex("hsl(0 100% 50%)"), "#ff0000")
    }

    func testHSLGreyscaleIgnoresHue() {
        XCTAssertEqual(hex("hsl(210, 0%, 100%)"), "#ffffff")
        XCTAssertEqual(hex("hsl(210, 0%, 0%)"), "#000000")
    }

    func testHSLWithZeroAlphaIsDiscarded() {
        XCTAssertNil(hex("hsla(0, 100%, 50%, 0)"))
    }

    // MARK: - oklch()

    func testOKLCHBlackAndWhite() {
        XCTAssertEqual(hex("oklch(0 0 0)"), "#000000")
        XCTAssertEqual(hex("oklch(1 0 0)"), "#ffffff")
    }

    /// sRGB red is oklch(0.6279 0.2577 29.23). Allow a channel of slack: the
    /// conversion runs through OKLab and a gamma curve, so exact equality would
    /// be testing floating point rather than correctness.
    func testOKLCHRedLandsOnRed() {
        guard let result = SnapshotColor.normalize("oklch(0.6279 0.2577 29.23)") else {
            return XCTFail("oklch red did not parse")
        }
        assertChannels(result.hex, red: 255, green: 0, blue: 0, tolerance: 3)
    }

    func testOKLCHAcceptsPercentageLightness() {
        XCTAssertEqual(hex("oklch(100% 0 0)"), "#ffffff")
    }

    func testOKLCHWithAlphaSyntax() {
        guard let result = SnapshotColor.normalize("oklch(0.6279 0.2577 29.23 / 0.8)") else {
            return XCTFail("oklch with alpha did not parse")
        }
        assertChannels(result.hex, red: 255, green: 0, blue: 0, tolerance: 3)
        XCTAssertNil(hex("oklch(0.6279 0.2577 29.23 / 0)"))
    }

    /// Out-of-gamut chroma must still yield a usable swatch rather than nil.
    func testOKLCHOutOfGamutIsClamped() {
        XCTAssertNotNil(hex("oklch(0.5 0.9 200)"))
    }

    // MARK: - Units that used to be silently dropped

    /// Every angle unit is legal wherever CSS expects a hue. Parsing used to
    /// discard the component it could not read, which shifted every later
    /// argument into the wrong slot instead of failing.
    func testHueAcceptsAngleUnits() {
        XCTAssertEqual(hex("hsl(120deg 100% 50%)"), "#00ff00")
        XCTAssertEqual(hex("hsl(120deg, 100%, 50%)"), "#00ff00")
        XCTAssertEqual(hex("hsl(0.3333turn, 100%, 50%)"), "#00ff00")
        XCTAssertEqual(hex("hsl(133.33grad, 100%, 50%)"), "#00ff00")
    }

    func testAlphaIsNotMistakenForAChannelWhenHueCarriesAUnit() {
        // Regression: this used to parse as hue 100, saturation 0.5,
        // lightness 0.005 and render near-black.
        XCTAssertEqual(hex("hsla(120deg, 100%, 50%, 0.5)"), "#00ff00")
    }

    func testNegativeAndOversizedHuesWrap() {
        XCTAssertEqual(hex("hsl(-240, 100%, 50%)"), "#00ff00")
        XCTAssertEqual(hex("hsl(480, 100%, 50%)"), "#00ff00")
    }

    /// rgb() channels may be percentages of full scale. Treating "100%" as the
    /// raw number 100 produced #640000 for pure red — a wrong swatch, which is
    /// worse than the nil this used to return.
    func testRGBPercentageChannels() {
        XCTAssertEqual(hex("rgb(100%, 0%, 0%)"), "#ff0000")
        XCTAssertEqual(hex("rgb(100% 100% 100%)"), "#ffffff")
    }

    /// The unit decides, not the magnitude: a percentage lightness at or below
    /// 1% is a very dark color, and guessing from the number alone made it white.
    func testOKLCHSmallPercentageLightnessStaysDark() {
        guard let dark = SnapshotColor.normalize("oklch(1% 0 0)") else {
            return XCTFail("oklch(1% 0 0) did not parse")
        }
        XCTAssertNotEqual(dark.hex, "#ffffff")
        assertChannels(dark.hex, red: 0, green: 0, blue: 0, tolerance: 12)
    }

    func testOKLCHHueAcceptsDegrees() {
        XCTAssertEqual(
            SnapshotColor.normalize("oklch(0.7 0.1 200deg)")?.hex,
            SnapshotColor.normalize("oklch(0.7 0.1 200)")?.hex
        )
    }

    func testUnparseableComponentsFailRatherThanShift() {
        XCTAssertNil(hex("rgb(calc(1 + 1), 0, 0)"))
        XCTAssertNil(hex("hsl(var(--h), 100%, 50%)"))
    }

    // MARK: - Deduplication

    func testUniqueKeepsFirstOccurrenceAndDropsRepeats() {
        let colors = SnapshotColor.unique(from: ["#ffffff", "rgb(255, 255, 255)", "#000000"])
        XCTAssertEqual(colors.map(\.hex), ["#ffffff", "#000000"])
    }

    // MARK: - Helpers

    private func assertChannels(
        _ hexValue: String,
        red: Int,
        green: Int,
        blue: Int,
        tolerance: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let digits = hexValue.dropFirst()
        guard digits.count == 6, let value = Int(digits, radix: 16) else {
            return XCTFail("Malformed hex: \(hexValue)", file: file, line: line)
        }
        let actual = ((value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff)
        XCTAssertLessThanOrEqual(abs(actual.0 - red), tolerance, "red channel of \(hexValue)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(actual.1 - green), tolerance, "green channel of \(hexValue)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(actual.2 - blue), tolerance, "blue channel of \(hexValue)", file: file, line: line)
    }
}
