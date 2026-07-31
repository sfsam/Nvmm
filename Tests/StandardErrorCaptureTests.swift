//
//  NvmmTests
//  StandardErrorCaptureTests.swift
//
//  Bounded asynchronous pipe-drain coverage for Neovim stderr.
//

import Darwin
import Foundation
import XCTest
@testable import Nvmm

private nonisolated final class StandardErrorRecorder:
    @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [StandardErrorCapture.Output] = []
    private let expectation: XCTestExpectation

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func append(_ output: StandardErrorCapture.Output) {
        lock.lock()
        outputs.append(output)
        lock.unlock()
        expectation.fulfill()
    }

    func snapshot() -> [StandardErrorCapture.Output] {
        lock.lock()
        defer { lock.unlock() }
        return outputs
    }
}

final class StandardErrorCaptureTests: XCTestCase {
    func testCaptureDecodesAtEndOfFile() throws {
        let opened = Spawn.openPipe()
        XCTAssertEqual(opened.error, 0)
        let received = expectation(description: "stderr output")
        let recorder = StandardErrorRecorder(expectation: received)
        let capture = StandardErrorCapture(
            fileDescriptor: opened.pipe.readEnd,
            handler: recorder.append)

        let bytes = Array("diagnostic 😀\n".utf8)
        let split = bytes.firstIndex(of: 0xf0)! + 2
        XCTAssertEqual(
            writeBytes(Array(bytes[..<split]), to: opened.pipe.writeEnd),
            split)
        XCTAssertEqual(
            writeBytes(Array(bytes[split...]), to: opened.pipe.writeEnd),
            bytes.count - split)
        close(opened.pipe.writeEnd)

        wait(for: [received], timeout: 2)
        XCTAssertEqual(
            recorder.snapshot(),
            [.init(text: "diagnostic 😀", isTruncated: false)])
        withExtendedLifetime(capture) {}
    }

    func testCaptureBoundsRetainedOutput() throws {
        let opened = Spawn.openPipe()
        XCTAssertEqual(opened.error, 0)
        let received = expectation(description: "stderr output")
        let recorder = StandardErrorRecorder(expectation: received)
        let capture = StandardErrorCapture(
            fileDescriptor: opened.pipe.readEnd,
            maximumBytes: 8,
            handler: recorder.append)

        XCTAssertEqual(
            writeBytes(Array("1234567890".utf8), to: opened.pipe.writeEnd),
            10)
        close(opened.pipe.writeEnd)

        wait(for: [received], timeout: 2)
        XCTAssertEqual(
            recorder.snapshot(),
            [.init(text: "12345678", isTruncated: true)])
        withExtendedLifetime(capture) {}
    }

    private func writeBytes(_ bytes: [UInt8], to descriptor: Int32) -> Int {
        bytes.withUnsafeBytes {
            write(descriptor, $0.baseAddress, $0.count)
        }
    }
}
