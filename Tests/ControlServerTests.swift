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

    private nonisolated static func exchange(
        _ request: CLIRequest, path: String
    ) throws -> [CLIResponse] {
        let result = CLIEndpoint.connect(to: path)
        guard result.error == 0 else {
            throw CLIError.system(result.error)
        }
        defer { close(result.fd) }

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
