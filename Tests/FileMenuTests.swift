//
//  NvmmTests
//  FileMenuTests.swift
//
//  Coverage for the decisions behind the File menu: classifying the mode a
//  command is about to be issued in, and the outcome a save reports. These are
//  the parts that decide whether a command is sent at all, and whether a save
//  panel follows, so they are checked against the shapes Neovim actually
//  replies with.
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

        // A mode this client does not know is `.unknown`, and `.unknown` is
        // busy, so an unrecognized mode refuses commands rather than guessing.
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

    /// A reply names a mode; a timeout or lost connection maps to a busy
    /// state; an RPC error, or a reply without a mode, cannot be trusted as
    /// a mode at all.
    func testParsesModeReplies() {
        let pending = RPCResponse(error: .null,
                                  result: .map([(.string("mode"), .string("no")),
                                                (.string("blocking"), .bool(false))]))
        XCTAssertEqual(parseNvimMode(pending), .operatorPending)

        let insert = RPCResponse(
            error: .null,
            result: .map([(.string("mode"), .string("i"))]))
        XCTAssertEqual(parseNvimMode(RPCRequestResult.response(insert)), .insert)
        XCTAssertEqual(parseNvimMode(RPCRequestResult.timedOut), .timedOut)
        XCTAssertEqual(
            parseNvimMode(RPCRequestResult.transport(.connectionClosed)),
            .cancelled)

        let errored = RPCResponse(error: .array([.int(0), .string("boom")]),
                                  result: .map([(.string("mode"), .string("n"))]))
        XCTAssertEqual(parseNvimMode(errored), .unknown)
        let empty = RPCResponse(error: .null, result: .map([]))
        XCTAssertEqual(parseNvimMode(empty), .unknown)
        let wrongType = RPCResponse(error: .null, result: .string("n"))
        XCTAssertEqual(parseNvimMode(wrongType), .unknown)
    }

    /// The `blocking` flag of an `nvim_get_mode` reply says whether Neovim is
    /// waiting for input, and is read separately from the mode: the reply
    /// still names the underlying mode — Normal, say — and a command issued
    /// while blocked would land there once the block lifts.
    func testParsesBlockingFlagSeparatelyFromMode() {
        let blocked = RPCResponse(error: .null,
                                  result: .map([(.string("mode"), .string("n")),
                                                (.string("blocking"), .bool(true))]))
        XCTAssertTrue(parseBlockedAwaitingInput(.response(blocked)))
        // The mode read is unaffected: gating ordinary commands on the flag
        // would refuse them during Neovim's own bounded waits, such as the
        // `'timeoutlen'` wait after a mapping prefix.
        XCTAssertEqual(parseNvimMode(blocked), .normal)
        XCTAssertFalse(parseNvimMode(blocked).isBusy)

        let unblocked = RPCResponse(error: .null,
                                    result: .map([(.string("mode"), .string("n")),
                                                  (.string("blocking"), .bool(false))]))
        XCTAssertFalse(parseBlockedAwaitingInput(.response(unblocked)))
        XCTAssertEqual(parseNvimMode(unblocked), .normal)

        // A reply proves Neovim is processing requests, so one without a
        // usable flag is not blocked.
        XCTAssertFalse(parseBlockedAwaitingInput(
            .response(RPCResponse(error: .null, result: .map([])))))

        // No answer is not a block. A Neovim too slow to reply, or gone, is
        // not waiting on the user, and refusing on that basis would report
        // input that does not exist.
        XCTAssertFalse(parseBlockedAwaitingInput(.timedOut))
        XCTAssertFalse(
            parseBlockedAwaitingInput(.transport(.connectionClosed)))
    }
}

final class WriteOutcomeTests: XCTestCase {

    func testClassifiesWriteResponses() {
        func failure(_ message: String) -> RPCResponse {
            RPCResponse(error: .array([.int(0), .string(message)]),
                        result: .null)
        }
        let e32 = "Vim(write):E32: No file name"
        let e212 = "Vim(write):E212: Can't open file for writing"
        let fallback = WriteOutcome.failed("Neovim did not complete the save.")

        XCTAssertEqual(classifyWriteResponse(
            RPCResponse(error: .null, result: .null)), .written)
        // E32 means an unnamed buffer, which a save panel can answer.
        XCTAssertEqual(classifyWriteResponse(failure(e32)), .needsFilename)
        XCTAssertEqual(classifyWriteResponse(failure(e212)), .failed(e212))
        // With an explicit path there is no unnamed buffer to name.
        XCTAssertEqual(
            classifyWriteResponse(failure(e32), recognizesUnnamedBuffer: false),
            .failed(e32))
        XCTAssertEqual(classifyWriteResponse(
            RPCResponse(error: .string("bad"), result: .null)), fallback)
        XCTAssertEqual(classifyWriteResponse(nil), fallback)
    }
}
