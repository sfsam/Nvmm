//
//  NvmmTests
//  ScrollerTests.swift
//
//  The scrollbar's math: turning Neovim's viewport reports into a knob, and
//  clicks on the bar back into a line to scroll to.
//

import XCTest
@testable import Nvmm

final class ScrollerTests: XCTestCase {

    /// Before any viewport arrives, and for a report that says nothing (an
    /// empty buffer, or a window with no lines in it), the track is empty.
    func testDegenerateReportsGiveAnEmptyTrack() {
        var model = ScrollerModel()
        XCTAssertEqual(model.update(topline: 0, botline: 0, lineCount: 0), .empty)
        XCTAssertEqual(model.update(topline: 5, botline: 5, lineCount: 100), .empty)
        // A botline that has not caught up with topline is not usable either.
        XCTAssertEqual(model.update(topline: 9, botline: 4, lineCount: 100), .empty)
    }

    /// A buffer that fits on screen has nothing to scroll, so no knob is drawn
    /// and the bar is disabled.
    func testBufferThatFitsHasNoKnob() {
        var model = ScrollerModel()
        XCTAssertEqual(model.update(topline: 0, botline: 20, lineCount: 20), .empty)
        XCTAssertEqual(model.update(topline: 0, botline: 24, lineCount: 20), .empty)
    }

    /// At the top of a long buffer the knob is at 0 and covers the share of the
    /// buffer that is on screen.
    func testKnobAtTopOfBuffer() {
        var model = ScrollerModel()
        let knob = model.update(topline: 0, botline: 25, lineCount: 100)
        XCTAssertTrue(knob.enabled)
        XCTAssertEqual(knob.position, 0, accuracy: 1e-9)
        XCTAssertEqual(knob.proportion, 0.25, accuracy: 1e-9)
    }

    /// The position is the top line's share of the travel, which ends with the
    /// last line at the top of the window — not with the last line on screen.
    func testKnobPositionRunsToTheLastLine() {
        var model = ScrollerModel()
        _ = model.update(topline: 0, botline: 25, lineCount: 101)
        let middle = model.update(topline: 50, botline: 75, lineCount: 101)
        XCTAssertEqual(middle.position, 0.5, accuracy: 1e-9)

        let end = model.update(topline: 100, botline: 101, lineCount: 101)
        XCTAssertEqual(end.position, 1.0, accuracy: 1e-9)
    }

    /// A very long buffer would give a knob too small to grab, so it is
    /// floored.
    func testKnobHasAMinimumSize() {
        var model = ScrollerModel()
        let knob = model.update(topline: 0, botline: 25, lineCount: 1_000_000)
        XCTAssertEqual(knob.proportion, 0.01, accuracy: 1e-9)
    }

    /// The last screenful of a buffer holds fewer lines than the window fits,
    /// so taking that report at face value would shrink the knob as the user
    /// scrolled to the end. The window's height is remembered instead.
    func testKnobDoesNotShrinkAtTheEndOfTheBuffer() {
        var model = ScrollerModel()
        let full = model.update(topline: 0, botline: 25, lineCount: 100)
        XCTAssertEqual(model.visibleLines, 25)

        // The last five lines of the buffer: only five lines are drawn.
        let atEnd = model.update(topline: 95, botline: 100, lineCount: 100)
        XCTAssertEqual(model.visibleLines, 25)
        XCTAssertEqual(atEnd.proportion, full.proportion, accuracy: 1e-9)
    }

    /// A window that grew is a real change in height, even when the report
    /// comes from the end of the buffer.
    func testWindowGrowthUpdatesVisibleLines() {
        var model = ScrollerModel()
        _ = model.update(topline: 0, botline: 25, lineCount: 100)
        _ = model.update(topline: 60, botline: 100, lineCount: 100)
        XCTAssertEqual(model.visibleLines, 40)
    }

    /// So is a window that shrank, which shows as a shorter report with more
    /// buffer still below.
    func testWindowShrinkUpdatesVisibleLines() {
        var model = ScrollerModel()
        _ = model.update(topline: 0, botline: 40, lineCount: 100)
        _ = model.update(topline: 10, botline: 30, lineCount: 100)
        XCTAssertEqual(model.visibleLines, 20)
    }

    /// Dragging the knob or jumping into the track scrolls to the line the
    /// knob's position stands for, one-based.
    func testAbsoluteTargetLine() {
        var model = ScrollerModel()
        _ = model.update(topline: 0, botline: 25, lineCount: 101)
        XCTAssertEqual(model.targetLine(part: .absolute, position: 0), 1)
        XCTAssertEqual(model.targetLine(part: .absolute, position: 0.5), 51)
        XCTAssertEqual(model.targetLine(part: .absolute, position: 1), 101)
    }

    /// Paging moves by a window's worth of lines, stopping at either end.
    func testPagingTargetLines() {
        var model = ScrollerModel()
        _ = model.update(topline: 0, botline: 25, lineCount: 101)

        // Half way down: 51 is the top line, so paging moves ±25 lines.
        XCTAssertEqual(model.targetLine(part: .pageDown, position: 0.5), 76)
        XCTAssertEqual(model.targetLine(part: .pageUp, position: 0.5), 26)

        // Clamped at the ends rather than running past them.
        XCTAssertEqual(model.targetLine(part: .pageUp, position: 0), 1)
        XCTAssertEqual(model.targetLine(part: .pageDown, position: 1), 101)
    }

    /// A click on anything else (the legacy arrows) stays put.
    func testOtherPartsStayPut() {
        var model = ScrollerModel()
        _ = model.update(topline: 0, botline: 25, lineCount: 101)
        XCTAssertEqual(model.targetLine(part: .other, position: 0.5), 51)
    }

    /// A target line is never zero or past the end, whatever the position says.
    func testTargetLineIsClamped() {
        var model = ScrollerModel()
        _ = model.update(topline: 0, botline: 25, lineCount: 50)
        XCTAssertEqual(model.targetLine(part: .absolute, position: -1), 1)
        XCTAssertEqual(model.targetLine(part: .absolute, position: 2), 50)
    }

    /// With no viewport yet the model still answers, rather than dividing by a
    /// zero line count.
    func testTargetLineBeforeAnyViewport() {
        let model = ScrollerModel()
        XCTAssertEqual(model.targetLine(part: .absolute, position: 0.5), 1)
        XCTAssertEqual(model.targetLine(part: .pageDown, position: 0), 1)
    }
}
