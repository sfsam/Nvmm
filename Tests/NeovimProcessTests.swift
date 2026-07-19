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

    // MARK: Controlled-peer helpers

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
        for _ in 0..<64 {
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

    // MARK: Controlled-peer cases

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
}
