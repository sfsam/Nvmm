//
//  NvmmTests
//  CursorTrailTests.swift
//
//  Cursor shape and polygon-bridge geometry.
//

import CoreGraphics
import XCTest
@testable import Nvmm

final class CursorTrailTests: XCTestCase {
    func testBottomLeftDetectionIsExact() {
        XCTAssertTrue(CursorTrailGeometry.isBottomLeft(
            row: 23, column: 0, gridHeight: 24))
        XCTAssertFalse(CursorTrailGeometry.isBottomLeft(
            row: 22, column: 0, gridHeight: 24))
        XCTAssertFalse(CursorTrailGeometry.isBottomLeft(
            row: 23, column: 1, gridHeight: 24))
        XCTAssertFalse(CursorTrailGeometry.isBottomLeft(
            row: 0, column: 0, gridHeight: 0))
    }

    func testCursorRectsMatchRenderedShapes() {
        let cell = CGSize(width: 10, height: 20)

        XCTAssertEqual(
            CursorTrailGeometry.cursorRect(
                row: 2, column: 3, cellWidth: 1, shape: .block,
                cellSize: cell, lineThickness: 2),
            CGRect(x: 30, y: 40, width: 10, height: 20))

        XCTAssertEqual(
            CursorTrailGeometry.cursorRect(
                row: 2, column: 3, cellWidth: 2, shape: .block,
                cellSize: cell, lineThickness: 2),
            CGRect(x: 30, y: 40, width: 20, height: 20))

        XCTAssertEqual(
            CursorTrailGeometry.cursorRect(
                row: 2, column: 3, cellWidth: 1, shape: .vertical,
                cellSize: cell, lineThickness: 2),
            CGRect(x: 30, y: 40, width: 2, height: 20))

        XCTAssertEqual(
            CursorTrailGeometry.cursorRect(
                row: 2, column: 3, cellWidth: 1, shape: .horizontal,
                cellSize: cell, lineThickness: 2),
            CGRect(x: 30, y: 58, width: 10, height: 2))
    }

    func testHorizontalBridgeSpansCursorCenterLines() throws {
        let points = try XCTUnwrap(CursorTrailGeometry.bridge(
            from: CGRect(x: 0, y: 0, width: 10, height: 20),
            to: CGRect(x: 20, y: 0, width: 10, height: 20)))

        XCTAssertEqual(points, [
            CGPoint(x: 5, y: 0),
            CGPoint(x: 25, y: 0),
            CGPoint(x: 25, y: 20),
            CGPoint(x: 5, y: 20),
        ])
    }

    func testVerticalBarBridgeStaysNarrow() throws {
        let points = try XCTUnwrap(CursorTrailGeometry.bridge(
            from: CGRect(x: 0, y: 0, width: 2, height: 20),
            to: CGRect(x: 0, y: 40, width: 2, height: 20)))

        XCTAssertEqual(points, [
            CGPoint(x: 2, y: 10),
            CGPoint(x: 2, y: 50),
            CGPoint(x: 0, y: 50),
            CGPoint(x: 0, y: 10),
        ])
    }

    func testDiagonalBridgeUsesProjectedCursorWidth() throws {
        let points = try XCTUnwrap(CursorTrailGeometry.bridge(
            from: CGRect(x: 0, y: 0, width: 10, height: 20),
            to: CGRect(x: 20, y: 20, width: 10, height: 20)))

        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points[0].x + points[3].x, 10, accuracy: 0.0001)
        XCTAssertEqual(points[0].y + points[3].y, 20, accuracy: 0.0001)
        XCTAssertEqual(points[1].x + points[2].x, 50, accuracy: 0.0001)
        XCTAssertEqual(points[1].y + points[2].y, 60, accuracy: 0.0001)
    }

    func testLengthFractionKeepsDestinationEnd() throws {
        let source = CGRect(x: 0, y: 0, width: 10, height: 20)
        let destination = CGRect(x: 20, y: 0, width: 10, height: 20)
        let points = try XCTUnwrap(CursorTrailGeometry.bridge(
            from: source, to: destination, lengthFraction: 0.5))

        XCTAssertEqual(points, [
            CGPoint(x: 15, y: 0),
            CGPoint(x: 25, y: 0),
            CGPoint(x: 25, y: 20),
            CGPoint(x: 15, y: 20),
        ])
    }

    func testLengthFractionIsClamped() {
        let source = CGRect(x: 0, y: 0, width: 10, height: 20)
        let destination = CGRect(x: 20, y: 0, width: 10, height: 20)

        XCTAssertNil(CursorTrailGeometry.bridge(
            from: source, to: destination, lengthFraction: 0))
        XCTAssertNil(CursorTrailGeometry.bridge(
            from: source, to: destination, lengthFraction: -1))
        XCTAssertEqual(
            CursorTrailGeometry.bridge(
                from: source, to: destination, lengthFraction: 2),
            CursorTrailGeometry.bridge(from: source, to: destination))
    }

    func testCoincidentCursorRectsHaveNoBridge() {
        let rect = CGRect(x: 10, y: 20, width: 10, height: 20)
        XCTAssertNil(CursorTrailGeometry.bridge(from: rect, to: rect))
    }
}
