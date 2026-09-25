//
//  NvmmTests
//  PasteTrimmingTextFieldTests.swift
//

import AppKit
import XCTest
@testable import Nvmm

@MainActor
final class PasteTrimmingTextFieldTests: XCTestCase {
    private lazy var pasteboard: NSPasteboard = {
        let name = NSPasteboard.Name(
            "PasteTrimmingTextFieldTests.\(UUID())")
        let pasteboard = NSPasteboard(name: name)
        pasteboard.clearContents()
        return pasteboard
    }()

    func testTextFieldUsesPasteTrimmingFieldEditor() {
        let field = PasteTrimmingTextField(frame: .zero)
        let editor = field.cell?.fieldEditor(for: field)

        XCTAssertTrue(field.cell is PasteTrimmingTextFieldCell)
        XCTAssertTrue(editor is PasteTrimmingFieldEditor)
        XCTAssertEqual(editor?.isFieldEditor, true)
    }

    /// A paste is trimmed of surrounding whitespace, whether it inserts at
    /// the caret or replaces a selection.
    func testPasteTrimsSurroundingWhitespace() {
        let editor = makeEditor(initialString: "/tmp/")
        setPasteboardString("  nvim socket \n")
        editor.paste(nil)
        XCTAssertEqual(editor.string, "/tmp/nvim socket")

        let replacing = makeEditor(initialString: "/tmp/old.sock")
        replacing.setSelectedRange(NSRange(location: 5, length: 8))
        setPasteboardString(" new.sock ")
        replacing.paste(nil)
        XCTAssertEqual(replacing.string, "/tmp/new.sock")
    }

    func testOrdinaryInsertionRetainsWhitespace() {
        let editor = makeEditor(initialString: "/tmp/nvimsocket")
        editor.insertText(
            " ",
            replacementRange: NSRange(location: 9, length: 0))

        XCTAssertEqual(editor.string, "/tmp/nvim socket")
    }

    private func makeEditor(initialString: String) -> PasteTrimmingFieldEditor {
        let editor = PasteTrimmingFieldEditor(pasteboard: pasteboard)
        editor.string = initialString
        editor.setSelectedRange(NSRange(
            location: (initialString as NSString).length,
            length: 0))
        return editor
    }

    private func setPasteboardString(_ string: String) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
