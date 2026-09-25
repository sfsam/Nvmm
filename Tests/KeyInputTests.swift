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

    private func mods(shift: Bool = false, control: Bool = false,
                      option: Bool = false, command: Bool = false) -> KeyModifiers {
        KeyModifiers(shift: shift, control: control, option: option, command: command)
    }

    func testEncoding() {
        XCTAssertEqual(escapeText(""), "")
        XCTAssertEqual(escapeText("abc"), "abc")
        XCTAssertEqual(escapeText("a<b<c"), "a<lt>b<lt>c")

        XCTAssertEqual(encodeNamed(.escape), "<Esc>")
        XCTAssertEqual(encodeNamed(.carriageReturn), "<CR>")
        XCTAssertEqual(encodeNamed(.f12), "<F12>")
        // Canonical order is Control, Shift, Option (M), Command (D).
        XCTAssertEqual(
            encodeNamed(.left, mods(shift: true, control: true,
                                    option: true, command: true)),
            "<C-S-M-D-Left>")

        // Without modifiers only escaping applies.
        XCTAssertEqual(encodeModified("<", mods()), "<lt>")
        XCTAssertEqual(encodeModified("c", mods(command: true)), "<D-c>")
        XCTAssertEqual(encodeModified("<", mods(control: true)), "<C-lt>")
    }

    /// Control with a symbol key sends the control character a terminal
    /// would, rather than a `<C-…>` notation Neovim does not recognize.
    func testControlSymbolSpecialCases() {
        var space = KeyboardEvent(modifierKeys: mods(control: true), named: .space)
        space.physical = .other
        let cases: [(String, KeyboardEvent, String)] = [
            ("Control-Space", space, "<Nul>"),
            ("Control-2", KeyboardEvent(modifierKeys: mods(control: true),
                                        physical: .digit2), "<Nul>"),
            ("Control-6", KeyboardEvent(modifierKeys: mods(control: true),
                                        physical: .digit6), "\u{1e}"),
            ("Control-minus", KeyboardEvent(modifierKeys: mods(control: true),
                                            physical: .minus), "<C-_>"),
        ]
        for (label, event, expected) in cases {
            XCTAssertEqual(routeKeyEvent(event), expected, label)
        }

        // Shift alongside Control disqualifies the special-case handling.
        let shifted = KeyboardEvent(modifierKeys: mods(shift: true, control: true),
                                    physical: .digit6)
        XCTAssertNotEqual(routeKeyEvent(shifted), "\u{1e}")
    }

    func testRouteKeyEvent() {
        // Option-Space that a layout turned into text routes the text.
        var optionSpaceText = KeyboardEvent(
            characters: "\u{a0}", modifierKeys: mods(option: true), named: .space)
        optionSpaceText.physical = .other

        let cases: [(String, KeyboardEvent, String)] = [
            ("plain text", KeyboardEvent(characters: "a"), "a"),
            ("plain <", KeyboardEvent(characters: "<"), "<lt>"),
            ("named key", KeyboardEvent(modifierKeys: mods(control: true),
                                        named: .left), "<C-Left>"),
            ("Option-Space text", optionSpaceText, "\u{a0}"),
            ("Option-Space", KeyboardEvent(characters: " ",
                                           modifierKeys: mods(option: true),
                                           named: .space), "<M-Space>"),
            ("Command key", KeyboardEvent(keyCharacters: "c",
                                          resolvedKeyCharacters: "c",
                                          modifierKeys: mods(command: true)),
             "<D-c>"),
            // Control-Shift-6 produces `^`; Shift is folded into the symbol,
            // so it is dropped and the resolved character is used.
            ("Shift embodied", KeyboardEvent(keyCharacters: "6",
                                             resolvedKeyCharacters: "^",
                                             modifierKeys: mods(shift: true,
                                                                control: true),
                                             shiftIsEmbodied: true), "<C-^>"),
            ("Command, no characters",
             KeyboardEvent(modifierKeys: mods(command: true)), ""),
        ]
        for (label, event, expected) in cases {
            XCTAssertEqual(routeKeyEvent(event), expected, label)
        }
    }

    func testKeyEquivalentArbitration() {
        let command = KeyboardEvent(modifierKeys: mods(command: true))
        let cases: [(String, Bool, Bool, KeyboardEvent, KeyEquivalentAction)] = [
            ("key up", false, false, command, .unhandled),
            ("menu equivalent", true, true, command, .deferToAppKit),
            // Control-Command-Space opens the Character Viewer.
            ("Character Viewer", true, false,
             KeyboardEvent(modifierKeys: mods(control: true, command: true),
                           named: .space), .deferToAppKit),
            ("Control-Tab", true, false,
             KeyboardEvent(modifierKeys: mods(control: true), named: .tab),
             .forwardToKeyDown),
            ("modified Space", true, false,
             KeyboardEvent(modifierKeys: mods(option: true), named: .space),
             .forwardToKeyDown),
            ("Command-period", true, false,
             KeyboardEvent(modifierKeys: mods(command: true), physical: .period),
             .forwardToKeyDown),
            ("plain key", true, false, KeyboardEvent(characters: "a"), .unhandled),
        ]
        for (label, isKeyDown, hasMenuEquivalent, event, expected) in cases {
            XCTAssertEqual(
                arbitrateKeyEquivalent(isKeyDown: isKeyDown,
                                       hasEnabledMenuEquivalent: hasMenuEquivalent,
                                       event: event),
                expected, label)
        }
    }
}
