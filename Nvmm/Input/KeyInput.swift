//
//  Nvmm
//  KeyInput.swift
//
//  Pure keyboard input types and Neovim key-notation encoding.
//
//  A normalized Cocoa key event becomes a `KeyboardEvent`; `routeKeyEvent` turns
//  it into one `nvim_input` payload, or the empty string for events that produce
//  no input. This layer is value logic with no AppKit dependency, so it is unit
//  tested in isolation. It also holds the marked-text / IME composition policy:
//  whether to offer an event to Cocoa, how dead-key and IME sessions treat
//  Escape/Delete/focus loss, how a Cocoa handle-event transaction resolves, and
//  how committed text is transported. The single-row preedit geometry math lives
//  in `Composition.swift`.
//

import Foundation

/// Raw modifier-flag bit patterns AppKit reports for the physical Option keys.
/// Used to attribute an Option press to the left or right key.
nonisolated let leftOptionFlag: UInt = 0x080020
nonisolated let rightOptionFlag: UInt = 0x080040

nonisolated struct KeyModifiers: Equatable, Sendable {
    var shift = false
    var control = false
    var option = false
    var command = false

    var isEmpty: Bool { !shift && !control && !option && !command }
}

nonisolated enum NamedKey: Sendable, Equatable {
    case carriageReturn, tab, space, backspace, deleteForward, escape, help
    case home, end, pageUp, pageDown, left, right, up, down
    case volumeUp, volumeDown, mute
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10
    case f11, f12, f13, f14, f15, f16, f17, f18, f19, f20
    case f21, f22, f23, f24, f25, f26, f27, f28, f29, f30
    case f31, f32, f33, f34, f35

    /// The Neovim key-notation name (the text between `<` and `>`).
    var name: String {
        switch self {
        case .carriageReturn: return "CR"
        case .tab:            return "Tab"
        case .space:          return "Space"
        case .backspace:      return "BS"
        case .deleteForward:  return "Del"
        case .escape:         return "Esc"
        case .help:           return "Help"
        case .home:           return "Home"
        case .end:            return "End"
        case .pageUp:         return "PageUp"
        case .pageDown:       return "PageDown"
        case .left:           return "Left"
        case .right:          return "Right"
        case .up:             return "Up"
        case .down:           return "Down"
        case .volumeUp:       return "VolumeUp"
        case .volumeDown:     return "VolumeDown"
        case .mute:           return "Mute"
        case .f1:  return "F1";  case .f2:  return "F2";  case .f3:  return "F3"
        case .f4:  return "F4";  case .f5:  return "F5";  case .f6:  return "F6"
        case .f7:  return "F7";  case .f8:  return "F8";  case .f9:  return "F9"
        case .f10: return "F10"; case .f11: return "F11"; case .f12: return "F12"
        case .f13: return "F13"; case .f14: return "F14"; case .f15: return "F15"
        case .f16: return "F16"; case .f17: return "F17"; case .f18: return "F18"
        case .f19: return "F19"; case .f20: return "F20"; case .f21: return "F21"
        case .f22: return "F22"; case .f23: return "F23"; case .f24: return "F24"
        case .f25: return "F25"; case .f26: return "F26"; case .f27: return "F27"
        case .f28: return "F28"; case .f29: return "F29"; case .f30: return "F30"
        case .f31: return "F31"; case .f32: return "F32"; case .f33: return "F33"
        case .f34: return "F34"; case .f35: return "F35"
        }
    }
}

nonisolated enum PhysicalKey: Sendable, Equatable {
    case other, digit2, digit6, minus, period
}

/// Appends the modifier prefix in canonical order, which makes emitted input
/// deterministic and easy to test.
nonisolated func appendModifiers(_ result: inout String, _ value: KeyModifiers) {
    if value.control { result += "C-" }
    if value.shift   { result += "S-" }
    if value.option  { result += "M-" }
    if value.command { result += "D-" }
}

/// Encodes a named key with its modifiers, e.g. `<C-Left>`.
nonisolated func encodeNamed(_ key: NamedKey, _ value: KeyModifiers = KeyModifiers()) -> String {
    var result = "<"
    appendModifiers(&result, value)
    result += key.name
    result += ">"
    return result
}

/// Escapes literal text for `nvim_input`, where `<` introduces key notation.
nonisolated func escapeText(_ text: String) -> String {
    guard text.contains("<") else { return text }
    var result = ""
    result.reserveCapacity(text.count)
    for character in text {
        if character == "<" { result += "<lt>" } else { result.append(character) }
    }
    return result
}

/// Encodes text carrying modifiers, e.g. `<D-c>`. A bare `<` becomes `<lt>`.
nonisolated func encodeModified(_ text: String, _ value: KeyModifiers) -> String {
    if value.isEmpty { return escapeText(text) }

    var result = "<"
    appendModifiers(&result, value)
    result += (text == "<") ? "lt" : text
    result += ">"
    return result
}

/// One normalized Cocoa key event: the fields `routeKeyEvent` needs, filled in
/// by the view that receives the `NSEvent`.
nonisolated struct KeyboardEvent: Sendable {
    var keyCode: UInt16 = 0
    /// Cocoa's `characters`: the text the layout produces, modifiers applied.
    var characters = ""
    /// Unshifted Cocoa key identity, with modifier transformations removed.
    var keyCharacters = ""
    /// Cocoa's resolved key identity after applying Shift / Caps Lock, but not
    /// Command, Control, or Option.
    var resolvedKeyCharacters = ""
    var modifierKeys = KeyModifiers()
    var named: NamedKey?
    var physical: PhysicalKey = .other
    var capsLock = false
    var shiftIsEmbodied = false
    var isRepeat = false
    var leftOption = false
    var rightOption = false
}

/// Records which physical Option key produced this event from the raw flags.
nonisolated func setOptionSides(_ event: inout KeyboardEvent, rawFlags: UInt) {
    event.leftOption = (rawFlags & leftOptionFlag) == leftOptionFlag
    event.rightOption = (rawFlags & rightOptionFlag) == rightOptionFlag
}

nonisolated func hasOnlyControl(_ value: KeyModifiers) -> Bool {
    value.control && !value.shift && !value.option && !value.command
}

/// Converts a normalized Cocoa key event into one `nvim_input` payload. An empty
/// result means the event produces no Neovim input.
nonisolated func routeKeyEvent(_ event: KeyboardEvent) -> String {
    if hasOnlyControl(event.modifierKeys) {
        if event.named == .space || event.physical == .digit2 {
            return "<Nul>"
        }
        if event.physical == .digit6 {
            return "\u{1e}"
        }
        if event.physical == .minus {
            return "<C-_>"
        }
    }

    let optionSpaceProducedText =
        event.named == .space && event.modifierKeys.option &&
        !event.modifierKeys.command && !event.modifierKeys.control &&
        !event.characters.isEmpty && event.characters != " "
    if let named = event.named, !optionSpaceProducedText {
        return encodeNamed(named, event.modifierKeys)
    }

    if event.modifierKeys.command || event.modifierKeys.control {
        var encodedModifiers = event.modifierKeys
        var key = event.keyCharacters
        if event.shiftIsEmbodied {
            // Shift-produced punctuation (for example `^` from Shift-6) already
            // carries Shift in the symbol. Encoding S- again changes its key.
            encodedModifiers.shift = false
            key = event.resolvedKeyCharacters
        }
        if key.isEmpty { return "" }
        return encodeModified(key, encodedModifiers)
    }

    return escapeText(event.characters)
}

nonisolated enum KeyEquivalentAction: Sendable, Equatable {
    case unhandled
    case deferToAppKit
    case forwardToKeyDown
}

/// Decides how a key equivalent should be handled: left to AppKit's menu, sent
/// on to `keyDown`, or ignored so AppKit continues its search.
nonisolated func arbitrateKeyEquivalent(isKeyDown: Bool,
                                        hasEnabledMenuEquivalent: Bool,
                                        event: KeyboardEvent) -> KeyEquivalentAction {
    if !isKeyDown { return .unhandled }
    if hasEnabledMenuEquivalent { return .deferToAppKit }

    let mods = event.modifierKeys
    if event.named == .space && mods.command && mods.control {
        // Preserve the system Character Viewer shortcut.
        return .deferToAppKit
    }

    if (event.named == .tab && mods.control) ||
        (event.named == .space && !mods.isEmpty) ||
        (event.physical == .period && mods.command) {
        return .forwardToKeyDown
    }
    return .unhandled
}

// MARK: - Composition policy

/// The lifecycle phase of a Cocoa marked-text session.
nonisolated enum CompositionPhase: Sendable, Equatable {
    case inactive, marked, suspended, cancelling
}

/// The source of a marked-text session, which selects its Escape/Delete/focus
/// policy. Captured once when the session starts.
///
///   dead key: Escape commits, Delete cancels before Cocoa, focus loss cancels.
///   IME:      Escape cancels, Delete edits through Cocoa, focus loss suspends.
///   unknown:  conservative cancellation behavior.
nonisolated enum CompositionKind: Sendable, Equatable {
    case unknown, deadKey, ime
}

nonisolated func deadKeyEscapeCommits(_ kind: CompositionKind) -> Bool {
    kind == .deadKey
}

nonisolated func deleteCancelsBeforeCocoa(_ kind: CompositionKind) -> Bool {
    kind == .deadKey
}

nonisolated func focusLossSuspends(_ kind: CompositionKind) -> Bool {
    kind == .ime
}

/// Whether a key event should be offered to Cocoa's text-input system rather
/// than routed straight to Neovim.
nonisolated func shouldOfferToCocoa(mode: TextEntryMode,
                                    compositionActive: Bool,
                                    event: KeyboardEvent) -> Bool {
    if compositionActive { return true }
    if mode == .directNeovim { return false }
    if event.modifierKeys.command || event.modifierKeys.control { return false }

    // Cocoa owns text production in text-entry modes: ordinary layout text,
    // Option transformations, dead keys, IME input, and key repeat. Named
    // editing/navigation keys stay on Neovim's direct path; Space is text.
    return event.named == nil || event.named == .space
}

/// The routing decision after a Cocoa handle-event transaction.
nonisolated enum CocoaEventResult: Sendable, Equatable {
    case consume
    case routeToNeovim
    case commitAndConsume
    case commitAndRouteToNeovim
    case cancelAndConsume
}

/// What Cocoa's synchronous callbacks did during a handle-event transaction.
nonisolated enum CocoaCallbackEffect: Sendable, Equatable {
    case none, text, editingCommand
}

/// The observable results of one `NSTextInputContext.handleEvent` call: its
/// return value, the callback side effect, and whether marked text remains.
nonisolated struct CocoaEventTransaction: Sendable {
    var handleEventReturned = false
    var callbackEffect: CocoaCallbackEffect = .none
    var markedTextRemains = false
}

/// Folds a handle-event transaction into one routing decision.
///
/// An editing-command callback means Cocoa declined text ownership, so Neovim
/// gets the original key. A text callback or a true return consumes it. If Cocoa
/// leaves marked text behind after returning false, Escape/Delete apply
/// composition-kind policy; other keys commit first and then route to Neovim.
nonisolated func resolveCocoaEventTransaction(_ transaction: CocoaEventTransaction,
                                              escape: Bool,
                                              deleteKey: Bool = false) -> CocoaEventResult {
    if transaction.callbackEffect == .editingCommand { return .routeToNeovim }
    if transaction.handleEventReturned { return .consume }
    if transaction.callbackEffect == .text { return .consume }
    if !transaction.markedTextRemains { return .routeToNeovim }
    if deleteKey { return .cancelAndConsume }
    return escape ? .commitAndConsume : .commitAndRouteToNeovim
}

/// The upper bound, in bytes, of committed text sent as `nvim_input`; larger
/// commits are pasted instead.
nonisolated let committedTextInputLimit = 4096

/// How committed text should reach Neovim.
nonisolated enum CommittedTextTransport: Sendable, Equatable {
    case none, input, paste
}

/// One committed-text delivery: the transport and the payload it carries.
nonisolated struct CommittedTextOperation: Sendable, Equatable {
    var transport: CommittedTextTransport = .none
    var utf8 = ""
}

/// Routes committed Cocoa text to `nvim_input` or `nvim_paste`. Multiline text
/// and anything longer than the input limit are pasted (unescaped); everything
/// else is escaped key-notation input.
nonisolated func routeCommittedText(_ text: String) -> CommittedTextOperation {
    if text.isEmpty { return CommittedTextOperation() }
    // Scan scalars, not Characters: a CR+LF is one grapheme, so a Character-wise
    // search for "\n"/"\r" would miss it.
    if text.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
        return CommittedTextOperation(transport: .paste, utf8: text)
    }

    let escaped = escapeText(text)
    if escaped.utf8.count > committedTextInputLimit {
        return CommittedTextOperation(transport: .paste, utf8: text)
    }
    return CommittedTextOperation(transport: .input, utf8: escaped)
}
