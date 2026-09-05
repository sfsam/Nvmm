//
//  NvmmTests
//  NeovimProcessTests.swift
//
//  Transport tests. The socketpair-based cases drive the actor deterministically
//  without Neovim: a controlled peer holds the far end and never (or selectively)
//  responds, exercising the timeout, disconnect, and inbound-request paths. The
//  remaining cases attach a real bundled `nvim --embed` and round-trip
//  nvim_eval / nvim_command.
//

import XCTest
import Darwin
@testable import Nvmm

final class NeovimProcessTests: XCTestCase {

    private struct TestIOError: Error {}

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

    func testTransportErrorDescriptions() {
        XCTAssertEqual(
            RPCTransportError.connectionClosed.description,
            "connection closed")
        XCTAssertEqual(
            RPCTransportError.readFailed(errno: 5).description,
            "read failed (errno 5)")
        XCTAssertEqual(
            RPCTransportError.writeFailed(errno: 32).description,
            "write failed (errno 32)")
        XCTAssertEqual(
            RPCTransportError.protocolViolation.description,
            "protocol violation")
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

    func testSpawnReapsChildExitStatus() async throws {
        let process = NeovimProcess()
        try await process.spawn(
            path: "/bin/sh",
            argv: ["/bin/sh", "-c", "exit 7"])

        let termination = await process.childTermination()

        XCTAssertEqual(termination, .exited(status: 7))
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

    func testRecordedChildTerminationDoesNotWaitForRunningChild() async throws {
        let process = NeovimProcess()
        try await process.spawn(
            path: "/bin/sh",
            argv: ["/bin/sh", "-c", "while :; do :; done"])

        let termination = await process.recordedChildTermination()

        XCTAssertNil(termination)
        _ = await process.terminateChild(gracePeriod: .milliseconds(50))
        await process.disconnect()
    }

    func testRecordedChildTerminationReturnsReapedStatus() async throws {
        let process = NeovimProcess()
        try await process.spawn(
            path: "/bin/sh",
            argv: ["/bin/sh", "-c", "exit 11"])
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
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw TestIOError() }
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
                if count <= 0 { throw TestIOError() }
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
        throw TestIOError()
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
            throw TestIOError()
        }
        if let expectedArguments, arguments != expectedArguments {
            XCTFail("unexpected arguments for \(method): \(arguments)")
            throw TestIOError()
        }
        return id
    }

    private func readNotification(
        _ fd: Int32, method: String,
        unpacker: inout MessagePackUnpacker
    ) throws {
        let message = try readMessage(fd, unpacker: &unpacker)
        guard let values = message.arrayValue, values.count == 3,
              values[0].integer?.unsigned == 2,
              values[1].stringValue == method,
              values[2].arrayValue != nil else {
            XCTFail("expected notification for \(method), got \(message)")
            throw TestIOError()
        }
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

    private func answerAttachPreamble(
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
        try readNotification(
            fd, method: "nvim_command", unpacker: &unpacker)
        try readNotification(
            fd, method: "nvim_command", unpacker: &unpacker)

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
    func testWriteIsNotSentWhileBlockedAwaitingInput() async throws {
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

        let outcome = await write.value
        XCTAssertEqual(outcome, .awaitingInput)
        // Nothing followed the probe: no `:write` is left to fail unseen.
        XCTAssertThrowsError(try readMessage(pair.peer, unpacker: &unpacker))
        await process.disconnect()
    }

    private func assertNewDocumentCommand(
        inBuffers: Bool, expectedKeys: String
    ) async throws {
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

    func testNewDocumentUsesHideEnewForBuffers() async throws {
        try await assertNewDocumentCommand(
            inBuffers: true, expectedKeys: "<Esc><C-\\><C-N>:hide enew<CR>")
    }

    func testNewDocumentUsesTabnewForTabs() async throws {
        try await assertNewDocumentCommand(
            inBuffers: false, expectedKeys: "<Esc><C-\\><C-N>:tabnew<CR>")
    }

    func testServerAddressReturnsNilForEmptyAddress() async throws {
        let pair = try makeSocketPair()
        defer { close(pair.peer) }
        let process = NeovimProcess()
        await process.attach(readFD: pair.client, writeFD: pair.client)

        let address = Task { await process.serverAddress() }
        var unpacker = MessagePackUnpacker()
        let id = try readRequest(
            pair.peer, method: "nvim_eval",
            arguments: [.string("v:servername")], unpacker: &unpacker)
        try writeResponse(pair.peer, id: id, result: .string(""))

        let result = await address.value
        XCTAssertNil(result)
        await process.disconnect()
    }

    func testServerAddressReturnsNilForErrorResponse() async throws {
        let pair = try makeSocketPair()
        defer { close(pair.peer) }
        let process = NeovimProcess()
        await process.attach(readFD: pair.client, writeFD: pair.client)

        let address = Task { await process.serverAddress() }
        var unpacker = MessagePackUnpacker()
        let id = try readRequest(
            pair.peer, method: "nvim_eval",
            arguments: [.string("v:servername")], unpacker: &unpacker)
        try writeResponse(
            pair.peer, id: id,
            error: .array([.int(0), .string("evaluation failed")]))

        let result = await address.value
        XCTAssertNil(result)
        await process.disconnect()
    }

    func testServerAddressReturnsNilWhenConnectionDrops() async throws {
        let pair = try makeSocketPair()
        let process = NeovimProcess()
        await process.attach(readFD: pair.client, writeFD: pair.client)

        let address = Task { await process.serverAddress() }
        var unpacker = MessagePackUnpacker()
        _ = try readRequest(
            pair.peer, method: "nvim_eval",
            arguments: [.string("v:servername")], unpacker: &unpacker)
        close(pair.peer)

        let result = await address.value
        XCTAssertNil(result)
        await process.disconnect()
    }

    func testUIAttachReportsPostAttachLuaError() async throws {
        let pair = try makeSocketPair()
        defer { close(pair.peer) }
        let process = NeovimProcess()
        await process.attach(readFD: pair.client, writeFD: pair.client)
        var options = UIOptions()
        options.extLinegrid = true

        let attach = Task {
            await process.uiAttach(width: 80, height: 24, options: options)
        }
        var unpacker = MessagePackUnpacker()
        try answerAttachPreamble(pair.peer, unpacker: &unpacker)

        var id = try readRequest(
            pair.peer, method: "nvim_exec_lua", unpacker: &unpacker)
        try writeResponse(pair.peer, id: id)
        id = try readRequest(
            pair.peer, method: "nvim_exec_lua", unpacker: &unpacker)
        let setupError = MPValue.string("setup failed")
        try writeResponse(pair.peer, id: id, error: setupError)

        let result = await attach.value
        XCTAssertEqual(result.status, .rpcError)
        XCTAssertEqual(result.message, "Progress setup was rejected by Neovim")
        XCTAssertEqual(result.rpcError, setupError)
        await process.disconnect()
    }

    func testUIAttachTimesOutDuringPostAttachLua() async throws {
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
        try answerAttachPreamble(pair.peer, unpacker: &unpacker)
        _ = try readRequest(
            pair.peer, method: "nvim_exec_lua", unpacker: &unpacker)

        let result = await attach.value
        XCTAssertEqual(result.status, .timedOut)
        XCTAssertEqual(result.message, "Document-state setup timed out")
        await process.disconnect()
    }

    func testProgressCompletionSurvivesLaterStateUpdate() async {
        let completion = ProgressUpdate(percent: 100, isCompletion: true)
        let state = ProgressUpdate(percent: 25, isCompletion: false)

        let received = await bufferedProgressUpdate([completion, state])
        XCTAssertEqual(received, completion)
    }

    func testProgressCompletionDisplacesEarlierStateUpdate() async {
        let state = ProgressUpdate(percent: 25, isCompletion: false)
        let completion = ProgressUpdate(percent: 100, isCompletion: true)

        let received = await bufferedProgressUpdate([state, completion])
        XCTAssertEqual(received, completion)
    }

    func testProgressStateUpdatesKeepNewestValue() async {
        let old = ProgressUpdate(percent: 25, isCompletion: false)
        let newest = ProgressUpdate(percent: 50, isCompletion: false)

        let received = await bufferedProgressUpdate([old, newest])
        XCTAssertEqual(received, newest)
    }

    func testProgressCompletionsKeepNewestValue() async {
        let old = ProgressUpdate(percent: 75, isCompletion: true)
        let newest = ProgressUpdate(percent: 100, isCompletion: true)

        let received = await bufferedProgressUpdate([old, newest])
        XCTAssertEqual(received, newest)
    }

    func testProgressPublisherIgnoresTerminatedStream() async {
        let pair = AsyncStream.makeStream(
            of: ProgressUpdate.self,
            bufferingPolicy: .bufferingNewest(1))
        pair.continuation.finish()

        publishProgressUpdate(
            ProgressUpdate(percent: 100, isCompletion: true),
            to: pair.continuation)

        var iterator = pair.stream.makeAsyncIterator()
        let received = await iterator.next()
        XCTAssertNil(received)
    }

    func testPasteChunksPreserveUnicodeAtByteBoundaries() {
        let text = "ab🙂cdéfg"
        let chunks = pasteChunks(text, maximumBytes: 5)

        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 5 })
    }

    func testEmptyPasteRemainsOneChunk() {
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

        await fulfillment(of: [refused], timeout: 2)
        await paste.value
        // Nothing followed the probe: no chunk reached the blocked editor.
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

    func testDisconnectFailsPendingRequest() async throws {
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
    }

    func testRequestAfterDisconnectThrows() async throws {
        let (client, peer) = try makeSocketPair()
        defer { close(peer) }
        let process = NeovimProcess()
        await process.attach(readFD: client, writeFD: client)
        await process.disconnect()
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

    // MARK: Real-Neovim helper

    /// Runs `body` against a real bundled Neovim and reaps the child.
    ///
    /// Closing the transport alone is not enough: a buffer left modified sends
    /// Neovim to a prompt on its way out, and with no UI to answer it the
    /// process waits there forever. `terminateChild` escalates to `SIGKILL`,
    /// which ends it whatever state it stopped in.
    ///
    /// A private state directory keeps swap files out of the one the person
    /// running the tests edits in, so a test that ends abruptly cannot leave
    /// residue that later runs — or that person's own Neovim — trip over.
    private func withNvim(_ body: (NeovimProcess) async throws -> Void) async throws {
        guard let nvim = await MainActor.run(body: { NeovimBundle.executableURL }) else {
            throw XCTSkip("bundled nvim executable not available")
        }
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmm-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let process = NeovimProcess()
        try await process.spawn(
            path: nvim.path,
            argv: [nvim.path, "--embed", "-n", "-u", "NONE", "-i", "NONE"],
            env: ["XDG_STATE_HOME=\(state.path)"])
        do {
            try await body(process)
        } catch {
            await process.disconnect()
            _ = await process.terminateChild()
            throw error
        }
        await process.disconnect()
        _ = await process.terminateChild()
    }

    private func attachLinegridUI(_ process: NeovimProcess) async throws {
        var options = UIOptions()
        options.extLinegrid = true
        let result = await process.uiAttach(
            width: 80, height: 24, options: options)
        guard result.status == .success else { throw TestIOError() }
    }

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
                return {helpers, document_state, progress, recent}
                """
            let response = try await process.request(
                "nvim_exec_lua", [.string(lua), .array([])])

            XCTAssertFalse(response.isError)
            XCTAssertEqual(response.result.arrayValue,
                           [.bool(true), .bool(true), .bool(true), .bool(true)])
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

    /// Polls a Vimscript condition until it holds. Typed keys are consumed by
    /// Neovim's main loop rather than answered like a request, so the state
    /// they produce arrives after the call that sent them.
    private func waitUntilTrue(
        _ process: NeovimProcess, _ expr: String,
        timeout: Duration = .seconds(3)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let reply = try? await process.request(
                "nvim_eval", [.string(expr)])
            if let reply, !reply.isError,
               reply.result.integer?.signed == 1 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
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

    // MARK: Real-Neovim cases

    func testEvalRoundTrip() async throws {
        try await withNvim { process in
            let response = try await process.request("nvim_eval", [.string("1 + 2")])
            XCTAssertTrue(response.error.isNull)
            XCTAssertEqual(response.result, .int(3))
        }
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

    func testCommandRoundTrip() async throws {
        try await withNvim { process in
            let set = try await process.request("nvim_command", [.string("let g:nvmm = 42")])
            XCTAssertTrue(set.error.isNull)
            let get = try await process.request("nvim_eval", [.string("g:nvmm")])
            XCTAssertEqual(get.result, .int(42))
        }
    }

    func testInvalidCommandReportsError() async throws {
        try await withNvim { process in
            let response = try await process.request("nvim_command", [.string("ThisIsNotACommand")])
            XCTAssertTrue(response.isError)
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

