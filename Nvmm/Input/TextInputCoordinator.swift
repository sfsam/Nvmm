//
//  Nvmm
//  TextInputCoordinator.swift
//
//  Owns Cocoa marked-text state and its client-side composition lifecycle.
//
//  `GridView` remains the `NSTextInputClient` and delegates the stateful work
//  here so its rendering and Neovim-input paths stay small. The coordinator
//  holds the marked string, the selection, the session phase, and the session
//  kind (dead key vs. IME), and applies the commit / cancel / suspend / resume
//  transitions. It performs no rendering and issues no RPC; committed text
//  leaves through the delegate. The Escape/Delete/focus policy and the
//  handle-event transaction resolution live in `KeyInput.swift`.
//

import AppKit
import Carbon.HIToolbox
import os

/// Receives text the coordinator commits out of a marked-text session.
@MainActor protocol TextInputCoordinatorDelegate: AnyObject {
    func commitCompositionString(_ text: String)
}

/// Extracts committed text from the object forms Cocoa passes to text input.
func committedString(_ value: Any) -> String? {
    if let string = value as? String { return string }
    if let attributed = value as? NSAttributedString { return attributed.string }
    return nil
}

private let compositionLog = Logger(subsystem: "Nvmm", category: "textinput")

/// Reads the current Carbon input source to classify a marked-text session as a
/// dead-key keyboard layout or a full IME. Captured once per session.
private func currentCompositionKind() -> CompositionKind {
    guard let unmanaged = TISCopyCurrentKeyboardInputSource() else { return .unknown }
    let source = unmanaged.takeRetainedValue()
    guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType)
    else { return .unknown }

    let value = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
    guard CFGetTypeID(value) == CFStringGetTypeID() else { return .unknown }
    let type = value as! CFString
    if CFEqual(type, kTISTypeKeyboardLayout) { return .deadKey }
    if CFEqual(type, kTISTypeKeyboardInputMode) ||
       CFEqual(type, kTISTypeKeyboardInputMethodWithoutModes) ||
       CFEqual(type, kTISTypeKeyboardInputMethodModeEnabled) {
        return .ime
    }
    return .unknown
}

final class TextInputCoordinator {
    private weak var delegate: TextInputCoordinatorDelegate?
    private let kindResolver: @MainActor () -> CompositionKind

    /// The current marked string, or nil when no session is active.
    private(set) var markedText: NSAttributedString?
    private var selection = NSRange(location: NSNotFound, length: 0)
    private var phase: CompositionPhase = .inactive
    /// The session's source kind, fixed when the session starts.
    private(set) var kind: CompositionKind = .unknown

    private var handlingEvent = false
    private var callbackEffect: CocoaCallbackEffect = .none

    init(delegate: TextInputCoordinatorDelegate,
         kindResolver: @escaping @MainActor () -> CompositionKind = currentCompositionKind) {
        self.delegate = delegate
        self.kindResolver = kindResolver
    }

    // The class is main-actor isolated, which would otherwise give it an isolated
    // deinit. A nonisolated deinit avoids the isolated-deinit executor hop that
    // trips a libmalloc double-free under XCTest's post-test memory checker.
    nonisolated deinit {}

    /// True while a marked-text session is active.
    var isActive: Bool { markedText != nil }

    /// True while Neovim's rendered cursor should be hidden behind visible
    /// preedit. Suspended IME sessions keep their state but show the cursor.
    var suppressesNvimCursor: Bool { isActive && phase != .suspended }

    /// True when a Delete should cancel the session before Cocoa sees it.
    func shouldCancelDeleteBeforeCocoa() -> Bool {
        isActive && deleteCancelsBeforeCocoa(kind)
    }

    // MARK: Handle-event transaction

    /// Begins one `handleEvent` transaction. `handleEvent` can synchronously call
    /// back into the text-input methods before it returns; those callbacks and
    /// the return value are treated as one transaction.
    func beginInputContextEvent() {
        handlingEvent = true
        callbackEffect = .none
    }

    /// Ends the transaction and resolves how Neovim should see the key.
    func finishInputContextEvent(handled: Bool, escape: Bool,
                                 deleteKey: Bool) -> CocoaEventResult {
        handlingEvent = false
        let cancelKey = deleteKey || (escape && !deadKeyEscapeCommits(kind))
        let transaction = CocoaEventTransaction(handleEventReturned: handled,
                                                callbackEffect: callbackEffect,
                                                markedTextRemains: isActive)
        return resolveCocoaEventTransaction(transaction,
                                            escape: escape && deadKeyEscapeCommits(kind),
                                            deleteKey: cancelKey)
    }

    private func recordTextCallback() {
        if handlingEvent { callbackEffect = .text }
    }

    private func clearState() {
        markedText = nil
        selection = NSRange(location: NSNotFound, length: 0)
        phase = .inactive
        kind = .unknown
    }

    // MARK: NSTextInputClient callbacks

    func insertText(_ value: Any, replacementRange: NSRange) {
        if phase == .cancelling {
            // discardMarkedText may re-enter with insertText. While cancelling,
            // this callback is Cocoa cleanup rather than a commit to Neovim.
            return clearState()
        }
        guard let text = committedString(value) else { return }
        recordTextCallback()
        logUnsupportedReplacementRange(replacementRange)
        delegate?.commitCompositionString(text)
        clearState()
    }

    func setMarkedText(_ value: Any, selectedRange: NSRange,
                       replacementRange: NSRange) {
        guard let text = committedString(value) else { return }
        recordTextCallback()
        if !isActive {
            // Classify once per marked session. Dead-key and IME sessions use
            // different Escape/Delete/focus policies, and reclassifying
            // mid-session would make those policies unstable.
            kind = kindResolver()
        }

        let inserted = (value as? NSAttributedString)
            .map { NSAttributedString(attributedString: $0) }
            ?? NSAttributedString(string: text)
        var selectionBase = 0
        let current = markedText
        let hasConcreteRange = replacementRange.location != NSNotFound
        let validConcreteRange = hasConcreteRange && current != nil &&
            replacementRange.location <= current!.length &&
            replacementRange.length <= current!.length - replacementRange.location
        if validConcreteRange, let current {
            // Some IMEs patch only a clause of the existing preedit. Cocoa ranges
            // are UTF-16 offsets into the current marked string.
            let updated = NSMutableAttributedString(attributedString: current)
            updated.replaceCharacters(in: replacementRange, with: inserted)
            markedText = updated
            selectionBase = replacementRange.location
        } else {
            // Unsupported or stale concrete ranges cannot be applied safely to
            // buffer text, so replace the whole marked value and log the mismatch.
            if hasConcreteRange &&
                !(current == nil && replacementRange.location == 0 &&
                  replacementRange.length == 0) {
                logInvalidMarkedReplacementRange(replacementRange,
                                                 markedLength: current?.length ?? 0)
            }
            markedText = inserted
        }

        guard let marked = markedText, marked.length > 0 else { return clearState() }
        let relativeLocation = min(selectedRange.location, inserted.length)
        let relativeLength = min(selectedRange.length,
                                 inserted.length - relativeLocation)
        let location = min(selectionBase + relativeLocation, marked.length)
        let length = min(relativeLength, marked.length - location)
        selection = NSRange(location: location, length: length)
        phase = .marked
    }

    func unmarkText() {
        recordTextCallback()
        switch phase {
        case .marked, .suspended: commit()
        case .cancelling: clearState()
        case .inactive: return
        }
    }

    func doCommandBySelector(_ selector: Selector,
                             inputContext: NSTextInputContext?) {
        let deleteCommand =
            selector == #selector(NSStandardKeyBindingResponding.deleteBackward(_:)) ||
            selector == #selector(NSStandardKeyBindingResponding.deleteForward(_:))
        if deleteCommand && isActive {
            if deleteCancelsBeforeCocoa(kind) {
                recordTextCallback()
                cancel(inputContext: inputContext)
            }
            return
        } else if selector == #selector(NSResponder.cancelOperation(_:)) && isActive {
            if deadKeyEscapeCommits(kind) {
                recordTextCallback()
                commit()
            } else {
                recordTextCallback()
                cancel(inputContext: inputContext)
            }
        } else if handlingEvent && callbackEffect == .none {
            callbackEffect = .editingCommand
        }
    }

    // MARK: Lifecycle transitions

    func commit() {
        guard isActive, let text = markedText?.string else { return }
        delegate?.commitCompositionString(text)
        clearState()
    }

    func cancel(inputContext: NSTextInputContext?) {
        guard isActive else { return }
        // discardMarkedText can synchronously call back into this object. Set the
        // phase first so re-entrant insertText/unmarkText callbacks clear state
        // instead of committing the cancelled preedit.
        phase = .cancelling
        inputContext?.discardMarkedText()
        if phase == .cancelling { clearState() }
    }

    /// Commits any active session for an external action (a menu command, a
    /// mouse click) that must take over from the composition.
    func commitForExternalAction(inputContext: NSTextInputContext?) {
        guard isActive else { return }
        commit()
        inputContext?.discardMarkedText()
    }

    func suspendOrCancel(inputContext: NSTextInputContext?) {
        guard isActive else { return }
        // IMEs can preserve a meaningful preedit across app focus changes. Dead
        // keys are layout-local transient state, so losing focus cancels them.
        if !focusLossSuspends(kind) {
            return cancel(inputContext: inputContext)
        }
        phase = .suspended
    }

    func cancelIfInputSourceChanged(inputContext: NSTextInputContext?) {
        guard isActive else { return }
        if kindResolver() != kind { cancel(inputContext: inputContext) }
    }

    func resume(inputContext: NSTextInputContext?) {
        cancelIfInputSourceChanged(inputContext: inputContext)
        if phase == .suspended { phase = .marked }
    }

    // MARK: NSTextInputClient queries

    func hasMarkedText() -> Bool { (markedText?.length ?? 0) > 0 }

    func markedRange() -> NSRange {
        markedText.map { NSRange(location: 0, length: $0.length) }
            ?? NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        markedText != nil ? selection : NSRange(location: 0, length: 0)
    }

    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? {
        if let marked = markedText, range.location != NSNotFound,
           range.location <= marked.length {
            let length = min(range.length, marked.length - range.location)
            let intersection = NSRange(location: range.location, length: length)
            actualRange?.pointee = intersection
            return marked.attributedSubstring(from: intersection)
        }
        actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
        return nil
    }
}

private func logUnsupportedReplacementRange(_ range: NSRange) {
    if range.location == NSNotFound || range == NSRange(location: 0, length: 0) {
        return
    }
    compositionLog.info("""
        Committed text used unsupported replacement range - \
        Location=\(range.location) Length=\(range.length)
        """)
}

private func logInvalidMarkedReplacementRange(_ range: NSRange, markedLength: Int) {
    compositionLog.info("""
        Marked text used invalid replacement range - Location=\(range.location) \
        Length=\(range.length) MarkedLength=\(markedLength)
        """)
}
