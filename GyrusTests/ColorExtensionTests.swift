import XCTest
import SwiftUI
@testable import Gyrus

final class ColorExtensionTests: XCTestCase {

    // MARK: - init(hex:)

    func testHexWithHash() {
        XCTAssertNotNil(Color(hex: "#FF0000"))
    }

    func testHexWithoutHash() {
        XCTAssertNotNil(Color(hex: "FF0000"))
    }

    func testHexCaseInsensitive() {
        XCTAssertNotNil(Color(hex: "ff0000"))
        XCTAssertNotNil(Color(hex: "#ff0000"))
    }

    func testHexTooShort() {
        XCTAssertNil(Color(hex: "#FFF"))
        XCTAssertNil(Color(hex: "FFF"))
    }

    func testHexTooLong() {
        XCTAssertNil(Color(hex: "#FFFFFFF"))
    }

    func testHexInvalidChars() {
        XCTAssertNil(Color(hex: "#GGGGGG"))
        XCTAssertNil(Color(hex: "ZZZZZZ"))
    }

    func testHexEmpty() {
        XCTAssertNil(Color(hex: ""))
        XCTAssertNil(Color(hex: "#"))
    }

    // MARK: - toHex() round-trips

    func testRoundTrip() {
        XCTAssertEqual(Color(hex: "#A1B2C3")?.toHex(), "#A1B2C3")
    }

    func testBlack() {
        XCTAssertEqual(Color(hex: "#000000")?.toHex(), "#000000")
    }

    func testWhite() {
        XCTAssertEqual(Color(hex: "#FFFFFF")?.toHex(), "#FFFFFF")
    }

    func testRed() {
        XCTAssertEqual(Color(hex: "#FF0000")?.toHex(), "#FF0000")
    }

    func testLowercaseRoundTrips() {
        XCTAssertEqual(Color(hex: "1a2b3c")?.toHex(), "#1A2B3C")
    }
}
