//
//  NvmmTests
//  NeovimProcessTests.swift
//
//  Transport tests. The socketpair-based cases drive the actor deterministically
//  without Neovim: a controlled peer holds the far end and never (or selectively)
//  responds, exercising the timeout, disconnect, and inbound-request paths. The
//  remaining cases run a real bundled Neovim: startup and ginit ordering,
//  blocked-input handling, saving, and undo.
//

import XCTest
import Darwin
@testable import Nvmm

private actor StartupGridProbe {
    private(set) var hasDrawn = false
    private(set) var startupGrid: Grid?

    func record(_ grid: Grid) {
        hasDrawn = true
        if grid.startupComplete { startupGrid = grid }
    }
}

final class NeovimProcessTests: XCTestCase {

    private nonisolated final class StandardErrorSink:
        @unchecked Sendable {
        private let lock = NSLock()
        private var output: StandardErrorCapture.Output?
        let expectation: XCTestExpectation

        init(expectation: XCTestExpectation) {
            self.expectation = expectation
        }

        func receive(_ output: StandardErrorCapture.Output) {
            lock.lock()
            self.output = output
            lock.unlock()
            expectation.fulfill()
        }

        func received() -> StandardErrorCapture.Output? {
            lock.lock()
            defer { lock.unlock() }
            return output
        }
    }

    func testAbnormalNeovimExitDescriptions() {
        XCTAssertNil(abnormalNeovimExitDescription(nil))
        XCTAssertNil(abnormalNeovimExitDescription(.exited(status: 0)))
        XCTAssertEqual(
            abnormalNeovimExitDescription(.exited(status: 7)),
            "Neovim exited with status 7.")
        XCTAssertEqual(
            abnormalNeovimExitDescription(.signaled(signal: SIGKILL)),
            "Neovim was terminated by signal 9.")
        XCTAssertEqual(
            abnormalNeovimExitDescription(.waitFailed(errno: ECHILD)),
            "Nvmm could not determine how Neovim exited (errno \(ECHILD)).")
    }

    func testTransportDisconnectDescriptions() {
        XCTAssertNil(transportDisconnectDescription(
            nil, ownsServer: true, expected: false))
        XCTAssertNil(transportDisconnectDescription(
            .connectionClosed, ownsServer: true, expected: false))
        XCTAssertNil(transportDisconnectDescription(
            .readFailed(errno: EIO), ownsServer: false, expected: true))
        XCTAssertEqual(
            transportDisconnectDescription(
                .readFailed(errno: EIO),
                ownsServer: true,
                expected: false),
            "Communication with Neovim failed: read failed (errno \(EIO)). "
                + "The embedded session ended. Unsaved changes may be "
                + "recoverable from a swap file.")
        XCTAssertEqual(
            transportDisconnectDescription(
                .protocolViolation,
                ownsServer: true,
                expected: false),
            "Nvmm closed the connection because RPC traffic could not be "
                + "processed safely. The embedded session ended. Unsaved "
                + "changes may be recoverable from a swap file.")
        XCTAssertEqual(
            transportDisconnectDescription(
                .connectionClosed,
                ownsServer: false,
                expected: false),
            "The connection to the remote Neovim server closed. "
                + "The server may still be running.")
        XCTAssertEqual(
            transportDisconnectDescription(
                .writeFailed(errno: EPIPE),
                ownsServer: false,
                expected: false),
            "Communication with the remote Neovim server failed: "
                + "write failed (errno \(EPIPE)). "
                + "The server may still be running.")
    }

    func testSpawnCapturesStandardError() async throws {
        let received = expectation(description: "stderr event")
        let sink = StandardErrorSink(expectation: received)
        let process = NeovimProcess { event in
            StandardErrorCapture.log(event)
            sink.receive(event)
        }

        try await process.spawn(
            path: "/bin/sh",
            argv: [
                "/bin/sh", "-c",
                "printf 'shell failure\\n' >&2",
            ])
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(
            sink.received(),
            .init(text: "shell failure", isTruncated: false))
        await process.disconnect()
    }

    func testSpawnReapsChildSignal() async throws {
        let process = NeovimProcess()
        try await process.spawn(
            path: "/bin/sh",
            argv: ["/bin/sh", "-c", "kill -KILL $$"])

        let termination = await process.childTermination()

        XCTAssertEqual(termination, .signaled(signal: SIGKILL))
        await process.disconnect()
    }

    /// The recorded status is read without waiting: nil while the child
    /// runs, and its exit once the reaper has collected it.
    func testRecordedChildTerminationReportsOnlyAReapedExit() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let process = NeovimProcess()
        try await process.spawn(
            path: "/bin/sh",
            argv: ["/bin/sh", "-c",
                   "while [ ! -e " + spawnShellQuoteArg(marker.path)
                    + " ]; do sleep 0.01; done; exit 11"])

        let running = await process.recordedChildTermination()
        XCTAssertNil(running)

        FileManager.default.createFile(atPath: marker.path, contents: nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var termination: Spawn.Termination?
        while ContinuousClock.now < deadline {
            termination = await process.recordedChildTermination()
            if termination != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(termination, .exited(status: 11))
        await process.disconnect()
    }

    func testTerminateChildAllowsGracefulExit() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let process = NeovimProcess()
        let command = "trap 'exit 23' TERM; : > "
            + spawnShellQuoteArg(marker.path)
            + "; while :; do :; done"
        try await process.spawn(
            path: "/bin/sh",
            argv: ["/bin/sh", "-c", command])
        let ready = await waitForFile(marker)
        XCTAssertTrue(ready)

        let termination = await process.terminateChild()

        XCTAssertEqual(termination, .exited(status: 23))
        await process.disconnect()
    }

    func testTerminateChildEscalatesToKill() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let process = NeovimProcess()
        let command = "trap '' TERM; : > "
            + spawnShellQuoteArg(marker.path)
            + "; while :; do :; done"
        try await process.spawn(
            path: "/bin/sh",
            argv: ["/bin/sh", "-c", command])
        let ready = await waitForFile(marker)
        XCTAssertTrue(ready)

        let termination = await process.terminateChild(
            gracePeriod: .milliseconds(50))

        XCTAssertEqual(termination, .signaled(signal: SIGKILL))
        await process.disconnect()
    }

    func testTerminateChildReturnsRecordedExit() async throws {
        let process = NeovimProcess()
        try await process.spawn(
            path: "/bin/sh",
            argv: ["/bin/sh", "-c", "exit 9"])
        let recorded = await process.childTermination()

        let termination = await process.terminateChild()

        XCTAssertEqual(recorded, .exited(status: 9))
        XCTAssertEqual(termination, recorded)
        await process.disconnect()
    }

    func testTerminateChildDoesNotAffectRemoteConnection() async throws {
        let pair = try makeSocketPair()
        defer { close(pair.peer) }
        let process = NeovimProcess()
        await process.attach(readFD: pair.client, writeFD: pair.client)

        let termination = await process.terminateChild(
            gracePeriod: .milliseconds(1))

        XCTAssertNil(termination)
        await process.disconnect()
    }

    // MARK: Controlled-peer helpers

    private func waitForFile(
        _ url: URL,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// A connected socket pair: the client end is handed to the process, the peer
    /// end is driven by the test. The peer has a receive timeout so a missing
    /// response fails the test instead of hanging it.
    private func makeSocketPair() throws -> (client: Int32, peer: Int32) {
        var fds = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw NeovimTestError() }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fds[1], SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        return (fds[0], fds[1])
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count <= 0 { throw NeovimTestError() }
                offset += count
            }
        }
    }

    private func writeResponse(
        _ fd: Int32, id: UInt64, error: MPValue = .null,
        result: MPValue = .null
    ) throws {
        var writer = MessagePackWriter()
        writer.encodeResponse(id: id, error: error, result: result)
        try writeAll(fd, writer.bytes)
    }

    /// Reads one complete MessagePack value from a blocking descriptor.
    private func readMessage(_ fd: Int32) throws -> MPValue {
        var unpacker = MessagePackUnpacker()
        return try readMessage(fd, unpacker: &unpacker)
    }

    /// Reads one value while retaining any later values from the same read.
    private func readMessage(
        _ fd: Int32, unpacker: inout MessagePackUnpacker
    ) throws -> MPValue {
        var buffer = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<1_024 {
            if let value = unpacker.unpack() { return value }
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            unpacker.feed(buffer[0..<count])
        }
        throw NeovimTestError()
    }

    private func readRequest(
        _ fd: Int32, method: String,
        arguments expectedArguments: [MPValue]? = nil,
        unpacker: inout MessagePackUnpacker
    ) throws -> UInt64 {
        let message = try readMessage(fd, unpacker: &unpacker)
        guard let values = message.arrayValue, values.count == 4,
              values[0].integer?.unsigned == 0,
              let id = values[1].integer?.unsigned,
              values[2].stringValue == method,
              let arguments = values[3].arrayValue else {
            XCTFail("expected request for \(method), got \(message)")
            throw NeovimTestError()
        }
        if let expectedArguments, arguments != expectedArguments {
            XCTFail("unexpected arguments for \(method): \(arguments)")
            throw NeovimTestError()
        }
        return id
    }

    private func compatibleAPIMetadata() -> MPValue {
        let functions = [
            "nvim_set_client_info", "nvim_ui_attach", "nvim_exec_lua",
            "nvim_call_function",
        ].map { MPValue.map([(.string("name"), .string($0))]) }
        let version: MPValue = .map([
            (.string("major"), .int(0)),
            (.string("minor"), .int(12)),
            (.string("patch"), .int(0)),
        ])
        let info: MPValue = .map([
            (.string("version"), version),
            (.string("functions"), .array(functions)),
            (.string("ui_options"), .array([.string("ext_linegrid")])),
        ])
        return .array([.int(1), info])
    }

    private func answerAttachThroughRecentFiles(
        _ fd: Int32, unpacker: inout MessagePackUnpacker
    ) throws {
        var id = try readRequest(
            fd, method: "nvim_get_api_info", unpacker: &unpacker)
        try writeResponse(fd, id: id, result: compatibleAPIMetadata())

        id = try readRequest(
            fd, method: "nvim_set_client_info", unpacker: &unpacker)
        try writeResponse(fd, id: id)

        id = try readRequest(
            fd, method: "nvim_exec_lua", unpacker: &unpacker)
        try writeResponse(fd, id: id)
    }

    private func answerAttachPreamble(
        _ fd: Int32, unpacker: inout MessagePackUnpacker
    ) throws {
        try answerAttachThroughRecentFiles(fd, unpacker: &unpacker)

        var id = try readRequest(
            fd, method: "nvim_exec_lua", unpacker: &unpacker)
        try writeResponse(fd, id: id)

        id = try readRequest(
            fd, method: "nvim_ui_attach", unpacker: &unpacker)
        try writeResponse(fd, id: id)
    }

    private func bufferedProgressUpdate(
        _ updates: [ProgressUpdate]
    ) async -> ProgressUpdate? {
        let pair = AsyncStream.makeStream(
            of: ProgressUpdate.self,
            bufferingPolicy: .bufferingNewest(1))
        for update in updates {
            publishProgressUpdate(update, to: pair.continuation)
        }
        pair.continuation.finish()
        var iterator = pair.stream.makeAsyncIterator()
        return await iterator.next()
    }

    // MARK: Controlled-peer cases

    func testSetGlobalOptionUsesOptionAPI() async throws {
        let pair = try makeSocketPair()
        defer { close(pair.peer) }
        let process = NeovimProcess()
        await process.attach(readFD: pair.client, writeFD: pair.client)

        await process.perform(.setGlobalOption(
            name: "guifont", value: "Menlo-Regular:h13"))

        let message = try readMessage(pair.peer)
        let options: MPValue = .map([
            (.string("scope"), .string("global")),
        ])
        XCTAssertEqual(message, .array([
            .int(2), .string("nvim_set_option_value"),
            .array([
                .string("guifont"), .string("Menlo-Regular:h13"), options,
            ]),
        ]))
        await process.disconnect()
    }

    /// A write is not sent to a Neovim blocked awaiting input. Sent, it
    /// would be answered after its deadline, and an error it raised — E32
    /// for an unnamed buffer, which the save panel exists to answer — would
    /// arrive in a reply no longer being read, failing invisibly.
    ///
    /// A block with no keys pending is not a mapping pause, so nothing is
    /// typed into it either — nor when the pause query itself fails, as on
    /// a Neovim without it.
    func testWriteIsNotSentWhileBlockedAwaitingInput() async throws {
        let replies: [(result: MPValue, error: MPValue)] = [
            (.string(""), .null),
            (.null, .array([.int(0), .string("Invalid method")])),
        ]
        for reply in replies {
            let pair = try makeSocketPair()
            defer { close(pair.peer) }
            let process = NeovimProcess()
            await process.attach(readFD: pair.client, writeFD: pair.client)

            let write = Task { await process.writeBuffer(3) }

            var unpacker = MessagePackUnpacker()
            let probeID = try readRequest(pair.peer, method: "nvim_get_mode",
                                          unpacker: &unpacker)
            try writeResponse(
                pair.peer, id: probeID,
                result: .map([(.string("mode"), .string("n")),
                              (.string("blocking"), .bool(true))]))
            let pauseID = try readRequest(
                pair.peer, method: "nvim__exec_lua_fast",
                arguments: [.string("return vim.fn.state('m')"), .array([])],
                unpacker: &unpacker)
            try writeResponse(pair.peer, id: pauseID, error: reply.error,
                              result: reply.result)

            let outcome = await write.value
            XCTAssertEqual(outcome, .awaitingInput)
            // Nothing followed the probes: no `<Ignore>`, and no `:write`
            // left to fail unseen.
            XCTAssertThrowsError(
                try readMessage(pair.peer, unpacker: &unpacker))
            await process.disconnect()
        }
    }

    func testNewDocumentTypesItsCommand() async throws {
        let cases = [(true, "<Esc><C-\\><C-N>:hide enew<CR>"),
                     (false, "<Esc><C-\\><C-N>:tabnew<CR>")]
        for (inBuffers, expectedKeys) in cases {
            let pair = try makeSocketPair()
            defer { close(pair.peer) }
            let process = NeovimProcess()
            await process.attach(readFD: pair.client, writeFD: pair.client)

            await process.newDocument(inBuffers: inBuffers)

            var unpacker = MessagePackUnpacker()
            let message = try readMessage(pair.peer, unpacker: &unpacker)
            guard let values = message.arrayValue, values.count == 3,
                  values[0].integer?.unsigned == 2,
                  values[1].stringValue == "nvim_input",
                  let arguments = values[2].arrayValue, arguments.count == 1
            else {
                return XCTFail("expected an nvim_input notification: \(message)")
            }
            // The mode is never queried: the keys leave any pending state
            // themselves, which is what makes this work while Neovim is blocked.
            XCTAssertEqual(arguments[0].stringValue, expectedKeys)
            await process.disconnect()
        }
    }

    /// An empty address, an error reply, and a dropped connection all mean
    /// there is no address to report.
    func testServerAddressIsNilWithoutAUsableReply() async throws {
        enum Reply: CaseIterable { case empty, error, dropped }
        for reply in Reply.allCases {
            let pair = try makeSocketPair()
            var peerOpen = true
            defer { if peerOpen { close(pair.peer) } }
            let process = NeovimProcess()
            await process.attach(readFD: pair.client, writeFD: pair.client)

            let address = Task { await process.serverAddress() }
            var unpacker = MessagePackUnpacker()
            let id = try readRequest(
                pair.peer, method: "nvim_eval",
                arguments: [.string("v:servername")], unpacker: &unpacker)
            switch reply {
            case .empty:
                try writeResponse(pair.peer, id: id, result: .string(""))
            case .error:
                try writeResponse(
                    pair.peer, id: id,
                    error: .array([.int(0), .string("evaluation failed")]))
            case .dropped:
                close(pair.peer)
                peerOpen = false
            }

            let result = await address.value
            XCTAssertNil(result, "\(reply)")
            await process.disconnect()
        }
    }

    /// How far the peer answers the attach sequence before it stops.
    private enum AttachPhase: String {
        case startup, documentState, progress

        /// Answers every request that precedes the phase's own request.
        func answerPrelude(
            _ test: NeovimProcessTests, _ fd: Int32,
            _ unpacker: inout MessagePackUnpacker
        ) throws {
            switch self {
            case .startup:
                try test.answerAttachThroughRecentFiles(fd, unpacker: &unpacker)
            case .documentState:
                try test.answerAttachPreamble(fd, unpacker: &unpacker)
            case .progress:
                try test.answerAttachPreamble(fd, unpacker: &unpacker)
                let id = try test.readRequest(
                    fd, method: "nvim_exec_lua", unpacker: &unpacker)
                try test.writeResponse(fd, id: id)
            }
        }
    }

    /// Drives an attach to `phase`, then either rejects the phase's Lua
    /// request with `error` or, with no error, never answers it.
    private func attach(
        stoppingAt phase: AttachPhase, error: MPValue? = nil
    ) async throws -> UIAttachResult {
        let pair = try makeSocketPair()
        defer { close(pair.peer) }
        let process = NeovimProcess()
        await process.attach(readFD: pair.client, writeFD: pair.client)
        var options = UIOptions()
        options.extLinegrid = true

        let attach = Task {
            await process.uiAttach(
                width: 80, height: 24, options: options,
                timeout: .seconds(1))
        }
        var unpacker = MessagePackUnpacker()
        try phase.answerPrelude(self, pair.peer, &unpacker)
        let id = try readRequest(
            pair.peer, method: "nvim_exec_lua", unpacker: &unpacker)
        if let error { try writeResponse(pair.peer, id: id, error: error) }

        let result = await attach.value
        await process.disconnect()
        return result
    }

    func testUIAttachReportsWhichSetupPhaseWasRejected() async throws {
        let setupError = MPValue.string("setup failed")
        for (phase, message) in [
            (AttachPhase.startup, "Startup setup was rejected by Neovim"),
            (.progress, "Progress setup was rejected by Neovim"),
        ] {
            let result = try await attach(stoppingAt: phase, error: setupError)
            XCTAssertEqual(result.status, .rpcError, phase.rawValue)
            XCTAssertEqual(result.message, message)
            XCTAssertEqual(result.rpcError, setupError, phase.rawValue)
        }
    }

    func testUIAttachReportsWhichSetupPhaseTimedOut() async throws {
        for (phase, message) in [
            (AttachPhase.startup, "Startup setup timed out"),
            (.documentState, "Document-state setup timed out"),
        ] {
            let result = try await attach(stoppingAt: phase)
            XCTAssertEqual(result.status, .timedOut, phase.rawValue)
            XCTAssertEqual(result.message, message)
        }
    }

    /// The progress stream holds one update. A completion is never displaced
    /// by a later state update, and otherwise the newest update wins.
    func testProgressBufferKeepsCompletionsOverStateUpdates() async {
        let state25 = ProgressUpdate(percent: 25, isCompletion: false)
        let state50 = ProgressUpdate(percent: 50, isCompletion: false)
        let done75 = ProgressUpdate(percent: 75, isCompletion: true)
        let done100 = ProgressUpdate(percent: 100, isCompletion: true)
        let cases: [([ProgressUpdate], ProgressUpdate)] = [
            ([done100, state25], done100),
            ([state25, done100], done100),
            ([state25, state50], state50),
            ([done75, done100], done100),
        ]
        for (updates, expected) in cases {
            let received = await bufferedProgressUpdate(updates)
            XCTAssertEqual(received, expected, "\(updates)")
        }

        // Publishing into a finished stream is ignored.
        let pair = AsyncStream.makeStream(
            of: ProgressUpdate.self,
            bufferingPolicy: .bufferingNewest(1))
        pair.continuation.finish()
        publishProgressUpdate(done100, to: pair.continuation)
        var iterator = pair.stream.makeAsyncIterator()
        let received = await iterator.next()
        XCTAssertNil(received)
    }

    func testPasteChunksPreserveUnicodeAtByteBoundaries() {
        let text = "ab🙂cdéfg"
        let chunks = pasteChunks(text, maximumBytes: 5)

        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 5 })
        XCTAssertEqual(pasteChunks("", maximumBytes: 4), [""])
    }

    /// A paste into a Neovim blocked awaiting input is refused rather than
    /// sent: `nvim_paste` is deferred while blocked, and awaiting it in the
    /// serialized command consumer would park every later keystroke behind
    /// it — including the Esc that cancels the block. The refusal is
    /// reported, so the clipboard does not vanish without a sign.
    func testPasteIsRefusedWhileNeovimIsBlocked() async throws {
        let (client, peer) = try makeSocketPair()
        defer { close(peer) }
        let process = NeovimProcess()
        await process.attach(readFD: client, writeFD: client)

        let refused = expectation(description: "the paste was reported")
        let paste = Task {
            await process.perform(
                .paste("hello", refused: { refused.fulfill() }))
        }

        var unpacker = MessagePackUnpacker()
        let probeID = try readRequest(peer, method: "nvim_get_mode",
                                      unpacker: &unpacker)
        try writeResponse(
            peer, id: probeID,
            result: .map([(.string("mode"), .string("n")),
                          (.string("blocking"), .bool(true))]))
        // No keys are pending, so this is a wait on the user, not a pause.
        let pauseID = try readRequest(peer, method: "nvim__exec_lua_fast",
                                      unpacker: &unpacker)
        try writeResponse(peer, id: pauseID, result: .string(""))

        await fulfillment(of: [refused], timeout: 2)
        await paste.value
        // Nothing followed the probes: no chunk reached the blocked editor.
        XCTAssertThrowsError(try readMessage(peer, unpacker: &unpacker))
    }

    /// A chunk that goes unanswered abandons the paste, but the chunks
    /// already sent still run whenever Neovim reaches them. An empty final
    /// chunk closes the stream, so the dot-repeat register is finished and a
    /// terminal buffer leaves streamed-paste mode.
    func testAbandonedPasteTerminatesTheStream() async throws {
        let (client, peer) = try makeSocketPair()
        defer { close(peer) }
        // The abandoned chunk is bounded at two seconds; wait past that.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        let process = NeovimProcess()
        await process.attach(readFD: client, writeFD: client)

        let text = String(repeating: "a", count: nvimPasteChunkBytes + 1)
        let paste = Task { await process.perform(.paste(text, refused: {})) }

        var unpacker = MessagePackUnpacker()
        let probeID = try readRequest(peer, method: "nvim_get_mode",
                                      unpacker: &unpacker)
        try writeResponse(
            peer, id: probeID,
            result: .map([(.string("mode"), .string("n")),
                          (.string("blocking"), .bool(false))]))

        // Read the opening chunk and never answer it.
        _ = try readRequest(peer, method: "nvim_paste", unpacker: &unpacker)

        let message = try readMessage(peer, unpacker: &unpacker)
        guard let values = message.arrayValue, values.count == 3,
              values[0].integer?.unsigned == 2,
              values[1].stringValue == "nvim_paste",
              let arguments = values[2].arrayValue, arguments.count == 3
        else {
            return XCTFail("expected a terminating notification: \(message)")
        }
        XCTAssertEqual(arguments[0].stringValue, "")
        XCTAssertEqual(arguments[2].integer?.signed, 3)
        await paste.value
    }

    func testLargePasteUsesSequentialRequests() async throws {
        let (client, peer) = try makeSocketPair()
        defer { close(peer) }
        let process = NeovimProcess()
        await process.attach(readFD: client, writeFD: client)
        let queueLimit =
            RPCResourceLimits.production.maximumOutboundQueuedBytes
        let text = String(repeating: "🙂", count: (queueLimit / 4) + 1)
        XCTAssertGreaterThan(text.utf8.count, queueLimit)
        let chunkCount =
            (text.utf8.count + nvimPasteChunkBytes - 1)
            / nvimPasteChunkBytes

        let paste = Task { await process.perform(.paste(text, refused: {})) }

        // The paste probes the input-block state first; answer it so the
        // chunked nvim_paste requests proceed.
        let probe = try readMessage(peer)
        guard case .array(let probeValues) = probe, probeValues.count == 4,
              let probeID = probeValues[1].integer?.unsigned,
              probeValues[2].stringValue == "nvim_get_mode"
        else {
            return XCTFail("expected a leading nvim_get_mode probe: \(probe)")
        }
        var probeReply = MessagePackWriter()
        probeReply.encodeResponse(
            id: probeID, error: .null,
            result: .map([(.string("mode"), .string("n")),
                          (.string("blocking"), .bool(false))]))
        try writeAll(peer, probeReply.bytes)

        var received: [String] = []
        var phases: [Int64] = []
        for _ in 0..<chunkCount {
            let message = try readMessage(peer)
            guard case .array(let values) = message, values.count == 4,
                  let id = values[1].integer?.unsigned,
                  values[2].stringValue == "nvim_paste",
                  let arguments = values[3].arrayValue,
                  let chunk = arguments[0].stringValue,
                  let phase = arguments[2].integer?.signed
            else {
                return XCTFail("invalid nvim_paste request: \(message)")
            }
            received.append(chunk)
            phases.append(phase)

            var response = MessagePackWriter()
            response.encodeResponse(id: id, error: .null, result: true)
            try writeAll(peer, response.bytes)
        }
        await paste.value

        XCTAssertEqual(received.joined(), text)
        XCTAssertEqual(phases.count, 17)
        XCTAssertEqual(phases.first, 1)
        XCTAssertEqual(phases.last, 3)
        XCTAssertTrue(phases.dropFirst().dropLast().allSatisfy { $0 == 2 })
        await process.disconnect()
    }

    func testAsyncRequestFailsWhenPeerCloses() async throws {
        let (client, peer) = try makeSocketPair()
        let process = NeovimProcess()
        await process.attach(readFD: client, writeFD: client)

        let request = Task { try await process.request("nvim_get_mode") }
        try? await Task.sleep(for: .milliseconds(50))
        close(peer) // EOF on the client's read end

        do {
            _ = try await request.value
            XCTFail("expected a transport error")
        } catch let error as RPCError {
            guard case .transport = error else {
                return XCTFail("expected .transport, got \(error)")
            }
        }
        let termination = await process.transportTermination()
        XCTAssertEqual(termination, .connectionClosed)
        await process.disconnect()
    }

    /// A disconnect fails the request waiting on it, and every request
    /// made after it.
    func testDisconnectFailsPendingAndLaterRequests() async throws {
        let (client, peer) = try makeSocketPair()
        defer { close(peer) }
        let process = NeovimProcess()
        await process.attach(readFD: client, writeFD: client)

        let request = Task { try await process.request("nvim_get_mode") }
        try? await Task.sleep(for: .milliseconds(50))
        await process.disconnect()

        do {
            _ = try await request.value
            XCTFail("expected a transport error")
        } catch let error as RPCError {
            guard case .transport(.connectionClosed) = error else {
                return XCTFail("expected .connectionClosed, got \(error)")
            }
        }

        try? await Task.sleep(for: .milliseconds(50)) // let the shutdown propagate
        do {
            _ = try await process.request("nvim_get_mode")
            XCTFail("expected a transport error")
        } catch let error as RPCError {
            guard case .transport = error else {
                return XCTFail("expected .transport, got \(error)")
            }
        }
    }

    func testIncomingRequestIsRejected() async throws {
        let (client, peer) = try makeSocketPair()
        defer { close(peer) }
        let process = NeovimProcess()
        await process.attach(readFD: client, writeFD: client)

        var writer = MessagePackWriter()
        writer.encodeRequest(id: 7, method: "does_not_exist", arguments: [])
        try writeAll(peer, writer.bytes)

        let response = try readMessage(peer)
        await process.disconnect()

        guard case .array(let fields) = response, fields.count == 4 else {
            return XCTFail("expected a 4-element response array, got \(response)")
        }
        XCTAssertEqual(fields[0].integer?.unsigned, 1) // response envelope
        XCTAssertEqual(fields[1].integer?.unsigned, 7) // matching id
        XCTAssertFalse(fields[2].isNull)               // error is present
        XCTAssertTrue(fields[3].isNull)                // no result
    }

    func testInboundCreditResumesAFragmentedMessage() async throws {
        let (client, peer) = try makeSocketPair()
        defer { close(peer) }
        var limits = RPCResourceLimits.production
        limits.maximumInboundQueuedBytes = 32
        limits.inboundResumeBytes = 16
        let process = NeovimProcess(limits: limits)
        await process.attach(readFD: client, writeFD: client)

        var writer = MessagePackWriter()
        writer.encodeRequest(
            id: 9, method: String(repeating: "x", count: 100), arguments: [])
        try writeAll(peer, writer.bytes)

        let response = try readMessage(peer)
        await process.disconnect()
        XCTAssertEqual(response.arrayValue?[1].integer?.unsigned, 9)
    }

    func testDecoderLimitClosesTheConnection() async throws {
        let (client, peer) = try makeSocketPair()
        defer { close(peer) }
        var limits = RPCResourceLimits.production
        limits.maximumStringBytes = 3
        let process = NeovimProcess(limits: limits)
        await process.attach(readFD: client, writeFD: client)

        try writeAll(peer, [0xd9, 0x04])
        var byte: UInt8 = 0
        XCTAssertEqual(read(peer, &byte, 1), 0)
        for await _ in process.grids {}
        let termination = await process.transportTermination()
        XCTAssertEqual(termination, .protocolViolation)
    }

    func testOutboundLimitClosesInsteadOfQueueingAResponse() async throws {
        let (client, peer) = try makeSocketPair()
        defer { close(peer) }
        var limits = RPCResourceLimits.production
        limits.maximumOutboundQueuedBytes = 1
        let process = NeovimProcess(limits: limits)
        await process.attach(readFD: client, writeFD: client)

        var writer = MessagePackWriter()
        writer.encodeRequest(id: 10, method: "unknown", arguments: [])
        try writeAll(peer, writer.bytes)

        var byte: UInt8 = 0
        XCTAssertEqual(read(peer, &byte, 1), 0)
    }

    func testReverseRequestConcurrencyLimitClosesConnection() async throws {
        let (client, peer) = try makeSocketPair()
        defer { close(peer) }
        var limits = RPCResourceLimits.production
        limits.maximumReverseRequests = 1
        let process = NeovimProcess(limits: limits)
        await process.attach(readFD: client, writeFD: client)
        await process.registerRequestHandler("slow") { _ in
            try? await Task.sleep(for: .milliseconds(200))
            return .result(.null)
        }

        var writer = MessagePackWriter()
        writer.encodeRequest(id: 11, method: "slow", arguments: [])
        writer.encodeRequest(id: 12, method: "slow", arguments: [])
        try writeAll(peer, writer.bytes)

        var byte: UInt8 = 0
        XCTAssertEqual(read(peer, &byte, 1), 0)
    }

    // MARK: Real-Neovim cases

    func testUIAttachCompletesRequiredLuaSetup() async throws {
        try await withNvim { process in
            try await attachLinegridUI(process)
            let lua = """
                local helpers = type(_G.nvmm) == 'table'
                  and type(_G.nvmm.open_tabs) == 'function'
                  and type(_G.nvmm.open_buffers) == 'function'
                  and type(_G.nvmm.open_count) == 'function'
                  and type(_G.nvmm.write_as) == 'function'
                  and type(_G.nvmm.drop_text) == 'function'
                local document_state = #vim.api.nvim_get_autocmds(
                  {group='NvmmDocumentState'}) > 0
                local progress = vim.fn.exists('##Progress') ~= 1
                  or #vim.api.nvim_get_autocmds({group='NvmmProgress'}) > 0
                local recent = #vim.api.nvim_get_autocmds(
                  {group='NvmmRecentFiles'}) == 2
                local background = #vim.api.nvim_get_autocmds(
                  {event='OptionSet', pattern='background'}) > 0
                return {helpers, document_state, progress, recent, background}
                """
            let response = try await process.request(
                "nvim_exec_lua", [.string(lua), .array([])])

            XCTAssertFalse(response.isError)
            XCTAssertEqual(response.result.arrayValue,
                           [.bool(true), .bool(true), .bool(true), .bool(true),
                            .bool(true)])
        }
    }

    func testBackgroundOptionIsPublishedWithoutBeingSet() async throws {
        try await withNvim { process in
            let initial = Task {
                var values = process.backgroundOptions.makeAsyncIterator()
                return await values.next()
            }
            try await attachLinegridUI(process)
            let initialValue = await initial.value
            XCTAssertEqual(initialValue, .dark)

            let changed = Task<NeovimBackgroundOption?, Never> {
                for await value in process.backgroundOptions where value == .light {
                    return value
                }
                return nil
            }
            let lua = """
                vim.api.nvim_create_autocmd('User', {
                  pattern='NvmmTestBackground', once=true,
                  callback=function() vim.o.background='light' end,
                })
                vim.api.nvim_exec_autocmds('User', {
                  pattern='NvmmTestBackground'})
                """
            let response = try await process.request(
                "nvim_exec_lua", [.string(lua), .array([])])
            XCTAssertFalse(response.isError)
            let changedValue = await changed.value
            XCTAssertEqual(changedValue, .light)
        }
    }

    func testInitLuaErrorCanBeAnsweredDuringUISetup() async throws {
        try await withConfiguredNvim(
            initLua: "\n\n\n\n\n\n\n\n#", ginitVim: nil
        ) { process in
            var options = UIOptions()
            options.extLinegrid = true
            let errorGrid = Task {
                await awaitGrid(
                    process.grids,
                    containing: ["E5112", "init.lua", ":9"])
            }
            let attach = Task {
                await process.uiAttach(
                    width: 80, height: 24, options: options,
                    timeout: .seconds(1))
            }

            let renderedError = await errorGrid.value
            try await Task.sleep(for: .milliseconds(1_100))
            let blocked = await process.isBlockedAwaitingInput()
            XCTAssertNotNil(renderedError)
            XCTAssertTrue(blocked)
            await process.perform(.input("<CR>"))

            let result = await attach.value
            XCTAssertEqual(result.status, .success)
            await process.activateGUIStartup()
            let ready = await awaitStartupGrid(process.grids)
            XCTAssertNotNil(ready)
        }
    }

    func testRemoteUIEnterPromptCanOutlastAttachDeadline() async throws {
        try await withListeningNvim(ginitVim: "") { server in
            let process = NeovimProcess()
            try await process.connect(server.socket)
            let hook = """
                vim.api.nvim_create_autocmd('UIEnter', {once=true,
                  callback=function()
                    vim.fn.input('remote-uienter-marker: ')
                  end})
                """
            let response = try await process.request(
                "nvim_exec_lua", [.string(hook), .array([])])
            XCTAssertFalse(response.isError)

            var options = UIOptions()
            options.extLinegrid = true
            let promptGrid = Task {
                await awaitGrid(
                    process.grids,
                    containing: ["remote-uienter-marker"])
            }
            let attach = Task {
                await process.uiAttach(
                    width: 80, height: 24, options: options,
                    timeout: .seconds(1))
            }

            let renderedPrompt = await promptGrid.value
            XCTAssertNotNil(renderedPrompt)
            try await Task.sleep(for: .milliseconds(1_100))
            let promptPending = await process.hasPendingStartupPrompt()
            XCTAssertTrue(promptPending)
            await process.perform(.input("answer<CR>"))

            let result = await attach.value
            XCTAssertEqual(result.status, .success)
            let promptFinished = await process.hasPendingStartupPrompt()
            XCTAssertFalse(promptFinished)
            await process.activateGUIStartup()
            let ready = await awaitStartupGrid(process.grids)
            XCTAssertNotNil(ready)
            await process.disconnect()
        }
    }

    func testRemoteSlowUIEnterStillTimesOut() async throws {
        try await withListeningNvim(ginitVim: "") { server in
            let process = NeovimProcess()
            try await process.connect(server.socket)
            let hook = """
                vim.api.nvim_create_autocmd('UIEnter', {once=true,
                  callback=function()
                    vim.wait(1500)
                  end})
                """
            let response = try await process.request(
                "nvim_exec_lua", [.string(hook), .array([])])
            XCTAssertFalse(response.isError)

            var options = UIOptions()
            options.extLinegrid = true
            let result = await process.uiAttach(
                width: 80, height: 24, options: options,
                timeout: .milliseconds(500))

            XCTAssertEqual(result.status, .timedOut)
            XCTAssertEqual(result.message, "UI attachment timed out")
            let promptPending = await process.hasPendingStartupPrompt()
            XCTAssertFalse(promptPending)
            await process.disconnect()
        }
    }

    func testGinitRunsAfterInitAndCommandAndSetsGuifont() async throws {
        let initLua = """
            vim.g.nvmm_startup_order = 'init'
            vim.api.nvim_create_autocmd('VimEnter', {callback=function()
              vim.g.nvmm_startup_order = vim.g.nvmm_startup_order .. ',vimenter'
            end})
            vim.api.nvim_create_autocmd('UIEnter', {callback=function()
              vim.g.nvmm_startup_order = vim.g.nvmm_startup_order .. ',uienter'
            end})
            """
        let ginitVim = """
            let g:nvmm_startup_order .= ',ginit'
            let g:nvmm_ginit_count = get(g:, 'nvmm_ginit_count', 0) + 1
            set guifont=NvmmTestFont:h17
            """
        let command = "let g:nvmm_startup_order .= ',command'"

        try await withConfiguredNvim(
            initLua: initLua, ginitVim: ginitVim,
            arguments: ["-c", command]
        ) { process in
            try await attachLinegridUI(process)
            await process.activateGUIStartup()
            let ready = await awaitStartupGrid(process.grids)
            let finished = await waitUntilTrue(
                process, "get(g:, 'nvmm_ginit_count', 0) == 1")
            XCTAssertTrue(finished)
            XCTAssertEqual(ready?.guifont, "NvmmTestFont:h17")

            let order = try await process.request(
                "nvim_eval", [.string("g:nvmm_startup_order")])
            let font = try await process.request(
                "nvim_get_option_value",
                [.string("guifont"), .map([])])
            XCTAssertEqual(
                order.result.stringValue,
                "init,command,vimenter,uienter,ginit")
            XCTAssertEqual(font.result.stringValue, "NvmmTestFont:h17")
        }
    }

    func testOSAppearanceIsPublishedBeforeGinitAndOnChanges() async throws {
        let initLua = """
            vim.g.nvmm_appearance_changes = 0
            vim.api.nvim_create_autocmd('User', {
              pattern = 'NvmmOSAppearanceChanged',
              callback = function()
                vim.g.nvmm_appearance_changes =
                  vim.g.nvmm_appearance_changes + 1
              end,
            })
            """
        let ginitVim = """
            let g:nvmm_ginit_appearance = g:nvmm_os_appearance
            """

        try await withConfiguredNvim(
            initLua: initLua, ginitVim: ginitVim
        ) { process in
            var options = UIOptions()
            options.extLinegrid = true
            let result = await process.uiAttach(
                width: 80, height: 24, options: options)
            XCTAssertEqual(result.status, .success)

            await process.publishOSAppearance(.dark)
            await process.publishOSAppearance(.dark)
            await process.activateGUIStartup()
            let finished = await waitUntilTrue(process, "v:vim_did_enter")
            XCTAssertTrue(finished)

            var response = try await process.request(
                "nvim_eval",
                [.string("[g:nvmm_ginit_appearance, "
                         + "g:nvmm_appearance_changes]")])
            XCTAssertEqual(response.result.arrayValue, [.int(1), .int(1)])

            await process.perform(.osAppearance(.highContrastDark))
            response = try await process.request(
                "nvim_eval",
                [.string("[g:nvmm_os_appearance, "
                         + "g:nvmm_appearance_changes]")])
            XCTAssertEqual(response.result.arrayValue, [.int(3), .int(2)])
        }
    }

    func testGinitErrorIsReportedWithoutStoppingStartup() async throws {
        let ginitVim = """
            let g:nvmm_ginit_ran = 1
            throw 'broken-ginit-marker'
            """
        try await withConfiguredNvim(
            initLua: "", ginitVim: ginitVim
        ) { process in
            try await attachLinegridUI(process)
            let finished = await waitUntilTrue(
                process, "v:vim_did_enter && get(g:, 'nvmm_ginit_ran', 0)")
            let reported = await waitUntilTrue(
                process,
                "execute('messages') =~# 'broken-ginit-marker'")
            let located = await waitUntilTrue(
                process,
                "execute('messages') =~# 'ginit.vim, line 2'")
            XCTAssertTrue(finished)
            XCTAssertTrue(reported)
            XCTAssertTrue(located)
        }
    }

    func testDisabledConfigurationDoesNotSourceUserGinit() async throws {
        let ginitVim = "let g:nvmm_ginit_ran = 1"
        let argumentSets = [["--clean"], ["-u", "NONE"], ["-u", "NORC"]]
        for arguments in argumentSets {
            try await withConfiguredNvim(
                initLua: "", ginitVim: ginitVim,
                arguments: arguments
            ) { process in
                try await attachLinegridUI(process)
                let finished = await waitUntilTrue(process, "v:vim_did_enter")
                XCTAssertTrue(finished, "arguments: \(arguments)")
                let response = try await process.request(
                    "nvim_eval", [.string("exists('g:nvmm_ginit_ran')")])
                XCTAssertEqual(response.result.integer?.signed, 0,
                               "arguments: \(arguments)")
            }
        }
    }

    func testPromptingGinitDoesNotBlockRemoteStartup() async throws {
        let ginitVim = """
            let g:nvmm_prompt_answer = input('Nvmm prompt: ')
            let g:nvmm_prompt_done = 1
            """
        try await withListeningNvim(
            ginitVim: ginitVim
        ) { server in
            let process = NeovimProcess()
            try await process.connect(server.socket)

            var options = UIOptions()
            options.extLinegrid = true
            let result = await process.uiAttach(
                width: 80, height: 24, options: options)
            XCTAssertEqual(result.status, .success)
            await process.activateGUIStartup()

            // `input()` services input notifications but not ordinary RPC
            // requests, so give its prompt time to enter the blocking loop.
            try await Task.sleep(for: .milliseconds(100))
            await process.perform(.input("answer<CR>"))
            let finished = await waitUntilTrue(
                process,
                "get(g:, 'nvmm_prompt_done', 0)"
                    + " && g:nvmm_prompt_answer ==# 'answer'")
            XCTAssertTrue(finished)
            await process.disconnect()
        }
    }

    func testConcurrentUIsRunIndependentGUIStartup() async throws {
        let ginitVim = """
            let g:nvmm_ginit_count = get(g:, 'nvmm_ginit_count', 0) + 1
            """
        try await withListeningNvim(
            ginitVim: ginitVim
        ) { server in
            let first = NeovimProcess()
            let second = NeovimProcess()
            try await first.connect(server.socket)
            try await second.connect(server.socket)

            var options = UIOptions()
            options.extLinegrid = true
            async let firstResult = first.uiAttach(
                width: 80, height: 24, options: options)
            async let secondResult = second.uiAttach(
                width: 80, height: 24, options: options)
            let results = await [firstResult, secondResult]
            XCTAssertTrue(results.allSatisfy { $0.status == .success })

            let secondProbe = StartupGridProbe()
            let observeSecond = Task {
                for await grid in second.grids {
                    await secondProbe.record(grid)
                }
            }
            await first.perform(.input("iX<Esc>"))
            let drawDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await !secondProbe.hasDrawn,
                  ContinuousClock.now < drawDeadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            let secondDrawn = await secondProbe.hasDrawn
            XCTAssertTrue(secondDrawn)

            await first.activateGUIStartup()
            let firstReady = await awaitStartupGrid(first.grids)
            XCTAssertNotNil(firstReady)
            try await Task.sleep(for: .milliseconds(200))
            let secondEarly = await secondProbe.startupGrid
            XCTAssertNil(secondEarly)

            await second.activateGUIStartup()
            let readyDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await secondProbe.startupGrid == nil,
                  ContinuousClock.now < readyDeadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            let secondReady = await secondProbe.startupGrid
            XCTAssertNotNil(secondReady)
            observeSecond.cancel()
            let ranTwice = await waitUntilTrue(
                first, "get(g:, 'nvmm_ginit_count', 0) == 2")
            XCTAssertTrue(ranTwice)
            await first.disconnect()
            await second.disconnect()
        }
    }

    func testSuccessfulReadsAndWritesPublishRecentFilePaths() async throws {
        try await withNvim { process in
            try await attachLinegridUI(process)
            let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }

            let existing = directory.appendingPathComponent("existing").path
            let created = directory.appendingPathComponent("created").path
            XCTAssertTrue(FileManager.default.createFile(
                atPath: existing, contents: Data("hello".utf8)))

            let read = expectation(description: "read file reported")
            let written = expectation(description: "written file reported")
            let collector = Task {
                for await path in process.recentFilePaths {
                    if path == existing { read.fulfill() }
                    if path == created { written.fulfill() }
                }
            }
            defer { collector.cancel() }

            let lua = """
                local existing, created = ...
                vim.api.nvim_cmd({cmd='edit', args={existing}}, {})
                vim.api.nvim_cmd({cmd='enew'}, {})
                vim.api.nvim_buf_set_name(0, created)
                vim.api.nvim_buf_set_lines(0, 0, -1, true, {'new'})
                vim.api.nvim_cmd({cmd='write'}, {})
                """
            let response = try await process.request(
                "nvim_exec_lua",
                [.string(lua), .array([.string(existing), .string(created)])])
            XCTAssertFalse(response.isError)
            await fulfillment(of: [read, written], timeout: 2)
        }
    }

    private func waitForEditorState(
        _ process: NeovimProcess,
        mode: NvimMode,
        line: String,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let modeReply = try? await process.request("nvim_get_mode")
            let lineReply = try? await process.request(
                "nvim_get_current_line")
            if modeReply.map(parseNvimMode) == mode,
               lineReply?.result.stringValue == line {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// Puts Neovim into the block every one of these cases starts from: `q`
    /// in Normal mode waits for a register name, which only the user can
    /// give. False if the wait never took hold.
    private func blockOnRegisterWait(_ process: NeovimProcess) async -> Bool {
        await process.perform(.input("q"))
        return await waitFor(process) { await $0.isBlockedAwaitingInput() }
    }

    /// Waits for a block to lift, after the pending input has been answered.
    private func waitUntilUnblocked(_ process: NeovimProcess) async -> Bool {
        await waitFor(process) { await !$0.isBlockedAwaitingInput() }
    }

    private func waitFor(
        _ process: NeovimProcess, timeout: Duration = .seconds(2),
        _ condition: (NeovimProcess) async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition(process) { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    /// While Neovim is blocked waiting for input it answers `nvim_get_mode`
    /// with `blocking` set and nothing else: requests time out, and a quit
    /// command issued then queues behind the block instead of running.
    /// Cancelling the pending input lifts the block, and the queued quit then
    /// runs — which is why nothing may be issued into a blocked Neovim.
    func testBlockedInputIsDetectedAndDefersCommands() async throws {
        try await withNvim { process in
            try await attachLinegridUI(process)
            let blockedAtStart = await process.isBlockedAwaitingInput()
            XCTAssertFalse(blockedAtStart)

            let blocked = await blockOnRegisterWait(process)
            XCTAssertTrue(blocked)

            // A quit issued now queues behind the block: Neovim stays
            // blocked and alive, where a quit that ran would have ended the
            // connection.
            await process.perform(.quit(force: false))
            let watch = ContinuousClock.now.advanced(by: .milliseconds(500))
            while ContinuousClock.now < watch {
                let stillBlocked = await process.isBlockedAwaitingInput()
                XCTAssertTrue(stillBlocked)
                if !stillBlocked { break }
                try? await Task.sleep(for: .milliseconds(50))
            }

            // Esc through `nvim_input` is what reaches a blocked Neovim. It
            // cancels the wait, the queued quit then runs, and the connection
            // ends.
            await process.perform(.input("\u{1b}"))
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            var exited = false
            while ContinuousClock.now < deadline {
                if (try? await process.request("nvim_get_mode")) == nil {
                    exited = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(exited)
        }
    }

    /// The reported flow: `q` waits for a register name, Cmd-S reports that
    /// Neovim is waiting, and once the register name is given the save works
    /// normally — including offering a filename for an unnamed buffer, which
    /// is what a write sent into the block would have lost.
    func testUnnamedBufferSaveIsOfferedAfterTheBlockClears() async throws {
        try await withNvim { process in
            try await attachLinegridUI(process)
            let changed = try await process.request(
                "nvim_buf_set_lines",
                [.int(0), .int(0), .int(-1), .bool(true),
                 .array([.string("hello")])])
            XCTAssertFalse(changed.isError)

            let blocked = await blockOnRegisterWait(process)
            XCTAssertTrue(blocked)

            // Cmd-S's own sequence: no keys are pending, so this is not a
            // mapping pause, and the write reports the block.
            let allowed = await process.canSave()
            XCTAssertTrue(allowed)
            let refused = await process.writeCurrentBuffer()
            XCTAssertEqual(refused, .awaitingInput)

            // Give the register name, as the user does after the report.
            await process.perform(.input("q"))
            let cleared = await waitUntilUnblocked(process)
            XCTAssertTrue(cleared)

            // E32 now reaches the caller, which is what puts up a save panel.
            let outcome = await process.writeCurrentBuffer()
            XCTAssertEqual(outcome, .needsFilename)
        }
    }

    /// A key that starts a longer mapping blocks Neovim until `'timeoutlen'`
    /// runs out. That pause is told apart from a wait on the user and ended,
    /// so the write runs and its E32 reaches the caller long before the
    /// timeout would have.
    func testSaveEndsAMappingPause() async throws {
        try await withNvim { process in
            try await attachLinegridUI(process)
            let setup = try await process.request("nvim_exec2", [
                .string("set timeoutlen=10000 | nnoremap ,x <Nop>"),
                .map([])])
            XCTAssertFalse(setup.isError)
            let changed = try await process.request(
                "nvim_buf_set_lines",
                [.int(0), .int(0), .int(-1), .bool(true),
                 .array([.string("hello")])])
            XCTAssertFalse(changed.isError)

            await process.perform(.input(","))
            let blocked = await waitFor(process) {
                await $0.isBlockedAwaitingInput()
            }
            XCTAssertTrue(blocked)
            let paused = await process.isPausedOnMapping()
            XCTAssertTrue(paused)

            let start = ContinuousClock.now
            let allowed = await process.canSave()
            XCTAssertTrue(allowed)
            let outcome = await process.writeCurrentBuffer()
            XCTAssertEqual(outcome, .needsFilename)
            XCTAssertLessThan(ContinuousClock.now - start, .seconds(3))
        }
    }

    /// A mapping prefix that is also an operator: ending the pause leaves `d`
    /// pending. The save aborts it, as for an operator typed on its own, so
    /// Neovim is back in Normal mode once the file is written.
    func testSaveAbortsAnOperatorLeftByAMappingPause() async throws {
        try await withNvim { process in
            try await attachLinegridUI(process)
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("nvmm-save-\(UUID().uuidString)").path
            defer { try? FileManager.default.removeItem(atPath: path) }
            let named = try await process.request(
                "nvim_buf_set_name", [.int(0), .string(path)])
            XCTAssertFalse(named.isError)
            let setup = try await process.request("nvim_exec2", [
                .string("set timeoutlen=10000 | nnoremap ds <Nop>"),
                .map([])])
            XCTAssertFalse(setup.isError)

            await process.perform(.input("d"))
            let blocked = await waitFor(process) {
                await $0.isBlockedAwaitingInput()
            }
            XCTAssertTrue(blocked)

            let allowed = await process.canSave()
            XCTAssertTrue(allowed)
            let outcome = await process.writeCurrentBuffer()
            XCTAssertEqual(outcome, .written)
            let mode = await process.mode()
            XCTAssertEqual(mode, .normal)
        }
    }

    /// A paste during a mapping pause ends the pause and lands, rather than
    /// being refused as if Neovim were waiting on the user.
    func testPasteEndsAMappingPause() async throws {
        try await withNvim { process in
            try await attachLinegridUI(process)
            let setup = try await process.request("nvim_exec2", [
                .string("set timeoutlen=10000 | nnoremap ,x <Nop>"),
                .map([])])
            XCTAssertFalse(setup.isError)

            await process.perform(.input(","))
            let blocked = await waitFor(process) {
                await $0.isBlockedAwaitingInput()
            }
            XCTAssertTrue(blocked)

            await process.perform(.paste("hello", refused: {
                XCTFail("the paste was refused")
            }))
            let pasted = await waitUntilTrue(
                process, "getline(1) ==# 'hello'")
            XCTAssertTrue(pasted)
        }
    }

    /// Commands gated on `prepareForCommand` — Open, deleting a buffer — end
    /// a mapping pause before reading the mode, so an operator the pause
    /// leaves behind is cleared rather than left to swallow the command.
    func testPrepareForCommandEndsAMappingPause() async throws {
        try await withNvim { process in
            try await attachLinegridUI(process)
            let setup = try await process.request("nvim_exec2", [
                .string("set timeoutlen=10000 | nnoremap ds <Nop>"),
                .map([])])
            XCTAssertFalse(setup.isError)

            await process.perform(.input("d"))
            let blocked = await waitFor(process) {
                await $0.isBlockedAwaitingInput()
            }
            XCTAssertTrue(blocked)

            let start = ContinuousClock.now
            let prepared = await process.prepareForCommand()
            XCTAssertTrue(prepared)
            // Normal mode is reported during the pause too, so the pause
            // must also have ended.
            let normal = await waitFor(process) { process in
                guard await !process.isBlockedAwaitingInput() else {
                    return false
                }
                return await process.mode() == .normal
            }
            XCTAssertTrue(normal)
            XCTAssertLessThan(ContinuousClock.now - start, .seconds(3))
        }
    }

    /// The hit-enter prompt blocks with no keys pending, so it is not a
    /// mapping pause, and saving there is refused outright, before Save As
    /// puts up a panel it could not finish.
    func testSaveIsRefusedAtTheHitEnterPrompt() async throws {
        try await withNvim { process in
            try await attachLinegridUI(process)
            await process.perform(.input(":echo \"a\\nb\"\r"))
            let prompted = await waitFor(process) {
                await $0.mode() == .promptEnter
            }
            XCTAssertTrue(prompted)
            let blocked = await process.isBlockedAwaitingInput()
            XCTAssertTrue(blocked)
            let paused = await process.isPausedOnMapping()
            XCTAssertFalse(paused)

            let allowed = await process.canSave()
            XCTAssertFalse(allowed)
            let stillPrompted = await process.mode()
            XCTAssertEqual(stillPrompted, .promptEnter)
        }
    }

    /// The Help menu types its command rather than issuing it, so it reaches
    /// a Neovim blocked awaiting input — where an `nvim_command` would queue
    /// behind the block instead. The leading keys answer the pending wait.
    func testOpenHelpTopicWorksWhileBlockedAwaitingInput() async throws {
        try await withNvim { process in
            try await attachLinegridUI(process)

            let blocked = await blockOnRegisterWait(process)
            XCTAssertTrue(blocked)

            await process.openHelpTopic("help")
            let opened = await waitUntilTrue(process, "&buftype ==# 'help'")
            XCTAssertTrue(opened)
            // The block is gone: the typed keys cleared the pending wait.
            let stillBlocked = await process.isBlockedAwaitingInput()
            XCTAssertFalse(stillBlocked)
        }
    }

    func testNewBufferPreservesModifiedBufferWithNohidden() async throws {
        try await withNvim { process in
            // The command is typed, and Neovim reads typed input only once a
            // UI is attached: `--embed` waits for one before entering its
            // main loop.
            try await attachLinegridUI(process)
            let oldReply = try await process.request(
                "nvim_eval", [.string("bufnr('%')")])
            XCTAssertFalse(oldReply.isError)
            let old = try XCTUnwrap(oldReply.result.integer?.signed)
            let changed = try await process.request(
                "nvim_buf_set_lines",
                [.int(MPInteger(old)), .int(0), .int(-1), .bool(true),
                 .array([.string("unsaved")])])
            XCTAssertFalse(changed.isError)
            let nohidden = try await process.request(
                "nvim_command", [.string("set nohidden")])
            XCTAssertFalse(nohidden.isError)

            await process.newDocument(inBuffers: true)
            let created = await waitUntilTrue(
                process, "bufnr('%') != \(old)")
            XCTAssertTrue(created)

            let lua = """
                local old = ...
                return {
                  vim.o.hidden,
                  vim.api.nvim_get_current_buf(),
                  vim.fn.tabpagenr('$'),
                  vim.api.nvim_buf_is_loaded(old),
                  vim.bo[old].modified,
                }
                """
            let state = try await process.request(
                "nvim_exec_lua",
                [.string(lua), .array([.int(MPInteger(old))])])
            let values = try XCTUnwrap(state.result.arrayValue)

            XCTAssertEqual(values.count, 5)
            XCTAssertEqual(values[0], .bool(false))
            XCTAssertNotEqual(values[1].integer?.signed, old)
            XCTAssertEqual(values[2].integer?.signed, 1)
            XCTAssertEqual(values[3], .bool(true))
            XCTAssertEqual(values[4], .bool(true))
        }
    }

    func testWriteFailurePreservesNeovimMessage() async throws {
        try await withNvim { process in
            let path = "/private/tmp/nvmm-\(UUID().uuidString)/file"
            let changed = try await process.request(
                "nvim_buf_set_lines",
                [.int(0), .int(0), .int(-1), .bool(true),
                 .array([.string("unsaved")])])
            XCTAssertFalse(changed.isError)
            let named = try await process.request(
                "nvim_buf_set_name", [.int(0), .string(path)])
            XCTAssertFalse(named.isError)

            let outcome = await process.writeCurrentBuffer()
            guard case .failed(let detail) = outcome else {
                return XCTFail("expected write failure, got \(outcome)")
            }
            XCTAssertTrue(detail.contains("E212:"), detail)
            XCTAssertTrue(
                detail.contains("Can't open file for writing"), detail)
        }
    }

    /// Save As renames the document rather than copying it out: the buffer
    /// takes the new name, is no longer modified, and the alternate buffer
    /// `:saveas` leaves behind under the old name is wiped, so the window
    /// still holds one document.
    func testSaveAsRenamesTheBufferAndWipesTheOldName() async throws {
        try await withNvim { process in
            try await attachLinegridUI(process)
            let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let old = directory.appendingPathComponent("old").path
            let new = directory.appendingPathComponent("new file %").path
            try "old\n".write(toFile: old, atomically: true, encoding: .utf8)

            let edited = try await process.request(
                "nvim_exec_lua",
                [.string("""
                    vim.api.nvim_cmd({cmd='edit', args={...}}, {})
                    vim.api.nvim_buf_set_lines(0, 0, -1, true, {'edited'})
                    """),
                 .array([.string(old)])])
            XCTAssertFalse(edited.isError)

            let outcome = await process.writeAs(new)
            XCTAssertEqual(outcome, .written)

            let state = try await process.request(
                "nvim_exec_lua",
                [.string("""
                    local old = ...
                    return {vim.api.nvim_buf_get_name(0), vim.bo.modified,
                            vim.fn.bufexists(old) == 1,
                            #vim.fn.getbufinfo({buflisted = 1})}
                    """),
                 .array([.string(old)])])
            let values = try XCTUnwrap(state.result.arrayValue)
            XCTAssertEqual(values.count, 4)
            XCTAssertEqual(values[0].stringValue, new)
            XCTAssertEqual(values[1], .bool(false))
            XCTAssertEqual(values[2], .bool(false))
            XCTAssertEqual(values[3].integer?.signed, 1)

            // The edit went to the new file; the old one is left as it was.
            XCTAssertEqual(try String(contentsOfFile: new, encoding: .utf8),
                           "edited\n")
            XCTAssertEqual(try String(contentsOfFile: old, encoding: .utf8),
                           "old\n")
        }
    }

    /// Saving a brand-new document under a name: `:saveas` leaves the empty
    /// name behind as a `[No Name]` buffer, which is wiped too, so the window
    /// is left holding the one document that was just named.
    func testSaveAsFromAnUnnamedBufferLeavesNoStrayBuffer() async throws {
        try await withNvim { process in
            try await attachLinegridUI(process)
            let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("named").path

            let typed = try await process.request(
                "nvim_buf_set_lines",
                [.int(0), .int(0), .int(-1), .bool(true),
                 .array([.string("typed")])])
            XCTAssertFalse(typed.isError)

            let outcome = await process.writeAs(path)
            XCTAssertEqual(outcome, .written)

            let state = try await process.request(
                "nvim_exec_lua",
                [.string("""
                    return {vim.api.nvim_buf_get_name(0), vim.bo.modified,
                            #vim.api.nvim_list_bufs()}
                    """),
                 .array([])])
            let values = try XCTUnwrap(state.result.arrayValue)
            XCTAssertEqual(values.count, 3)
            XCTAssertEqual(values[0].stringValue, path)
            XCTAssertEqual(values[1], .bool(false))
            XCTAssertEqual(values[2].integer?.signed, 1)
            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8),
                           "typed\n")
        }
    }

    /// Cmd-S while typing: the write covers the text just typed, and Neovim
    /// is left in Insert mode rather than dropped into Normal mode.
    func testSaveFromInsertModeWritesAndStaysInInsertMode() async throws {
        try await withNvim { process in
            try await attachLinegridUI(process)
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("nvmm-save-\(UUID().uuidString)").path
            defer { try? FileManager.default.removeItem(atPath: path) }
            let named = try await process.request(
                "nvim_buf_set_name", [.int(0), .string(path)])
            XCTAssertFalse(named.isError)

            await process.perform(.input("ihello"))
            let typed = await waitForEditorState(
                process, mode: .insert, line: "hello")
            XCTAssertTrue(typed)

            let allowed = await process.canSave()
            XCTAssertTrue(allowed)
            let outcome = await process.writeCurrentBuffer()
            XCTAssertEqual(outcome, .written)

            let mode = await process.mode()
            XCTAssertEqual(mode, .insert)
            let written = try String(contentsOfFile: path, encoding: .utf8)
            XCTAssertEqual(written, "hello\n")
        }
    }

    func testUndoRedoReportsBoundariesAndPreservesInsertMode() async throws {
        try await withNvim { process in
            try await attachLinegridUI(process)
            await process.perform(.input("iabc"))

            let firstUndo = await process.performUndoRedo(.undo)
            XCTAssertEqual(firstUndo, .changed)
            let undone = await waitForEditorState(
                process, mode: .insert, line: "")
            XCTAssertTrue(undone)
            let oldestUndo = await process.performUndoRedo(.undo)
            XCTAssertEqual(oldestUndo, .boundary)

            let firstRedo = await process.performUndoRedo(.redo)
            XCTAssertEqual(firstRedo, .changed)
            let redone = await waitForEditorState(
                process, mode: .insert, line: "abc")
            XCTAssertTrue(redone)
            let newestRedo = await process.performUndoRedo(.redo)
            XCTAssertEqual(newestRedo, .boundary)
        }
    }

    func testNeovimBellEventsReachTheUIStream() async throws {
        try await withNvim { process in
            try await attachLinegridUI(process)
            let audible = expectation(description: "audible bell")
            let visual = expectation(description: "visual bell")
            let collector = Task {
                var iterator = process.bells.makeAsyncIterator()
                if await iterator.next() == .audible {
                    audible.fulfill()
                }
                if await iterator.next() == .visual {
                    visual.fulfill()
                }
            }
            defer { collector.cancel() }

            _ = try await process.request(
                "nvim_command",
                [.string("set belloff= novisualbell")])
            await process.perform(.input("<Esc>"))
            await fulfillment(of: [audible], timeout: 2)

            _ = try await process.request(
                "nvim_command", [.string("set visualbell")])
            await process.perform(.input("<Esc>"))
            await fulfillment(of: [visual], timeout: 2)
        }
    }

    /// Types `abc` in Insert mode and returns to Normal mode, leaving one
    /// change to undo, then sets up a mapping with a long `'timeoutlen'`.
    private func prepareUndoDuringPause(
        _ process: NeovimProcess, mapping: String, timeoutlen: Int = 10000
    ) async throws {
        try await attachLinegridUI(process)
        await process.perform(.input("iabc\u{1b}"))
        let typed = await waitForEditorState(
            process, mode: .normal, line: "abc")
        XCTAssertTrue(typed)
        let setup = try await process.request("nvim_exec2", [
            .string("set timeoutlen=\(timeoutlen) | nnoremap \(mapping) <Nop>"),
            .map([])])
        XCTAssertFalse(setup.isError)
    }

    /// Undo during a mapping pause ends the pause and undoes, long before
    /// `'timeoutlen'` would have ended it.
    func testUndoEndsAMappingPause() async throws {
        try await withNvim { process in
            try await prepareUndoDuringPause(process, mapping: ",x")
            await process.perform(.input(","))
            let blocked = await waitFor(process) {
                await $0.isBlockedAwaitingInput()
            }
            XCTAssertTrue(blocked)

            let start = ContinuousClock.now
            let outcome = await process.performUndoRedo(.undo)
            XCTAssertEqual(outcome, .changed)
            XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
            let undone = await waitForEditorState(
                process, mode: .normal, line: "")
            XCTAssertTrue(undone)
        }
    }

    /// A mapping prefix that is also an operator: the keys for Undo are
    /// chosen after the pause ends, from the operator-pending mode it
    /// leaves, so the operator is cancelled rather than handed `u` as its
    /// motion. The short `'timeoutlen'` is not needed to pass; it keeps the
    /// test telling. Were the mode read before the pause ended, the pause
    /// would still end, on its own, within the undo's deadline, and `u`
    /// would reach the pending `d` as its motion.
    func testUndoAfterAnOperatorLeftByAMappingPause() async throws {
        try await withNvim { process in
            try await prepareUndoDuringPause(
                process, mapping: "ds", timeoutlen: 500)
            await process.perform(.input("d"))
            let blocked = await waitFor(process) {
                await $0.isBlockedAwaitingInput()
            }
            XCTAssertTrue(blocked)

            let outcome = await process.performUndoRedo(.undo)
            XCTAssertEqual(outcome, .changed)
            let undone = await waitForEditorState(
                process, mode: .normal, line: "")
            XCTAssertTrue(undone)
        }
    }

    /// Undo while Neovim waits on the user is unavailable at once, without
    /// parking the input queue behind requests the block would hold.
    func testUndoIsUnavailableWhileAwaitingInput() async throws {
        try await withNvim { process in
            try await prepareUndoDuringPause(process, mapping: ",x")
            let blocked = await blockOnRegisterWait(process)
            XCTAssertTrue(blocked)

            let start = ContinuousClock.now
            let outcome = await process.performUndoRedo(.undo)
            XCTAssertEqual(outcome, .unavailable)
            XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))

            // Nothing was queued: answering the wait leaves the text as it
            // was.
            await process.perform(.input("q"))
            let cleared = await waitUntilUnblocked(process)
            XCTAssertTrue(cleared)
            let kept = await waitForEditorState(
                process, mode: .normal, line: "abc")
            XCTAssertTrue(kept)
        }
    }

    func testUndoRedoIsUnavailableWithoutAConnection() async {
        let process = NeovimProcess()
        let outcome = await process.performUndoRedo(.undo)
        XCTAssertEqual(outcome, .unavailable)
    }

    func testRedoReportsBoundaryOnNewUndoBranch() async throws {
        try await withNvim { process in
            try await attachLinegridUI(process)
            _ = try await process.request(
                "nvim_input", [.string("iabc\u{1b}")])
            let firstChange = await waitForEditorState(
                process, mode: .normal, line: "abc")
            XCTAssertTrue(firstChange)
            let firstUndo = await process.performUndoRedo(.undo)
            XCTAssertEqual(firstUndo, .changed)

            _ = try await process.request(
                "nvim_input", [.string("iX\u{1b}")])
            let branchChange = await waitForEditorState(
                process, mode: .normal, line: "X")
            XCTAssertTrue(branchChange)
            let branchRedo = await process.performUndoRedo(.redo)
            XCTAssertEqual(branchRedo, .boundary)
            let branchUndo = await process.performUndoRedo(.undo)
            XCTAssertEqual(branchUndo, .changed)
        }
    }
}
