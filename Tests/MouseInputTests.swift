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

        // Going inactive, or leaving the grid, forgets the last position, so
        // the same cell is sent again afterward.
        XCTAssertFalse(tracker.shouldSend(
            location: second, modifiers: "S-", enabled: false))
        XCTAssertTrue(tracker.shouldSend(
            location: second, modifiers: "S-", enabled: true))
        XCTAssertFalse(tracker.shouldSend(
            location: nil, modifiers: "S-", enabled: true))
        XCTAssertTrue(tracker.shouldSend(
            location: second, modifiers: "S-", enabled: true))
    }
}
