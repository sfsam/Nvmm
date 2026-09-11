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

    /// A stream left at -1 is inherited, so the child must still hold it: the
    /// spawn closes every descriptor no file action names.
    func testStreamsLeftUnsetAreInheritedByTheChild() async throws {
        let result = Spawn.spawn(
            path: "/bin/sh",
            argv: ["/bin/sh", "-c",
                   "[ -e /dev/fd/0 ] && [ -e /dev/fd/1 ] && [ -e /dev/fd/2 ]"],
            env: [], workingDirectory: nil, streams: Spawn.Streams())
        XCTAssertEqual(result.error, 0)

        let termination = await Spawn.wait(forChild: result.pid)

        XCTAssertEqual(termination, .exited(status: 0))
    }

    /// A stream inherited from a descriptor this process has already closed
    /// stays closed in the child, rather than failing the spawn.
    func testAClosedStreamIsInheritedAsClosed() async throws {
        let saved = dup(0)
        defer {
            if saved != -1 {
                dup2(saved, 0)
                close(saved)
            }
        }
        close(0)

        let result = Spawn.spawn(
            path: "/bin/sh",
            argv: ["/bin/sh", "-c", "! [ -e /dev/fd/0 ]"],
            env: [], workingDirectory: nil, streams: Spawn.Streams())
        XCTAssertEqual(result.error, 0)

        let termination = await Spawn.wait(forChild: result.pid)

        XCTAssertEqual(termination, .exited(status: 0))
    }

    /// An entry replaces the inherited value for its key. Two entries for one
    /// key would leave the inherited one first, which is the one a `getenv`
    /// in the child answers with.
    func testEnvironmentEntryReplacesTheInheritedValue() async throws {
        // A key the parent exports itself, so an entry that joins the
        // inherited one rather than replacing it leaves two of them.
        let key = "HOME"
        let replacement = "/nvmm-spawn-test"
        let inherited = try XCTUnwrap(ProcessInfo.processInfo.environment[key])
        XCTAssertNotEqual(inherited, replacement)
        // `env` reports what it was handed. A shell would rebuild its own
        // environment first, and report one entry either way.
        let output = Spawn.openPipe()
        XCTAssertEqual(output.error, 0)
        defer { close(output.pipe.readEnd) }
        let result = Spawn.spawn(
            path: "/usr/bin/env", argv: ["/usr/bin/env"],
            env: ["\(key)=\(replacement)"], workingDirectory: nil,
            streams: Spawn.Streams(output: output.pipe.writeEnd))
        close(output.pipe.writeEnd)
        XCTAssertEqual(result.error, 0)

        var reported = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(output.pipe.readEnd, &buffer, buffer.count)
            if count <= 0 { break }
            reported.append(contentsOf: buffer[0..<count])
        }
        let termination = await Spawn.wait(forChild: result.pid)
        XCTAssertEqual(termination, .exited(status: 0))

        let entries = String(decoding: reported, as: UTF8.self)
            .split(separator: "\n").filter { $0.hasPrefix("\(key)=") }
        XCTAssertEqual(entries, ["\(key)=\(replacement)"])
    }

    /// A base environment replaces the parent environment completely, and an
    /// `env` entry still overrides the base.
    func testBaseEnvironmentReplacesTheParentEnvironment() async throws {
        // HOME is exported by the parent; its absence from the child proves
        // the base replaced the parent environment rather than merged in.
        XCTAssertNotNil(ProcessInfo.processInfo.environment["HOME"])
        let output = Spawn.openPipe()
        XCTAssertEqual(output.error, 0)
        defer { close(output.pipe.readEnd) }
        let result = Spawn.spawn(
            path: "/usr/bin/env", argv: ["/usr/bin/env"],
            env: ["OVERRIDE=b"],
            base: ["ONLY": "a", "OVERRIDE": "a"],
            workingDirectory: nil,
            streams: Spawn.Streams(output: output.pipe.writeEnd))
        close(output.pipe.writeEnd)
        XCTAssertEqual(result.error, 0)

        var reported = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(output.pipe.readEnd, &buffer, buffer.count)
            if count <= 0 { break }
            reported.append(contentsOf: buffer[0..<count])
        }
        let termination = await Spawn.wait(forChild: result.pid)
        XCTAssertEqual(termination, .exited(status: 0))

        let entries = Set(String(decoding: reported, as: UTF8.self)
            .split(separator: "\n").map(String.init))
        XCTAssertEqual(entries, ["ONLY=a", "OVERRIDE=b"])
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
