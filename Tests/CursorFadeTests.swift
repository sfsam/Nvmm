//
//  NvmmTests
//  CursorFadeTests.swift
//
//  Cursor blink fade timing.
//

import XCTest
@testable import Nvmm

final class CursorFadeTests: XCTestCase {
    func testFullFadeUsesFourStepsOver120Milliseconds() {
        let fade = CursorFade(from: 1, to: 0, start: 10,
                              phaseMilliseconds: 400)

        XCTAssertEqual(fade.duration, 0.12, accuracy: 0.0001)
        XCTAssertEqual(fade.timerInterval, 0.03, accuracy: 0.0001)
        XCTAssertEqual(fade.opacity(at: 10), 1)
        XCTAssertEqual(fade.opacity(at: 10.03), 0.75)
        XCTAssertEqual(fade.opacity(at: 10.06), 0.5)
        XCTAssertEqual(fade.opacity(at: 10.09), 0.25)
        XCTAssertEqual(fade.opacity(at: 10.12), 0)
        XCTAssertTrue(fade.isComplete(at: 10.12))
    }

    func testFadeInUsesTheSameProgression() {
        let fade = CursorFade(from: 0, to: 1, start: 5,
                              phaseMilliseconds: 250)

        XCTAssertEqual(fade.opacity(at: 5.03), 0.25)
        XCTAssertEqual(fade.opacity(at: 5.06), 0.5)
        XCTAssertEqual(fade.opacity(at: 5.09), 0.75)
        XCTAssertEqual(fade.opacity(at: 5.12), 1)
    }

    func testShortPhaseRetainsAStationaryHalf() {
        let fade = CursorFade(from: 1, to: 0, start: 0,
                              phaseMilliseconds: 100)

        XCTAssertEqual(fade.duration, 0.05, accuracy: 0.0001)
        XCTAssertEqual(fade.steps, 2)
        XCTAssertEqual(fade.opacity(at: 0.025), 0.5)
        XCTAssertEqual(fade.opacity(at: 0.05), 0)
    }

    func testLateSampleSkipsMissedSteps() {
        let fade = CursorFade(from: 1, to: 0, start: 0,
                              phaseMilliseconds: 400)

        XCTAssertEqual(fade.opacity(at: 0.10), 0.25)
        XCTAssertEqual(fade.opacity(at: 1), 0)
        XCTAssertTrue(fade.isComplete(at: 1))
    }
}
