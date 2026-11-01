//
//  NvmmTests
//  MouseInputTests.swift
//
//  Coverage for passive mouse movement: repeated pixel motion within one cell
//  is suppressed, while cell, modifier, and active-state changes are retained.
//  Also covers trackpad scrolling, which must treat both directions alike.
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

    func testScrollNeedsAFullCellInEitherDirection() {
        let cell = SIMD2<Double>(8, 17)

        // A fresh move of less than a cell sends nothing, either way.
        let small: [SIMD2<Double>] = [
            [0, -1], [0, 16], [0, -16], [7, 0], [-7, 0],
        ]
        for delta in small {
            var scroll = ScrollAccumulator()
            XCTAssertEqual(scroll.cells(adding: delta, cellSize: cell), [0, 0])
        }

        // Equal moves up and down scroll the same number of cells.
        var scroll = ScrollAccumulator()
        XCTAssertEqual(scroll.cells(adding: [0, 18], cellSize: cell), [0, 1])
        scroll.reset()
        XCTAssertEqual(scroll.cells(adding: [0, -18], cellSize: cell), [0, -1])

        // The part short of a cell carries over to the next event.
        XCTAssertEqual(scroll.cells(adding: [0, -16], cellSize: cell), [0, -1])
        XCTAssertEqual(scroll.cells(adding: [-9, 0], cellSize: cell), [-1, 0])

        // A small back-and-forth jitter sends nothing.
        scroll.reset()
        XCTAssertEqual(scroll.cells(adding: [0, -1], cellSize: cell), [0, 0])
        XCTAssertEqual(scroll.cells(adding: [0, 2], cellSize: cell), [0, 0])
    }

    func testScrollTurningAroundNeedsOneCell() {
        let cell = SIMD2<Double>(8, 17)
        var scroll = ScrollAccumulator()

        // 33 points down is one cell with 16 left over. Going back up does
        // not first have to undo those 16: one cell up is one step.
        XCTAssertEqual(scroll.cells(adding: [0, -33], cellSize: cell), [0, -1])
        XCTAssertEqual(scroll.cells(adding: [0, 2], cellSize: cell), [0, 0])
        XCTAssertEqual(scroll.cells(adding: [0, 15], cellSize: cell), [0, 1])

        // The same holds the other way, and on the horizontal axis.
        scroll.reset()
        XCTAssertEqual(scroll.cells(adding: [15, 33], cellSize: cell), [1, 1])
        XCTAssertEqual(scroll.cells(adding: [-8, -17], cellSize: cell),
                       [-1, -1])
    }
}
