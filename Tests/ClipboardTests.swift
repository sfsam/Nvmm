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
    private lazy var pasteboard: NSPasteboard = {
        let name = NSPasteboard.Name("NvmmClipboardTests.\(UUID())")
        let pasteboard = NSPasteboard(name: name)
        pasteboard.clearContents()
        return pasteboard
    }()

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

    /// Each Vim register type survives a round trip, as does the split into
    /// lines.
    func testRoundTripPreservesLinesAndRegisterType() {
        let cases: [([String], String, String)] = [
            (["hello"], "v", "c"),
            (["alpha", "beta"], "V", "l"),
            (["x"], "b", "b"),
            (["one", "two", "three"], "v", "c"),
        ]
        for (lines, regtype, expected) in cases {
            XCTAssertEqual(result(set(lines, regtype)), .null)
            XCTAssertEqual(result(get()),
                           .array([.array(lines.map(MPValue.string)),
                                   .string(expected)]),
                           "\(lines) \(regtype)")
        }
    }

    /// Text without a Vim type reads as an unknown register type (an empty
    /// string), which Neovim treats as charwise; nothing reads as no lines.
    func testGetWithoutVimType() {
        XCTAssertEqual(result(get()), .array([.array([]), .string("")]))

        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("from another app", forType: .string)
        XCTAssertEqual(result(get()),
                       .array([.array([.string("from another app")]),
                               .string("")]))
    }

    func testSetRejectsMalformedArguments() {
        let cases: [(String, [MPValue])] = [
            ("single argument", [.array([])]),
            ("lines not an array", [.string("x"), .string("v")]),
            ("line not a string", [.array([.int(1)]), .string("v")]),
            ("regtype not a string", [.array([.string("x")]), .int(1)]),
        ]
        for (label, arguments) in cases {
            guard case .error = Clipboard.set(arguments, pasteboard: pasteboard)
            else { return XCTFail("expected .error: \(label)") }
        }
    }

    // MARK: - contentForPaste (drives the native paste branch)

    func testContentForPaste() {
        XCTAssertEqual(Clipboard.contentForPaste(pasteboard: pasteboard), .none)

        _ = set(["a", "b"], "V")
        XCTAssertEqual(Clipboard.contentForPaste(pasteboard: pasteboard),
                       .vimRegister)

        // An unknown register type (e.g. text put on the Vim type by something
        // that did not set a real regtype) is not a usable Vim register, so it
        // is treated as plain text.
        _ = set(["x"], "")
        guard case .plainText = Clipboard.contentForPaste(pasteboard: pasteboard)
        else { return XCTFail("expected .plainText for an unknown register type") }

        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("hello", forType: .string)
        XCTAssertEqual(Clipboard.contentForPaste(pasteboard: pasteboard),
                       .plainText("hello"))
    }
}
