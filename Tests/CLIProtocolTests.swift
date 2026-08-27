//
//  NvmmTests
//  CLIProtocolTests.swift
//

import Darwin
import XCTest
@testable import Nvmm

final class CLIProtocolTests: XCTestCase {

    func testParsesReferenceOptionSurface() throws {
        let parsed = try CLIArguments.parse([
            "-dR", "-cset number", "--clean", "-N", "--wait",
            "+42", "+/needle", "one", "two",
        ])

        XCTAssertEqual(parsed.arguments, [
            "-d", "-R", "-c", "set number", "--clean", "+42", "+/needle",
        ])
        XCTAssertEqual(parsed.files, ["one", "two"])
        XCTAssertTrue(parsed.forceNewWindow)
        XCTAssertTrue(parsed.wait)
        XCTAssertTrue(parsed.needsNewWindow)
    }

    func testSeparateCommandValueAndShortCluster() throws {
        let parsed = try CLIArguments.parse(["-op", "-c", "colorscheme blue"])

        XCTAssertEqual(parsed.arguments,
                       ["-o", "-p", "-c", "colorscheme blue"])
    }

    func testDoubleDashMakesEveryFollowingArgumentAFile() throws {
        let parsed = try CLIArguments.parse(["--", "-literal", "+quit"])

        XCTAssertEqual(parsed.files, ["-literal", "+quit"])
        XCTAssertTrue(parsed.arguments.isEmpty)
        XCTAssertFalse(parsed.needsNewWindow)
    }

    func testHelpIsClientSide() throws {
        let parsed = try CLIArguments.parse(["-h"])

        XCTAssertTrue(parsed.showHelp)
        XCTAssertTrue(parsed.arguments.isEmpty)
        XCTAssertFalse(parsed.needsNewWindow)
    }

    func testUnknownOptionFails() {
        XCTAssertThrowsError(try CLIArguments.parse(["--headless"])) { error in
            XCTAssertEqual(error as? CLIArgumentError,
                           .unknownOption("--headless"))
        }
    }

    func testMissingCommandFails() {
        XCTAssertThrowsError(try CLIArguments.parse(["-c"])) { error in
            XCTAssertEqual(error as? CLIArgumentError, .missingValue("-c"))
        }
    }

    func testRequestRoundTripAndValidation() throws {
        let request = CLIRequest(arguments: ["-c", "set number"],
                                 files: ["new file"],
                                 workingDirectory: "/tmp",
                                 forceNewWindow: false, wait: true)
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(CLIRequest.self, from: encoded)

        XCTAssertEqual(decoded, request)
        XCTAssertNoThrow(try decoded.validate())
        XCTAssertTrue(decoded.needsNewWindow)
    }

    func testRequestRejectsUnknownForwardedArgument() {
        let request = CLIRequest(arguments: ["--headless"], files: [],
                                 workingDirectory: "/tmp",
                                 forceNewWindow: false, wait: false)

        XCTAssertThrowsError(try request.validate()) { error in
            XCTAssertEqual(error as? CLIProtocolError,
                           .invalidForwardedArguments)
        }
    }

    // An option the helper consumes itself is not something Neovim may be
    // given, so a request naming one is not a request the helper built.
    func testRequestRejectsLocallyConsumedOption() {
        let request = CLIRequest(arguments: ["--wait"], files: [],
                                 workingDirectory: "/tmp",
                                 forceNewWindow: false, wait: false)

        XCTAssertThrowsError(try request.validate()) { error in
            XCTAssertEqual(error as? CLIProtocolError,
                           .invalidForwardedArguments)
        }
    }

    func testRequestRejectsCommandWithoutItsValue() {
        let request = CLIRequest(arguments: ["-c"], files: [],
                                 workingDirectory: "/tmp",
                                 forceNewWindow: false, wait: false)

        XCTAssertThrowsError(try request.validate()) { error in
            XCTAssertEqual(error as? CLIProtocolError,
                           .invalidForwardedArguments)
        }
    }

    func testRequestCarriesAndValidatesEnvironment() throws {
        var request = CLIRequest(
            arguments: [], files: [], workingDirectory: "/tmp",
            forceNewWindow: false, wait: false)
        request.environment = ["PATH": "/usr/bin", "EMPTY": ""]
        try request.validate()

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(CLIRequest.self, from: data)
        XCTAssertEqual(decoded, request)
    }

    // A request from an older helper has no environment key. It must still
    // decode and validate, so the field cannot be required.
    func testRequestWithoutEnvironmentKeyStillDecodes() throws {
        let json = """
        {"version": 1, "arguments": [], "files": [],
         "workingDirectory": "/tmp", "forceNewWindow": false, "wait": false}
        """
        let decoded = try JSONDecoder().decode(CLIRequest.self,
                                               from: Data(json.utf8))
        XCTAssertNil(decoded.environment)
        try decoded.validate()
    }

    // A real environ cannot hold these shapes, so a request that does was
    // not built by the helper.
    func testRequestRejectsMalformedEnvironmentEntries() {
        let bad: [[String: String]] = [
            ["": "value"], ["A=B": "value"],
            ["A\0B": "value"], ["KEY": "a\0b"],
        ]
        for environment in bad {
            var request = CLIRequest(
                arguments: [], files: [], workingDirectory: "/tmp",
                forceNewWindow: false, wait: false)
            request.environment = environment
            XCTAssertThrowsError(try request.validate()) { error in
                XCTAssertEqual(error as? CLIProtocolError, .invalidEnvironment)
            }
        }
    }

    func testEncodedLineDropsOnlyAnOversizedEnvironment() throws {
        var request = CLIRequest(
            arguments: [], files: [], workingDirectory: "/tmp",
            forceNewWindow: false, wait: false)
        request.environment = ["KEY": "value"]

        let kept = try request.encodedLine(
            maximumBytes: CLIProtocol.maximumRequestBytes)
        XCTAssertFalse(kept.droppedEnvironment)
        XCTAssertEqual(kept.data.last, 0x0a)

        request.environment = ["BIG": String(repeating: "x", count: 512)]
        let dropped = try request.encodedLine(maximumBytes: 256)
        XCTAssertTrue(dropped.droppedEnvironment)
        let decoded = try JSONDecoder().decode(
            CLIRequest.self, from: dropped.data.dropLast())
        XCTAssertNil(decoded.environment)

        request.environment = nil
        request.files = [String(repeating: "y", count: 512)]
        XCTAssertThrowsError(
            try request.encodedLine(maximumBytes: 256)) { error in
            XCTAssertEqual(error as? CLIProtocolError, .oversizedRequest)
        }
    }

    func testFileResolutionIsLexicalAndAllowsMissingPaths() {
        let request = CLIRequest(arguments: [], files: ["a/../new", "/x/../y"],
                                 workingDirectory: "/tmp/project",
                                 forceNewWindow: false, wait: false)

        XCTAssertEqual(request.absoluteFiles, ["/tmp/project/new", "/y"])
    }

    func testEndpointFitsUnixSocketAndSeparatesChannels() {
        let debug = CLIProtocol.endpointPath(channel: "debug")
        let stable = CLIProtocol.endpointPath(channel: "stable")

        XCTAssertNotEqual(debug, stable)
        XCTAssertLessThan(debug.utf8.count, CLIProtocol.unixPathCapacity)
        XCTAssertLessThan(stable.utf8.count, CLIProtocol.unixPathCapacity)
    }

    // The endpoint lives in the per-user temporary directory, which the system
    // owns at 0700, rather than in world-writable /tmp.
    func testEndpointDirectoryIsPrivateToTheUser() throws {
        let directory = CLIProtocol.endpointDirectory()
        XCTAssertFalse(directory.hasPrefix("/tmp/"))

        try CLIEndpoint.prepareDirectory(directory)
        var info = stat()
        XCTAssertEqual(lstat(directory, &info), 0)
        XCTAssertEqual(info.st_uid, geteuid())
        XCTAssertEqual(info.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO), S_IRWXU)
    }
}
