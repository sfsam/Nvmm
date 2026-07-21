//
//  NvmmTests
//  ClipboardTests.swift
//
//  Coverage for the pasteboard bridge: set/get round-trips preserve the text
//  and the Vim register type, plain text from other apps reads as an unknown
//  (charwise) type, an empty pasteboard reads as no lines, and malformed
//  `clipboard_set` arguments are rejected. Uses a private named pasteboard so
//  the tests never touch the user's clipboard.
//

import XCTest
import AppKit
@testable import Nvmm

@MainActor
final class ClipboardTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("NvmmClipboardTests"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.clearContents()
        pasteboard = nil
        super.tearDown()
    }

    /// Unwraps a `.result`, failing the test on `.error`.
    private func result(_ outcome: RequestOutcome) -> MPValue? {
        guard case .result(let value) = outcome else {
            XCTFail("expected .result, got \(outcome)")
            return nil
        }
        return value
    }

    private func set(_ lines: [String], _ regtype: String) -> RequestOutcome {
        Clipboard.set([.array(lines.map(MPValue.string)), .string(regtype)],
                      pasteboard: pasteboard)
    }

    private func get() -> RequestOutcome {
        Clipboard.get([], pasteboard: pasteboard)
    }

    func testCharwiseRoundTrip() {
        XCTAssertEqual(result(set(["hello"], "v")), .null)
        XCTAssertEqual(result(get()),
                       .array([.array([.string("hello")]), .string("c")]))
    }

    func testLinewiseRegtypePreserved() {
        _ = set(["alpha", "beta"], "V")
        XCTAssertEqual(result(get()),
                       .array([.array([.string("alpha"), .string("beta")]),
                               .string("l")]))
    }

    func testBlockwiseRegtypePreserved() {
        _ = set(["x"], "b")
        XCTAssertEqual(result(get()),
                       .array([.array([.string("x")]), .string("b")]))
    }

    func testMultilineTextSplitsBackToLines() {
        _ = set(["one", "two", "three"], "v")
        guard let value = result(get()),
              case .array(let pair) = value, pair.count == 2 else {
            return XCTFail("expected a [lines, regtype] pair")
        }
        XCTAssertEqual(pair[0],
                       .array([.string("one"), .string("two"), .string("three")]))
    }

    func testPlainTextFromOtherAppReadsAsUnknownType() {
        // No Vim type present: an unknown register type (empty string), which
        // Neovim treats as charwise.
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("from another app", forType: .string)
        XCTAssertEqual(result(get()),
                       .array([.array([.string("from another app")]),
                               .string("")]))
    }

    func testEmptyPasteboardReturnsNoLines() {
        XCTAssertEqual(result(get()), .array([.array([]), .string("")]))
    }

    func testSetRejectsWrongArgumentCount() {
        guard case .error = Clipboard.set([.array([])], pasteboard: pasteboard)
        else { return XCTFail("expected .error for a single argument") }
    }

    func testSetRejectsNonArrayLines() {
        let outcome = Clipboard.set([.string("x"), .string("v")],
                                    pasteboard: pasteboard)
        guard case .error = outcome else {
            return XCTFail("expected .error when lines is not an array")
        }
    }

    func testSetRejectsNonStringLine() {
        let outcome = Clipboard.set([.array([.int(1)]), .string("v")],
                                    pasteboard: pasteboard)
        guard case .error = outcome else {
            return XCTFail("expected .error when a line is not a string")
        }
    }

    func testSetRejectsNonStringRegtype() {
        let outcome = Clipboard.set([.array([.string("x")]), .int(1)],
                                    pasteboard: pasteboard)
        guard case .error = outcome else {
            return XCTFail("expected .error when regtype is not a string")
        }
    }

    // MARK: - contentForPaste (drives the native paste branch)

    func testContentForPasteEmptyIsNone() {
        XCTAssertEqual(Clipboard.contentForPaste(pasteboard: pasteboard), .none)
    }

    func testContentForPastePlainTextFromOtherApp() {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("hello", forType: .string)
        XCTAssertEqual(Clipboard.contentForPaste(pasteboard: pasteboard),
                       .plainText("hello"))
    }

    func testContentForPasteVimRegisterForValidRegtype() {
        _ = set(["a", "b"], "V")
        XCTAssertEqual(Clipboard.contentForPaste(pasteboard: pasteboard),
                       .vimRegister)
    }

    func testContentForPasteUnknownRegtypeFallsBackToPlainText() {
        // An unknown register type (e.g. text put on the Vim type by something
        // that did not set a real regtype) is not a usable Vim register, so it
        // is treated as plain text.
        _ = set(["x"], "")
        guard case .plainText = Clipboard.contentForPaste(pasteboard: pasteboard)
        else { return XCTFail("expected .plainText for an unknown register type") }
    }
}
