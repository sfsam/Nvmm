//
//  NvmmTests
//  SpawnTests.swift
//
//  Shell-quoting coverage: it produces single-quoted words, protects every shell
//  metacharacter, and round-trips unchanged back through /bin/sh.
//

import XCTest
@testable import Nvmm

final class SpawnTests: XCTestCase {

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
}
