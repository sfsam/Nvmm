//
//  NvmmTests
//  CursorTrailTests.swift
//
//  Cursor trail profiles and cursor-shape geometry.
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

    func testStrengthProfilesIncreaseMonotonically() throws {
        XCTAssertNil(CursorTrailProfile.profile(for: 0))
        XCTAssertNil(CursorTrailProfile.profile(for: -1))

        let subtle = try XCTUnwrap(CursorTrailProfile.profile(for: 1))
        let normal = try XCTUnwrap(CursorTrailProfile.profile(for: 2))
        let strong = try XCTUnwrap(CursorTrailProfile.profile(for: 3))
        XCTAssertEqual(CursorTrailProfile.profile(for: 4), strong)

        XCTAssertLessThan(subtle.lengthFraction, normal.lengthFraction)
        XCTAssertLessThan(normal.lengthFraction, strong.lengthFraction)
        XCTAssertLessThan(subtle.opacity, normal.opacity)
        XCTAssertLessThan(normal.opacity, strong.opacity)
        XCTAssertLessThan(subtle.duration, normal.duration)
        XCTAssertLessThan(normal.duration, strong.duration)
        XCTAssertLessThan(subtle.cornerSpeed, normal.cornerSpeed)
        XCTAssertLessThan(normal.cornerSpeed, strong.cornerSpeed)
    }

    func testStrengthProfilesHaveCanonicalValues() {
        XCTAssertEqual(
            CursorTrailProfile.profile(for: 1),
            CursorTrailProfile(lengthFraction: 0.35, opacity: 0.35,
                               duration: 0.035, cornerSpeed: 1.5))
        XCTAssertEqual(
            CursorTrailProfile.profile(for: 2),
            CursorTrailProfile(lengthFraction: 0.7, opacity: 0.6,
                               duration: 0.05, cornerSpeed: 2))
        XCTAssertEqual(
            CursorTrailProfile.profile(for: 3),
            CursorTrailProfile(lengthFraction: 1, opacity: 0.85,
                               duration: 0.08, cornerSpeed: 2.75))
    }
}
