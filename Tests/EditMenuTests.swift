//
//  NvmmTests
//  EditMenuTests.swift
//
//  Coverage for the mode-aware Undo and Redo key sequences.
//

import XCTest
@testable import Nvmm

final class EditMenuTests: XCTestCase {

    /// Normal modes undo directly, Insert and Replace modes run one Normal
    /// command with CTRL-O, interruptible modes cancel with CTRL-C first, and
    /// modes that cannot take a command get no input at all.
    func testUndoAndRedoKeysFollowTheMode() {
        let groups: [([NvimMode], String?, String?)] = [
            ([.normal, .normalCtrlIInsert, .normalCtrlIReplace,
              .normalCtrlIVirtualReplace],
             "u", "\u{12}"),
            ([.insert, .insertCompletion, .insertCompletionCtrlX,
              .replace, .replaceCompletion, .replaceCompletionCtrlX,
              .replaceVirtual],
             "\u{0f}u", "\u{0f}\u{12}"),
            ([.commandLine,
              .operatorPending, .operatorPendingForcedChar,
              .operatorPendingForcedLine, .operatorPendingForcedBlock,
              .visualChar, .visualLine, .visualBlock,
              .selectChar, .selectLine, .selectBlock],
             "\u{03}u", "\u{03}\u{12}"),
            ([.cancelled, .timedOut, .unknown,
              .exModeVim, .exMode,
              .promptEnter, .promptMore, .promptConfirm,
              .terminal, .shell],
             nil, nil),
        ]
        for (modes, undo, redo) in groups {
            for mode in modes {
                XCTAssertEqual(undoKeys(for: mode), undo, "\(mode)")
                XCTAssertEqual(redoKeys(for: mode), redo, "\(mode)")
            }
        }
    }

    /// A moved sequence position is a change; an unmoved one is the end of
    /// the undo history; a missing one means the outcome is unknown.
    func testUndoRedoOutcomeComparesSequencePositions() {
        let cases: [(MPInteger?, MPInteger?, UndoRedoOutcome)] = [
            (MPInteger(2), MPInteger(1), .changed),
            (MPInteger(1), MPInteger(2), .changed),
            (MPInteger(2), MPInteger(2), .boundary),
            (nil, MPInteger(1), .unavailable),
            (MPInteger(1), nil, .unavailable),
        ]
        for (before, after, expected) in cases {
            XCTAssertEqual(undoRedoOutcome(before: before, after: after),
                           expected, "\(String(describing: before)) → "
                               + "\(String(describing: after))")
        }
    }
}
