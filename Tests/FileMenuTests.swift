//
//  NvmmTests
//  FileMenuTests.swift
//
//  Coverage for the decisions behind the File menu: classifying the mode a
//  command is about to be issued in, and parsing the buffer state the save and
//  close prompts act on. These are the parts that decide whether a command is
//  sent at all, and which buffer a prompt is about, so they are checked against
//  the shapes Neovim actually replies with.
//

import XCTest
@testable import Nvmm

final class NvimModeTests: XCTestCase {

    func testShortnamesClassify() {
        XCTAssertEqual(classifyNvimMode("n"), .normal)
        XCTAssertEqual(classifyNvimMode("no"), .operatorPending)
        XCTAssertEqual(classifyNvimMode("no\u{16}"), .operatorPendingForcedBlock)
        XCTAssertEqual(classifyNvimMode("\u{16}"), .visualBlock)
        XCTAssertEqual(classifyNvimMode("\u{13}"), .selectBlock)
        XCTAssertEqual(classifyNvimMode("ce"), .exMode)
        XCTAssertEqual(classifyNvimMode("cv"), .exModeVim)
        XCTAssertEqual(classifyNvimMode("r?"), .promptConfirm)
        XCTAssertEqual(classifyNvimMode("rm"), .promptMore)
        XCTAssertEqual(classifyNvimMode("t"), .terminal)
    }

    /// A mode this client does not know is `.unknown`, and `.unknown` is busy,
    /// so an unrecognized mode refuses commands rather than guessing.
    func testUnknownShortnameIsBusy() {
        XCTAssertEqual(classifyNvimMode("zz"), .unknown)
        XCTAssertTrue(classifyNvimMode("zz").isBusy)
        XCTAssertTrue(NvimMode.timedOut.isBusy)
        XCTAssertTrue(NvimMode.cancelled.isBusy)
        XCTAssertFalse(NvimMode.normal.isBusy)
    }

    /// The predicates the two gates are built from. A command is refused in
    /// exactly the busy, Ex, and prompt modes; a save additionally in a
    /// terminal, and aborts a command line or a pending operator first.
    func testPredicates() {
        XCTAssertTrue(NvimMode.exMode.isExMode)
        XCTAssertTrue(NvimMode.exModeVim.isExMode)
        XCTAssertFalse(NvimMode.commandLine.isExMode)

        XCTAssertTrue(NvimMode.promptEnter.isPrompt)
        XCTAssertTrue(NvimMode.promptMore.isPrompt)
        XCTAssertTrue(NvimMode.promptConfirm.isPrompt)

        XCTAssertTrue(NvimMode.normalCtrlIInsert.isNormal)
        XCTAssertFalse(NvimMode.insert.isNormal)

        XCTAssertTrue(NvimMode.operatorPendingForcedLine.isOperatorPending)
        XCTAssertFalse(NvimMode.normal.isOperatorPending)
    }

    func testParsesGetModeReply() {
        let reply = RPCResponse(error: .null,
                                result: .map([(.string("mode"), .string("no")),
                                              (.string("blocking"), .bool(false))]))
        XCTAssertEqual(parseNvimMode(reply), .operatorPending)
    }

    func testBoundedModeResultsMapFailuresSafely() {
        let reply = RPCResponse(
            error: .null,
            result: .map([(.string("mode"), .string("i"))]))

        XCTAssertEqual(parseNvimMode(RPCSyncResult.response(reply)), .insert)
        XCTAssertEqual(parseNvimMode(RPCSyncResult.timedOut), .timedOut)
        XCTAssertEqual(
            parseNvimMode(RPCSyncResult.transport(.connectionClosed)),
            .cancelled)
    }

    /// An RPC error, or a reply without a mode, cannot be trusted as a mode.
    func testMalformedRepliesAreUnknown() {
        let errored = RPCResponse(error: .array([.int(0), .string("boom")]),
                                  result: .map([(.string("mode"), .string("n"))]))
        XCTAssertEqual(parseNvimMode(errored), .unknown)

        let empty = RPCResponse(error: .null, result: .map([]))
        XCTAssertEqual(parseNvimMode(empty), .unknown)

        let wrongType = RPCResponse(error: .null, result: .string("n"))
        XCTAssertEqual(parseNvimMode(wrongType), .unknown)
    }
}

final class ModifiedBufferTests: XCTestCase {

    /// The close path matches buffers by `changedtick`, not by number: a buffer
    /// the user discarded and then edited again is a different version, and
    /// must be asked about again rather than silently discarded.
    func testChangedtickDistinguishesVersions() {
        let discarded = ModifiedBuffer(bufnr: 2, name: "/tmp/a", changedtick: 7)
        let editedAgain = ModifiedBuffer(bufnr: 2, name: "/tmp/a", changedtick: 9)

        XCTAssertNotEqual(discarded, editedAgain)
        XCTAssertFalse([discarded].contains(editedAgain))
        XCTAssertTrue([discarded].contains(
            ModifiedBuffer(bufnr: 2, name: "/tmp/a", changedtick: 7)))
    }
}

final class WriteOutcomeTests: XCTestCase {

    func testSuccessfulWrite() {
        let response = RPCResponse(error: .null, result: .null)
        XCTAssertEqual(classifyWriteResponse(response), .written)
    }

    func testUnnamedBufferNeedsFilename() {
        let response = RPCResponse(
            error: .array([
                .int(0),
                .string("Vim(write):E32: No file name"),
            ]),
            result: .null)
        XCTAssertEqual(classifyWriteResponse(response), .needsFilename)
    }

    func testWriteFailurePreservesNeovimMessage() {
        let message = "Vim(write):E212: Can't open file for writing"
        let response = RPCResponse(
            error: .array([.int(0), .string(message)]),
            result: .null)
        XCTAssertEqual(classifyWriteResponse(response), .failed(message))
    }

    func testExplicitPathTreatsE32AsFailure() {
        let message = "Vim(write):E32: No file name"
        let response = RPCResponse(
            error: .array([.int(0), .string(message)]),
            result: .null)
        XCTAssertEqual(
            classifyWriteResponse(
                response, recognizesUnnamedBuffer: false),
            .failed(message))
    }

    func testMalformedAndMissingResponsesUseFallback() {
        let fallback = WriteOutcome.failed(
            "Neovim did not complete the save.")
        let malformed = RPCResponse(error: .string("bad"), result: .null)

        XCTAssertEqual(classifyWriteResponse(malformed), fallback)
        XCTAssertEqual(classifyWriteResponse(nil), fallback)
    }
}
