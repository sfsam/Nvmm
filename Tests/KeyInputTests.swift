//
//  NvmmTests
//  KeyInputTests.swift
//
//  KeyInput coverage: modifier ordering, text escaping, named-key and modified
//  encoding, the Control-symbol special cases, the Command/Control routing path
//  (including Shift folded into a symbol), Option as Meta, and key-equivalent
//  arbitration. All pure value logic, driven with synthetic `KeyboardEvent`s.
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
        XCTAssertEqual(encodeNamed(.keypadEnter), "<kEnter>")
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
            // Keypad Enter's text is ETX, which must not reach Neovim.
            ("keypad Enter", KeyboardEvent(characters: "\u{3}",
                                           named: .keypadEnter), "<kEnter>"),
            ("Shift-keypad Enter",
             KeyboardEvent(characters: "\u{3}",
                           modifierKeys: mods(shift: true),
                           named: .keypadEnter), "<S-kEnter>"),
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
            // Keypad Clear has no Neovim name; its function-key character
            // is not text, with or without modifiers.
            ("keypad Clear", KeyboardEvent(characters: "\u{f739}"), ""),
            ("Control-keypad Clear",
             KeyboardEvent(characters: "\u{f739}", keyCharacters: "\u{f739}",
                           resolvedKeyCharacters: "\u{f739}",
                           modifierKeys: mods(control: true)), ""),
            ("Command-keypad Clear",
             KeyboardEvent(characters: "\u{f739}", keyCharacters: "\u{f739}",
                           resolvedKeyCharacters: "\u{f739}",
                           modifierKeys: mods(command: true)), ""),
            // Shift is taken as embodied in a symbol with no letters, so this
            // reads the resolved key instead.
            ("Shift-Control-keypad Clear",
             KeyboardEvent(characters: "\u{f739}", keyCharacters: "\u{f739}",
                           resolvedKeyCharacters: "\u{f739}",
                           modifierKeys: mods(shift: true, control: true),
                           shiftIsEmbodied: true), ""),
            ("Option-keypad Clear",
             KeyboardEvent(characters: "\u{f739}",
                           resolvedKeyCharacters: "\u{f739}",
                           modifierKeys: mods(option: true)), ""),
            // The Apple logo is private-use too, but it is text.
            ("Apple logo", KeyboardEvent(characters: "\u{f8ff}",
                                         modifierKeys: mods(shift: true,
                                                            option: true)),
             "\u{f8ff}"),
        ]
        for (label, event, expected) in cases {
            XCTAssertEqual(routeKeyEvent(event), expected, label)
        }

        // In text-entry modes keypad Enter goes straight to Neovim, as
        // Return does, rather than through Cocoa as text.
        let keypadEnter = KeyboardEvent(characters: "\u{3}", named: .keypadEnter)
        XCTAssertFalse(shouldOfferToCocoa(mode: .insert,
                                          compositionActive: false,
                                          event: keypadEnter))
    }

    func testOptionAsMetaSides() {
        let option = KeyboardEvent(resolvedKeyCharacters: "h",
                                   modifierKeys: mods(option: true))
        var left = option
        left.leftOption = true
        var right = option
        right.rightOption = true
        var bothKeys = left
        bothKeys.rightOption = true

        XCTAssertFalse(optionActsAsMeta(left, .off))
        XCTAssertTrue(optionActsAsMeta(left, .left))
        XCTAssertFalse(optionActsAsMeta(left, .right))
        XCTAssertFalse(optionActsAsMeta(right, .left))
        XCTAssertTrue(optionActsAsMeta(right, .right))
        XCTAssertTrue(optionActsAsMeta(left, .both))
        XCTAssertTrue(optionActsAsMeta(right, .both))
        XCTAssertTrue(optionActsAsMeta(bothKeys, .left))
        XCTAssertTrue(optionActsAsMeta(bothKeys, .right))
        // A press that names no side counts as the left key.
        XCTAssertTrue(optionActsAsMeta(option, .left))
        XCTAssertFalse(optionActsAsMeta(option, .right))
        XCTAssertTrue(optionActsAsMeta(option, .both))
    }

    func testOptionAsMetaKeys() {
        func event(_ resolved: String, _ modifiers: KeyModifiers,
                   named: NamedKey? = nil) -> KeyboardEvent {
            KeyboardEvent(resolvedKeyCharacters: resolved,
                          modifierKeys: modifiers, named: named)
        }
        let option = mods(option: true)
        let cases: [(String, KeyboardEvent, Bool)] = [
            ("letter", event("h", option), true),
            ("shifted", event("H", mods(shift: true, option: true)), true),
            ("symbol", event(">", option), true),
            ("non-ASCII", event("é", option), true),
            ("Space", event(" ", option, named: .space), true),
            ("no Option", event("h", mods()), false),
            // Command and Control chords already carry M- unchanged.
            ("Command", event("h", mods(option: true, command: true)), false),
            ("Control", event("h", mods(control: true, option: true)), false),
            ("other named key", event("", option, named: .left), false),
            ("keypad Enter", event("\u{3}", option, named: .keypadEnter),
             false),
            ("no key", event("", option), false),
            ("two characters", event("ab", option), false),
            // Neovim would keep only the `e` of a decomposed `é`.
            ("combining mark", event("e\u{301}", option), false),
            ("control character", event("\u{3}", option), false),
            ("function-key character", event("\u{f739}", option), false),
            ("whitespace", event("\u{a0}", option), false),
        ]
        for (label, event, expected) in cases {
            XCTAssertEqual(optionActsAsMeta(event, .both), expected, label)
        }
    }

    func testOptionAsMetaRouting() {
        func meta(_ characters: String, _ resolved: String,
                  _ modifiers: KeyModifiers,
                  named: NamedKey? = nil) -> KeyboardEvent {
            KeyboardEvent(characters: characters,
                          resolvedKeyCharacters: resolved,
                          modifierKeys: modifiers, named: named,
                          optionIsMeta: true)
        }
        let option = mods(option: true)
        let shiftOption = mods(shift: true, option: true)
        let cases: [(String, KeyboardEvent, String)] = [
            ("letter", meta("\u{2d9}", "h", option), "<M-h>"),
            // Shift is in the character. Neovim reads <M-S-h> as <M-H> too.
            ("shifted letter", meta("\u{d3}", "H", shiftOption), "<M-H>"),
            ("shifted digit", meta("\u{2044}", "!", shiftOption), "<M-!>"),
            ("less-than", meta("\u{af}", "<", shiftOption), "<M-lt>"),
            // A dead key produces no text but still has a key.
            ("dead key", meta("", "e", option), "<M-e>"),
            ("Space", meta("\u{a0}", " ", option, named: .space),
             "<M-Space>"),
            ("greater-than", meta("\u{2d8}", ">", shiftOption), "<M->>"),
        ]
        for (label, event, expected) in cases {
            XCTAssertEqual(routeKeyEvent(event), expected, label)
        }

        // Meta keys skip Cocoa so no Option text or dead key is composed,
        // even during a composition, which GridView commits first.
        let event = meta("\u{2d9}", "h", option)
        XCTAssertFalse(shouldOfferToCocoa(mode: .insert,
                                          compositionActive: false,
                                          event: event))
        XCTAssertFalse(shouldOfferToCocoa(mode: .insert,
                                          compositionActive: true,
                                          event: event))
        var text = event
        text.optionIsMeta = false
        XCTAssertTrue(shouldOfferToCocoa(mode: .insert,
                                         compositionActive: false,
                                         event: text))
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
