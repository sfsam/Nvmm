//
//  NvmmTests
//  MouseInputTests.swift
//
//  Coverage for passive mouse movement: repeated pixel motion within one cell
//  is suppressed, while cell, modifier, and active-state changes are retained.
//

import XCTest
@testable import Nvmm

final class MouseInputTests: XCTestCase {

    func testTrackerSuppressesDuplicateInput() {
        var tracker = MouseMoveTracker()
        let first = GridPoint(row: 2, column: 3)
        let second = GridPoint(row: 2, column: 4)

        XCTAssertTrue(tracker.shouldSend(
            location: first, modifiers: "", enabled: true))
        XCTAssertFalse(tracker.shouldSend(
            location: first, modifiers: "", enabled: true))
        XCTAssertTrue(tracker.shouldSend(
            location: second, modifiers: "", enabled: true))
        XCTAssertTrue(tracker.shouldSend(
            location: second, modifiers: "S-", enabled: true))
    }

    func testTrackerResetsWhenInactive() {
        var tracker = MouseMoveTracker()
        let location = GridPoint(row: 2, column: 3)

        XCTAssertTrue(tracker.shouldSend(
            location: location, modifiers: "", enabled: true))
        XCTAssertFalse(tracker.shouldSend(
            location: location, modifiers: "", enabled: false))
        XCTAssertTrue(tracker.shouldSend(
            location: location, modifiers: "", enabled: true))
        XCTAssertFalse(tracker.shouldSend(
            location: nil, modifiers: "", enabled: true))
        XCTAssertTrue(tracker.shouldSend(
            location: location, modifiers: "", enabled: true))
    }
}
