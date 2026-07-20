//
//  NvmmTests
//  KeyInputTests.swift
//
//  KeyInput coverage: modifier ordering, text escaping, named-key and modified
//  encoding, the Control-symbol special cases, the Command/Control routing path
//  (including Shift folded into a symbol), and key-equivalent arbitration. All
//  pure value logic, driven with synthetic `KeyboardEvent`s.
//

import XCTest
@testable import Nvmm

final class KeyInputTests: XCTestCase {

    // MARK: Helpers

    private func mods(shift: Bool = false, control: Bool = false,
                      option: Bool = false, command: Bool = false) -> KeyModifiers {
        KeyModifiers(shift: shift, control: control, option: option, command: command)
    }

    // MARK: Encoding

    func testEscapeTextPassesPlainText() {
        XCTAssertEqual(escapeText("abc"), "abc")
        XCTAssertEqual(escapeText(""), "")
    }

    func testEscapeTextReplacesLessThan() {
        XCTAssertEqual(escapeText("<"), "<lt>")
        XCTAssertEqual(escapeText("a<b<c"), "a<lt>b<lt>c")
    }

    func testAppendModifiersCanonicalOrder() {
        // Canonical order is Control, Shift, Option (M), Command (D).
        XCTAssertEqual(
            encodeNamed(.left, mods(shift: true, control: true,
                                    option: true, command: true)),
            "<C-S-M-D-Left>")
    }

    func testEncodeNamedNoModifiers() {
        XCTAssertEqual(encodeNamed(.escape), "<Esc>")
        XCTAssertEqual(encodeNamed(.carriageReturn), "<CR>")
        XCTAssertEqual(encodeNamed(.f12), "<F12>")
    }

    func testEncodeModifiedEmptyModifiersEscapesOnly() {
        XCTAssertEqual(encodeModified("a", mods()), "a")
        XCTAssertEqual(encodeModified("<", mods()), "<lt>")
    }

    func testEncodeModifiedWrapsWithModifiers() {
        XCTAssertEqual(encodeModified("c", mods(command: true)), "<D-c>")
        XCTAssertEqual(encodeModified("<", mods(control: true)), "<C-lt>")
    }

    // MARK: Control-symbol special cases

    func testControlSpaceIsNul() {
        var event = KeyboardEvent(modifierKeys: mods(control: true), named: .space)
        event.physical = .other
        XCTAssertEqual(routeKeyEvent(event), "<Nul>")
    }

    func testControlDigit2IsNul() {
        let event = KeyboardEvent(modifierKeys: mods(control: true),
                                  physical: .digit2)
        XCTAssertEqual(routeKeyEvent(event), "<Nul>")
    }

    func testControlDigit6IsRecordSeparator() {
        let event = KeyboardEvent(modifierKeys: mods(control: true),
                                  physical: .digit6)
        XCTAssertEqual(routeKeyEvent(event), "\u{1e}")
    }

    func testControlMinusIsUnderscore() {
        let event = KeyboardEvent(modifierKeys: mods(control: true),
                                  physical: .minus)
        XCTAssertEqual(routeKeyEvent(event), "<C-_>")
    }

    func testControlSymbolCasesRequireOnlyControl() {
        // Shift alongside Control disqualifies the special-case handling.
        let event = KeyboardEvent(modifierKeys: mods(shift: true, control: true),
                                  physical: .digit6)
        XCTAssertNotEqual(routeKeyEvent(event), "\u{1e}")
    }

    // MARK: Named keys

    func testNamedKeyRoutesWithModifiers() {
        let event = KeyboardEvent(modifierKeys: mods(control: true), named: .left)
        XCTAssertEqual(routeKeyEvent(event), "<C-Left>")
    }

    func testOptionSpaceThatProducedTextIsText() {
        // Option-Space that a layout turned into text routes the text, not <Space>.
        var event = KeyboardEvent(characters: "\u{a0}",
                                  modifierKeys: mods(option: true), named: .space)
        event.physical = .other
        XCTAssertEqual(routeKeyEvent(event), "\u{a0}")
    }

    func testOptionSpaceWithoutTextIsNamed() {
        let event = KeyboardEvent(characters: " ",
                                  modifierKeys: mods(option: true), named: .space)
        XCTAssertEqual(routeKeyEvent(event), "<M-Space>")
    }

    // MARK: Plain and modified text

    func testPlainTextIsEscapedCharacters() {
        let event = KeyboardEvent(characters: "a")
        XCTAssertEqual(routeKeyEvent(event), "a")
    }

    func testPlainLessThanIsEscaped() {
        let event = KeyboardEvent(characters: "<")
        XCTAssertEqual(routeKeyEvent(event), "<lt>")
    }

    func testCommandKeyUsesKeyCharacters() {
        let event = KeyboardEvent(keyCharacters: "c",
                                  resolvedKeyCharacters: "c",
                                  modifierKeys: mods(command: true))
        XCTAssertEqual(routeKeyEvent(event), "<D-c>")
    }

    func testShiftEmbodiedDropsShiftAndUsesResolved() {
        // Control-Shift-6 produces `^`; Shift is folded into the symbol, so it is
        // dropped and the resolved character is used.
        let event = KeyboardEvent(keyCharacters: "6",
                                  resolvedKeyCharacters: "^",
                                  modifierKeys: mods(shift: true, control: true),
                                  shiftIsEmbodied: true)
        XCTAssertEqual(routeKeyEvent(event), "<C-^>")
    }

    func testCommandKeyEmptyKeyCharactersProducesNothing() {
        let event = KeyboardEvent(modifierKeys: mods(command: true))
        XCTAssertEqual(routeKeyEvent(event), "")
    }

    // MARK: Key-equivalent arbitration

    func testArbitrationIgnoresKeyUp() {
        let event = KeyboardEvent(modifierKeys: mods(command: true))
        XCTAssertEqual(
            arbitrateKeyEquivalent(isKeyDown: false,
                                   hasEnabledMenuEquivalent: false, event: event),
            .unhandled)
    }

    func testArbitrationDefersToMenu() {
        let event = KeyboardEvent(modifierKeys: mods(command: true))
        XCTAssertEqual(
            arbitrateKeyEquivalent(isKeyDown: true,
                                   hasEnabledMenuEquivalent: true, event: event),
            .deferToAppKit)
    }

    func testArbitrationPreservesCharacterViewerShortcut() {
        let event = KeyboardEvent(modifierKeys: mods(control: true, command: true),
                                  named: .space)
        XCTAssertEqual(
            arbitrateKeyEquivalent(isKeyDown: true,
                                   hasEnabledMenuEquivalent: false, event: event),
            .deferToAppKit)
    }

    func testArbitrationForwardsControlTab() {
        let event = KeyboardEvent(modifierKeys: mods(control: true), named: .tab)
        XCTAssertEqual(
            arbitrateKeyEquivalent(isKeyDown: true,
                                   hasEnabledMenuEquivalent: false, event: event),
            .forwardToKeyDown)
    }

    func testArbitrationForwardsModifiedSpace() {
        let event = KeyboardEvent(modifierKeys: mods(option: true), named: .space)
        XCTAssertEqual(
            arbitrateKeyEquivalent(isKeyDown: true,
                                   hasEnabledMenuEquivalent: false, event: event),
            .forwardToKeyDown)
    }

    func testArbitrationForwardsCommandPeriod() {
        let event = KeyboardEvent(modifierKeys: mods(command: true),
                                  physical: .period)
        XCTAssertEqual(
            arbitrateKeyEquivalent(isKeyDown: true,
                                   hasEnabledMenuEquivalent: false, event: event),
            .forwardToKeyDown)
    }

    func testArbitrationUnhandledByDefault() {
        let event = KeyboardEvent(characters: "a")
        XCTAssertEqual(
            arbitrateKeyEquivalent(isKeyDown: true,
                                   hasEnabledMenuEquivalent: false, event: event),
            .unhandled)
    }
}
