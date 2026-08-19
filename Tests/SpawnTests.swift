//
//  NvmmTests
//  SpawnTests.swift
//
//  Shell-quoting coverage: it produces single-quoted words, protects every shell
//  metacharacter, and round-trips unchanged back through /bin/sh.
//

import XCTest
@testable import Nvmm
import Darwin

final class SpawnTests: XCTestCase {

    private struct SpawnTestError: Error {}

    func testShellQuoteArgQuotesEveryWord() {
        XCTAssertEqual(spawnShellQuoteArg(""), "''")
        XCTAssertEqual(spawnShellQuoteArg("abc"), "'abc'")
        XCTAssertEqual(spawnShellQuoteArg("a b"), "'a b'")
        XCTAssertEqual(spawnShellQuoteArg("a'b"), "'a'\\''b'")
    }

    func testShellQuoteArgProtectsShellMetacharacters() {
        let input = "a; touch /tmp/nope | $HOME `whoami` [x] * ? ( ) < > &"
        XCTAssertEqual(spawnShellQuoteArg(input), "'\(input)'")
    }

    func testShellQuoteArgRoundTripsThroughShell() throws {
        let input = "a b;'$HOME`whoami`|[x]*?"
        let command = "printf '%s' " + spawnShellQuoteArg(input)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let output = Foundation.Pipe()
        process.standardOutput = output

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), input)
    }

    func testParsesUnixAndTCPServerAddresses() {
        XCTAssertEqual(parseRPCAddress("/tmp/nvim.sock"),
                       .unix(path: "/tmp/nvim.sock"))
        XCTAssertEqual(parseRPCAddress("relative.sock"),
                       .unix(path: "relative.sock"))
        XCTAssertEqual(parseRPCAddress("localhost:6666"),
                       .tcp(host: "localhost", port: 6666))
        XCTAssertEqual(parseRPCAddress("127.0.0.1:7777"),
                       .tcp(host: "127.0.0.1", port: 7777))
        XCTAssertEqual(parseRPCAddress("[::1]:8888"),
                       .tcp(host: "::1", port: 8888))
    }

    func testConnectsToLoopbackTCPServer() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener != -1 else { throw SpawnTestError() }
        defer { close(listener) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw SpawnTestError() }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &length)
            }
        }
        guard named == 0 else { throw SpawnTestError() }
        let port = UInt16(bigEndian: address.sin_port)
        let connected = Spawn.connectRPCAddress(.tcp(host: "127.0.0.1", port: port))
        guard connected.error == 0 else { throw SpawnTestError() }
        defer { close(connected.fd) }
        XCTAssertNotEqual(fcntl(connected.fd, F_GETFL, 0) & O_NONBLOCK, 0)

        let accepted = accept(listener, nil, nil)
        guard accepted != -1 else { throw SpawnTestError() }
        close(accepted)
    }
}
