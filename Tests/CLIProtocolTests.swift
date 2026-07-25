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
