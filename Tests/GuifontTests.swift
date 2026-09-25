//
//  NvmmTests
//  GuifontTests.swift
//
//  Coverage for `guifontSpec` and `parseGuifont`: single and multiple entries,
//  the `:h<size>` suffix, the default size fallback, backslash-escaped commas,
//  and space handling around separators. Pure value logic, so it is exempt
//  from the RenderTests teardown crash.
//

import CoreGraphics
import XCTest
@testable import Nvmm

final class GuifontTests: XCTestCase {

    /// The Font panel's choice becomes a concrete spec: the size is truncated
    /// to whole points and clamped to the supported range.
    func testFontPanelSelectionSpec() {
        let cases: [(String, CGFloat, String?)] = [
            ("Menlo-Regular", 13, "Menlo-Regular:h13"),
            ("Menlo-Regular", 13.75, "Menlo-Regular:h13"),
            ("Menlo-Regular", 0, "Menlo-Regular:h1"),
            ("Menlo-Regular", 513, "Menlo-Regular:h512"),
            ("", 13, nil),
            ("Menlo-Regular", .nan, nil),
        ]
        for (name, size, expected) in cases {
            XCTAssertEqual(guifontSpec(fontName: name, pointSize: size),
                           expected, "\(name) \(size)")
        }
    }

    func testParseGuifont() {
        func entry(_ name: String, _ size: CGFloat = 15) -> GuifontEntry {
            GuifontEntry(name: name, size: size)
        }
        let huge = "Menlo:h" + String(repeating: "9", count: 100)
        let cases: [(String, [GuifontEntry])] = [
            ("", []),
            ("Menlo", [entry("Menlo")]),
            ("Menlo:h13", [entry("Menlo", 13)]),
            ("Menlo:h120", [entry("Menlo", 120)]),
            ("Fira Code:h14", [entry("Fira Code", 14)]),
            ("Menlo:h13,Fira Code:h14",
             [entry("Menlo", 13), entry("Fira Code", 14)]),
            // Spaces after a separator are skipped.
            ("Menlo:h13,  Fira Code", [entry("Menlo", 13), entry("Fira Code")]),
            // A backslash-escaped comma does not split the list; the whole
            // name, backslash retained, is one entry.
            ("Weird\\,Font:h12", [entry("Weird\\,Font", 12)]),
            ("Menlo,", [entry("Menlo")]),
            // Only a `:h` suffix is a size; a bare colon-digit stays in the name.
            ("Menlo:13", [entry("Menlo:13")]),
            ("123", [entry("123")]),
            ("Menlo:h0007", [entry("Menlo", 7)]),
            // A size is read most significant digit first and saturates out of
            // range, so padding cannot overflow it into being part of the name.
            ("Menlo:h" + String(repeating: "0", count: 20) + "7",
             [entry("Menlo", 7)]),
            // A size that overflows or exceeds the limit is not applied.
            (huge, [entry(huge)]),
            ("Menlo:h513", [entry("Menlo:h513")]),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(parseGuifont(value, defaultSize: 15), expected,
                           value)
        }
    }
}
