//
//  NvmmTests
//  GuifontTests.swift
//
//  Coverage for `parseGuifont`: single and multiple entries, the `:h<size>`
//  suffix, the default size fallback, backslash-escaped commas, and space
//  handling around separators. Pure value logic, so it is exempt from the
//  RenderTests teardown crash.
//

import CoreGraphics
import XCTest
@testable import Nvmm

final class GuifontTests: XCTestCase {

    func testFontPanelSelectionProducesConcreteSpec() {
        XCTAssertEqual(
            guifontSpec(fontName: "Menlo-Regular", pointSize: 13),
            "Menlo-Regular:h13")
        XCTAssertEqual(
            guifontSpec(fontName: "Menlo-Regular", pointSize: 13.75),
            "Menlo-Regular:h13")
    }

    func testInvalidFontPanelSelectionIsRejected() {
        XCTAssertNil(guifontSpec(fontName: "", pointSize: 13))
        XCTAssertNil(guifontSpec(fontName: "Menlo-Regular", pointSize: .nan))
    }

    func testFontPanelSelectionIsClampedToSupportedSize() {
        XCTAssertEqual(
            guifontSpec(fontName: "Menlo-Regular", pointSize: 0),
            "Menlo-Regular:h1")
        XCTAssertEqual(
            guifontSpec(fontName: "Menlo-Regular", pointSize: 513),
            "Menlo-Regular:h512")
    }

    func testEmptyStringYieldsNoEntries() {
        XCTAssertEqual(parseGuifont("", defaultSize: 15), [])
    }

    func testNameWithoutSizeUsesDefault() {
        XCTAssertEqual(parseGuifont("Menlo", defaultSize: 15),
                       [GuifontEntry(name: "Menlo", size: 15)])
    }

    func testHeightSuffixSetsSize() {
        XCTAssertEqual(parseGuifont("Menlo:h13", defaultSize: 15),
                       [GuifontEntry(name: "Menlo", size: 13)])
    }

    func testMultiDigitSize() {
        XCTAssertEqual(parseGuifont("Menlo:h120", defaultSize: 15),
                       [GuifontEntry(name: "Menlo", size: 120)])
    }

    func testSpaceInName() {
        XCTAssertEqual(parseGuifont("Fira Code:h14", defaultSize: 15),
                       [GuifontEntry(name: "Fira Code", size: 14)])
    }

    func testMultipleEntriesInOrder() {
        XCTAssertEqual(
            parseGuifont("Menlo:h13,Fira Code:h14", defaultSize: 15),
            [GuifontEntry(name: "Menlo", size: 13),
             GuifontEntry(name: "Fira Code", size: 14)])
    }

    func testSpacesAfterSeparatorAreSkipped() {
        XCTAssertEqual(
            parseGuifont("Menlo:h13,  Fira Code", defaultSize: 15),
            [GuifontEntry(name: "Menlo", size: 13),
             GuifontEntry(name: "Fira Code", size: 15)])
    }

    func testEscapedCommaStaysInName() {
        // A backslash-escaped comma does not split the list; the whole name,
        // backslash retained, is one entry.
        XCTAssertEqual(
            parseGuifont("Weird\\,Font:h12", defaultSize: 15),
            [GuifontEntry(name: "Weird\\,Font", size: 12)])
    }

    func testTrailingCommaDoesNotAddEmptyEntry() {
        XCTAssertEqual(parseGuifont("Menlo,", defaultSize: 15),
                       [GuifontEntry(name: "Menlo", size: 15)])
    }

    func testColonWithoutHeightIsPartOfName() {
        // Only a `:h` suffix is a size; a bare colon-digit stays in the name.
        XCTAssertEqual(parseGuifont("Menlo:13", defaultSize: 15),
                       [GuifontEntry(name: "Menlo:13", size: 15)])
    }

    func testAllDigitsNameKeepsDefaultSize() {
        XCTAssertEqual(parseGuifont("123", defaultSize: 15),
                       [GuifontEntry(name: "123", size: 15)])
    }

    func testLeadingZeroesInSizeAreAccepted() {
        XCTAssertEqual(parseGuifont("Menlo:h0007", defaultSize: 15),
                       [GuifontEntry(name: "Menlo", size: 7)])
    }

    /// A size is read most significant digit first and saturates out of range,
    /// so padding it cannot overflow into being treated as part of the name.
    func testExcessiveLeadingZeroesStillYieldASize() {
        let padded = "Menlo:h" + String(repeating: "0", count: 20) + "7"
        XCTAssertEqual(parseGuifont(padded, defaultSize: 15),
                       [GuifontEntry(name: "Menlo", size: 7)])
    }

    func testOverflowingAndExcessiveSizesAreNotApplied() {
        let huge = "Menlo:h" + String(repeating: "9", count: 100)
        XCTAssertEqual(parseGuifont(huge, defaultSize: 15),
                       [GuifontEntry(name: huge, size: 15)])
        XCTAssertEqual(parseGuifont("Menlo:h513", defaultSize: 15),
                       [GuifontEntry(name: "Menlo:h513", size: 15)])
    }
}
