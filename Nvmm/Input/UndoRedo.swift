//
//  Nvmm
//  UndoRedo.swift
//
//  Mode-aware Neovim key sequences for the Edit menu's Undo and Redo actions.
//

import Foundation

private nonisolated let controlC = "\u{03}"
private nonisolated let controlO = "\u{0f}"
private nonisolated let controlR = "\u{12}"

/// An Edit menu operation on Neovim's undo tree.
nonisolated enum UndoRedoAction: Sendable {
    case undo
    case redo

    func keys(for mode: NvimMode) -> String? {
        switch self {
        case .undo: undoKeys(for: mode)
        case .redo: redoKeys(for: mode)
        }
    }
}

/// What happened when Neovim attempted an Undo or Redo operation.
nonisolated enum UndoRedoOutcome: Sendable, Equatable {
    case changed
    case boundary
    case unavailable
}

/// Classifies the undo-tree positions surrounding one operation.
nonisolated func undoRedoOutcome(before: MPInteger?, after: MPInteger?
) -> UndoRedoOutcome {
    guard let before, let after else { return .unavailable }
    return before == after ? .boundary : .changed
}

/// The raw key sequence that performs Undo in `mode`, or nil when unavailable.
nonisolated func undoKeys(for mode: NvimMode) -> String? {
    historyKeys(normalKey: "u", mode: mode)
}

/// The raw key sequence that performs Redo in `mode`, or nil when unavailable.
nonisolated func redoKeys(for mode: NvimMode) -> String? {
    historyKeys(normalKey: controlR, mode: mode)
}

private nonisolated func historyKeys(normalKey: String, mode: NvimMode
) -> String? {
    switch mode {
    case .normal, .normalCtrlIInsert, .normalCtrlIReplace,
         .normalCtrlIVirtualReplace:
        normalKey

    case .insert, .insertCompletion, .insertCompletionCtrlX,
         .replace, .replaceCompletion, .replaceCompletionCtrlX,
         .replaceVirtual:
        controlO + normalKey

    case .commandLine, .operatorPending, .operatorPendingForcedChar,
         .operatorPendingForcedLine, .operatorPendingForcedBlock,
         .visualChar, .visualLine, .visualBlock,
         .selectChar, .selectLine, .selectBlock:
        controlC + normalKey

    default:
        nil
    }
}
