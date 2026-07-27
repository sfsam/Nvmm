//
//  NvmmTests
//  EditMenuTests.swift
//
//  Coverage for the mode-aware Undo and Redo key sequences.
//

import XCTest
@testable import Nvmm

final class EditMenuTests: XCTestCase {

    func testNormalModesUseNormalCommands() {
        let modes: [NvimMode] = [
            .normal, .normalCtrlIInsert, .normalCtrlIReplace,
            .normalCtrlIVirtualReplace,
        ]

        for mode in modes {
            XCTAssertEqual(undoKeys(for: mode), "u")
            XCTAssertEqual(redoKeys(for: mode), "\u{12}")
        }
    }

    func testInsertAndReplaceModesUseOneNormalCommand() {
        let modes: [NvimMode] = [
            .insert, .insertCompletion, .insertCompletionCtrlX,
            .replace, .replaceCompletion, .replaceCompletionCtrlX,
            .replaceVirtual,
        ]

        for mode in modes {
            XCTAssertEqual(undoKeys(for: mode), "\u{0f}u")
            XCTAssertEqual(redoKeys(for: mode), "\u{0f}\u{12}")
        }
    }

    func testInterruptibleModesCancelBeforeCommand() {
        let modes: [NvimMode] = [
            .commandLine,
            .operatorPending, .operatorPendingForcedChar,
            .operatorPendingForcedLine, .operatorPendingForcedBlock,
            .visualChar, .visualLine, .visualBlock,
            .selectChar, .selectLine, .selectBlock,
        ]

        for mode in modes {
            XCTAssertEqual(undoKeys(for: mode), "\u{03}u")
            XCTAssertEqual(redoKeys(for: mode), "\u{03}\u{12}")
        }
    }

    func testUnsupportedModesProduceNoInput() {
        let modes: [NvimMode] = [
            .cancelled, .timedOut, .unknown,
            .exModeVim, .exMode,
            .promptEnter, .promptMore, .promptConfirm,
            .terminal, .shell,
        ]

        for mode in modes {
            XCTAssertNil(undoKeys(for: mode))
            XCTAssertNil(redoKeys(for: mode))
        }
    }

    func testUndoRedoOutcomeComparesSequencePositions() {
        XCTAssertEqual(
            undoRedoOutcome(before: MPInteger(2), after: MPInteger(1)),
            .changed)
        XCTAssertEqual(
            undoRedoOutcome(before: MPInteger(1), after: MPInteger(2)),
            .changed)
        XCTAssertEqual(
            undoRedoOutcome(before: MPInteger(2), after: MPInteger(2)),
            .boundary)
    }

    func testUndoRedoOutcomeRequiresBothPositions() {
        XCTAssertEqual(
            undoRedoOutcome(before: nil, after: MPInteger(1)),
            .unavailable)
        XCTAssertEqual(
            undoRedoOutcome(before: MPInteger(1), after: nil),
            .unavailable)
    }
}
