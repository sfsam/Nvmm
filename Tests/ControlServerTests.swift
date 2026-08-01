//
//  NvmmTests
//  ControlServerTests.swift
//

import Darwin
import Foundation
import XCTest
@testable import Nvmm

final class ControlServerTests: XCTestCase {

    @MainActor
    func testRequestAcknowledgesAndCompletesWait() async throws {
        let endpoint = try TestEndpoint()
        defer { endpoint.remove() }
        let server = try ControlServer(path: endpoint.socketPath) {
            request, channel in
            XCTAssertEqual(request.files, ["new-file"])
            channel.accepted(wait: request.wait)
            channel.closed()
        }
        defer { server.stop() }

        let request = CLIRequest(arguments: [], files: ["new-file"],
                                 workingDirectory: "/tmp",
                                 forceNewWindow: false, wait: true)
        let responses = try await Self.exchangeAsync(
            request, path: endpoint.socketPath)

        XCTAssertEqual(responses, [.accepted, .closed])
    }

    @MainActor
    func testServerRejectsUnsupportedForwardedArgument() async throws {
        let endpoint = try TestEndpoint()
        defer { endpoint.remove() }
        let server = try ControlServer(path: endpoint.socketPath) {
            _, _ in XCTFail("Invalid request reached the app handler")
        }
        defer { server.stop() }

        let request = CLIRequest(arguments: ["--headless"], files: [],
                                 workingDirectory: "/tmp",
                                 forceNewWindow: false, wait: false)
        let responses = try await Self.exchangeAsync(
            request, path: endpoint.socketPath)

        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.status, .error)
    }

    @MainActor
    func testServerRecoversStaleOwnedSocket() throws {
        let endpoint = try TestEndpoint()
        defer { endpoint.remove() }
        try Self.leaveStaleSocket(at: endpoint.socketPath)

        let server = try ControlServer(path: endpoint.socketPath) {
            _, channel in channel.accepted(wait: false)
        }
        server.stop()
    }

    @MainActor
    func testIdleConnectionExpires() async throws {
        let endpoint = try TestEndpoint()
        defer { endpoint.remove() }
        let limits = ControlServerLimits(
            maximumPendingConnections: 1,
            preRequestIdleTimeout: 0.05,
            descriptorRetryInterval: 0.05)
        let server = try ControlServer(path: endpoint.socketPath,
                                       limits: limits) { _, _ in
            XCTFail("Idle connection reached the handler")
        }
        defer { server.stop() }

        let descriptor = try Self.connect(to: endpoint.socketPath)
        defer { close(descriptor) }
        let response = try await Self.readResponseAsync(descriptor)

        XCTAssertNil(response)
        XCTAssertEqual(server.pendingConnectionCount, 0)
    }

    @MainActor
    func testPendingCapReturnsSpecificError() async throws {
        let endpoint = try TestEndpoint()
        defer { endpoint.remove() }
        let limits = ControlServerLimits(
            maximumPendingConnections: 1,
            preRequestIdleTimeout: 2,
            descriptorRetryInterval: 0.05)
        let server = try ControlServer(path: endpoint.socketPath,
                                       limits: limits) { _, channel in
            channel.accepted(wait: false)
        }
        defer { server.stop() }

        let pending = try Self.connect(to: endpoint.socketPath)
        defer { close(pending) }
        let reachedCap = await waitUntil {
            server.pendingConnectionCount == 1
        }
        XCTAssertTrue(reachedCap)

        let responses = try await Self.exchangeAsync(
            Self.request(), path: endpoint.socketPath)
        XCTAssertEqual(responses, [CLIResponse.error(
            "Too many pending control connections.")])
    }

    @MainActor
    func testPendingSlotRecoversAfterEOF() async throws {
        let endpoint = try TestEndpoint()
        defer { endpoint.remove() }
        let limits = ControlServerLimits(
            maximumPendingConnections: 1,
            preRequestIdleTimeout: 2,
            descriptorRetryInterval: 0.05)
        let server = try ControlServer(path: endpoint.socketPath,
                                       limits: limits) { _, channel in
            channel.accepted(wait: false)
        }
        defer { server.stop() }

        let pending = try Self.connect(to: endpoint.socketPath)
        let filledSlot = await waitUntil {
            server.pendingConnectionCount == 1
        }
        XCTAssertTrue(filledSlot)
        close(pending)
        let releasedSlot = await waitUntil {
            server.pendingConnectionCount == 0
        }
        XCTAssertTrue(releasedSlot)

        let responses = try await Self.exchangeAsync(
            Self.request(), path: endpoint.socketPath)
        XCTAssertEqual(responses, [.accepted])
    }

    @MainActor
    func testCompletedRequestCancelsIdleDeadline() async throws {
        let endpoint = try TestEndpoint()
        defer { endpoint.remove() }
        let limits = ControlServerLimits(
            maximumPendingConnections: 1,
            preRequestIdleTimeout: 0.03,
            descriptorRetryInterval: 0.05)
        let server = try ControlServer(path: endpoint.socketPath,
                                       limits: limits) { _, channel in
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                channel.accepted(wait: false)
            }
        }
        defer { server.stop() }

        let responses = try await Self.exchangeAsync(
            Self.request(), path: endpoint.socketPath)
        XCTAssertEqual(responses, [.accepted])
    }

    @MainActor
    func testWaitConnectionHasNoIdleDeadline() async throws {
        let endpoint = try TestEndpoint()
        defer { endpoint.remove() }
        let limits = ControlServerLimits(
            maximumPendingConnections: 1,
            preRequestIdleTimeout: 0.03,
            descriptorRetryInterval: 0.05)
        var waitAccepted = false
        let server = try ControlServer(path: endpoint.socketPath,
                                       limits: limits) { request, channel in
            channel.accepted(wait: request.wait)
            if request.wait {
                waitAccepted = true
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    channel.closed()
                }
            }
        }
        defer { server.stop() }

        async let waitResponses = Self.exchangeAsync(
            Self.request(wait: true), path: endpoint.socketPath)
        let waiting = await waitUntil { waitAccepted }
        XCTAssertTrue(waiting)
        let ordinaryResponses = try await Self.exchangeAsync(
            Self.request(), path: endpoint.socketPath)
        XCTAssertEqual(ordinaryResponses, [.accepted])
        let completedWaitResponses = try await waitResponses
        XCTAssertEqual(completedWaitResponses, [.accepted, .closed])
    }

    @MainActor
    func testDescriptorExhaustionRetriesWithoutRestart() async throws {
        for injectedError in [EMFILE, ENFILE] {
            let endpoint = try TestEndpoint()
            var shouldFail = true
            let limits = ControlServerLimits(
                maximumPendingConnections: 1,
                preRequestIdleTimeout: 2,
                descriptorRetryInterval: 0.03)
            let server = try ControlServer(
                path: endpoint.socketPath,
                limits: limits,
                acceptClient: { descriptor in
                    if shouldFail {
                        shouldFail = false
                        errno = injectedError
                        return -1
                    }
                    return Darwin.accept(descriptor, nil, nil)
                },
                handler: { _, channel in
                    channel.accepted(wait: false)
                })

            let responses = try await Self.exchangeAsync(
                Self.request(), path: endpoint.socketPath)
            XCTAssertEqual(responses, [.accepted])
            server.stop()
            endpoint.remove()
        }
    }

    @MainActor
    func testPendingReleaseRearmsPausedAcceptSource() async throws {
        let endpoint = try TestEndpoint()
        defer { endpoint.remove() }
        var acceptCount = 0
        let limits = ControlServerLimits(
            maximumPendingConnections: 2,
            preRequestIdleTimeout: 2,
            descriptorRetryInterval: 0.2)
        let server = try ControlServer(
            path: endpoint.socketPath,
            limits: limits,
            acceptClient: { descriptor in
                acceptCount += 1
                if acceptCount == 2 {
                    errno = EMFILE
                    return -1
                }
                return Darwin.accept(descriptor, nil, nil)
            },
            handler: { _, channel in
                channel.accepted(wait: false)
            })
        defer { server.stop() }

        let pending = try Self.connect(to: endpoint.socketPath)
        let firstAccepted = await waitUntil {
            server.pendingConnectionCount == 1
        }
        XCTAssertTrue(firstAccepted)
        async let second = Self.exchangeAsync(
            Self.request(), path: endpoint.socketPath)
        let paused = await waitUntil { server.acceptIsPaused }
        XCTAssertTrue(paused)
        close(pending)

        let secondResponses = try await second
        XCTAssertEqual(secondResponses, [.accepted])
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(server.acceptIsPaused)
    }

    @MainActor
    func testStopBalancesPausedAcceptSource() async throws {
        let endpoint = try TestEndpoint()
        defer { endpoint.remove() }
        let limits = ControlServerLimits(
            maximumPendingConnections: 1,
            preRequestIdleTimeout: 2,
            descriptorRetryInterval: 2)
        let server = try ControlServer(
            path: endpoint.socketPath,
            limits: limits,
            acceptClient: { _ in
                errno = EMFILE
                return -1
            },
            handler: { _, _ in XCTFail("Request was accepted") })

        let descriptor = try Self.connect(to: endpoint.socketPath)
        defer { close(descriptor) }
        let paused = await waitUntil { server.acceptIsPaused }
        XCTAssertTrue(paused)
        server.stop()
        XCTAssertEqual(lstat(endpoint.socketPath, nil), -1)
        XCTAssertEqual(errno, ENOENT)
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private nonisolated static func request(
        wait: Bool = false
    ) -> CLIRequest {
        CLIRequest(arguments: [], files: ["new-file"],
                   workingDirectory: "/tmp",
                   forceNewWindow: false, wait: wait)
    }

    private nonisolated static func exchange(
        _ request: CLIRequest, path: String
    ) throws -> [CLIResponse] {
        let result = CLIEndpoint.connect(to: path)
        guard result.error == 0 else {
            throw CLIError.system(result.error)
        }
        defer { close(result.fd) }
        try setReceiveTimeout(result.fd)

        var requestData = try JSONEncoder().encode(request)
        requestData.append(0x0a)
        try requestData.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(result.fd,
                                         bytes.baseAddress! + offset,
                                         bytes.count - offset)
                guard count > 0 else {
                    throw CLIError.system(errno)
                }
                offset += count
            }
        }

        var input = Data()
        var responses: [CLIResponse] = []
        var byte: UInt8 = 0
        while Darwin.read(result.fd, &byte, 1) == 1 {
            if byte == 0x0a {
                responses.append(try JSONDecoder().decode(
                    CLIResponse.self, from: input))
                input.removeAll(keepingCapacity: true)
            } else {
                input.append(byte)
            }
        }
        return responses
    }

    private nonisolated static func exchangeAsync(
        _ request: CLIRequest, path: String
    ) async throws -> [CLIResponse] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    continuation.resume(
                        returning: try exchange(request, path: path))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func connect(to path: String) throws -> Int32 {
        let result = CLIEndpoint.connect(to: path)
        guard result.error == 0 else {
            throw CLIError.system(result.error)
        }
        return result.fd
    }

    private nonisolated static func readResponseAsync(
        _ descriptor: Int32
    ) async throws -> CLIResponse? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    try setReceiveTimeout(descriptor)
                    var input = Data()
                    var byte: UInt8 = 0
                    while true {
                        let count = Darwin.read(descriptor, &byte, 1)
                        if count == 0 {
                            continuation.resume(returning: nil)
                            return
                        }
                        if count == -1 {
                            if errno == EINTR { continue }
                            throw CLIError.system(errno)
                        }
                        if byte == 0x0a {
                            continuation.resume(returning: try JSONDecoder()
                                .decode(CLIResponse.self, from: input))
                            return
                        }
                        input.append(byte)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func setReceiveTimeout(
        _ descriptor: Int32
    ) throws {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw CLIError.system(errno)
        }
    }

    private nonisolated static func leaveStaleSocket(
        at path: String
    ) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor != -1 else {
            throw CLIError.system(errno)
        }
        defer { close(descriptor) }

        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(bytes.count + 1)
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0,
                            socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw CLIError.system(errno)
        }
    }
}

private nonisolated struct TestEndpoint: Sendable {
    let directory: String
    let socketPath: String

    init() throws {
        directory = "/tmp/nvmm-control-test-\(UUID().uuidString)"
        socketPath = directory + "/control.sock"
        try CLIEndpoint.prepareDirectory(directory)
    }

    func remove() {
        _ = unlink(socketPath)
        _ = rmdir(directory)
    }
}
