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
        var request = CLIRequest(arguments: ["-c", "set number"],
                                 files: ["new file"],
                                 workingDirectory: "/tmp",
                                 forceNewWindow: false, wait: true)
        // An intentionally empty environment is valid; only a missing one
        // is not.
        request.environment = [:]
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

    // A v1 request has no environment key. It must decode — the field is a
    // Swift optional — so validation can name the version mismatch rather
    // than fail with a decode error.
    func testVersion1RequestDecodesButFailsValidation() throws {
        let json = """
        {"version": 1, "arguments": [], "files": [],
         "workingDirectory": "/tmp", "forceNewWindow": false, "wait": false}
        """
        let decoded = try JSONDecoder().decode(CLIRequest.self,
                                               from: Data(json.utf8))
        XCTAssertNil(decoded.environment)
        XCTAssertThrowsError(try decoded.validate()) { error in
            XCTAssertEqual(error as? CLIProtocolError, .incompatibleVersion)
        }
    }

    // v2 requires the environment. Without this, a new helper talking to an
    // old app would have the key silently ignored and report success while
    // reproducing the stale-environment bug.
    func testCurrentVersionRequestWithoutEnvironmentFailsValidation() throws {
        let json = """
        {"version": 2, "arguments": [], "files": [],
         "workingDirectory": "/tmp", "forceNewWindow": false, "wait": false}
        """
        let decoded = try JSONDecoder().decode(CLIRequest.self,
                                               from: Data(json.utf8))
        XCTAssertThrowsError(try decoded.validate()) { error in
            XCTAssertEqual(error as? CLIProtocolError, .missingEnvironment)
        }
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

    // The environment is all-or-nothing: an oversized request is rejected,
    // never sent with the environment quietly removed.
    func testEncodedLineRejectsAnOversizedRequest() throws {
        var request = CLIRequest(
            arguments: [], files: [], workingDirectory: "/tmp",
            forceNewWindow: false, wait: false)
        request.environment = ["KEY": "value"]

        let line = try request.encodedLine(
            maximumBytes: CLIProtocol.maximumRequestBytes)
        XCTAssertEqual(line.last, 0x0a)

        request.environment = ["BIG": String(repeating: "x", count: 512)]
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
