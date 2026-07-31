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

    /// Reads one complete MessagePack value from a blocking descriptor.
    private func readMessage(_ fd: Int32) throws -> MPValue {
        var unpacker = MessagePackUnpacker()
        var buffer = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<1_024 {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            unpacker.feed(buffer[0..<count])
            if let value = unpacker.unpack() { return value }
        }
        throw TestIOError()
    }

    /// Runs `requestSync` off the Swift cooperative pool, as an AppKit caller
    /// would, so blocking the caller cannot starve the actor's executor.
    private func callSync(_ process: NeovimProcess, _ method: String,
                          _ arguments: [MPValue] = [], timeout: Duration) async -> RPCSyncResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: process.requestSync(method, arguments, timeout: timeout))
            }
        }
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

        let paste = Task { await process.perform(.paste(text)) }
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

    func testRequestSyncTimesOut() async throws {
        let (client, peer) = try makeSocketPair()
        defer { close(peer) }
        let process = NeovimProcess()
        await process.attach(readFD: client, writeFD: client)

        let result = await callSync(process, "nvim_get_mode", timeout: .milliseconds(100))
        guard case .timedOut = result else {
            return XCTFail("expected .timedOut, got \(result)")
        }
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

    private func withNvim(_ body: (NeovimProcess) async throws -> Void) async throws {
        guard let nvim = await MainActor.run(body: { NeovimBundle.executableURL }) else {
            throw XCTSkip("bundled nvim executable not available")
        }
        let process = NeovimProcess()
        try await process.spawn(
            path: nvim.path,
            argv: [nvim.path, "--embed", "-n", "-u", "NONE", "-i", "NONE"])
        do {
            try await body(process)
        } catch {
            await process.disconnect()
            throw error
        }
        await process.disconnect()
    }

    private func attachLinegridUI(_ process: NeovimProcess) async throws {
        var options = UIOptions()
        options.extLinegrid = true
        let result = await process.uiAttach(
            width: 80, height: 24, options: options)
        guard result.status == .success else { throw TestIOError() }
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

    // MARK: Real-Neovim cases

    func testEvalRoundTrip() async throws {
        try await withNvim { process in
            let response = try await process.request("nvim_eval", [.string("1 + 2")])
            XCTAssertTrue(response.error.isNull)
            XCTAssertEqual(response.result, .int(3))
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

    func testRequestSyncReturnsResponse() async throws {
        try await withNvim { process in
            let result = await callSync(process, "nvim_eval", [.string("2 * 3")], timeout: .seconds(5))
            guard case .response(let response) = result else {
                return XCTFail("expected .response, got \(result)")
            }
            XCTAssertEqual(response.result, .int(6))
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
