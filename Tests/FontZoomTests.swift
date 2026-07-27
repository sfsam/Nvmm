//
//  NvmmTests
//  FontZoomTests.swift
//
//  Coverage for the editor window's one-point font zoom limits.
//

import XCTest
@testable import Nvmm

final class FontZoomTests: XCTestCase {

    func testZoomChangesSizeByDelta() {
        XCTAssertEqual(WindowController.zoomedFontSize(15, delta: 1), 16)
        XCTAssertEqual(WindowController.zoomedFontSize(15, delta: -1), 14)
    }

    func testInclusiveBoundsAreAccepted() {
        XCTAssertEqual(WindowController.zoomedFontSize(71, delta: 1), 72)
        XCTAssertEqual(WindowController.zoomedFontSize(7, delta: -1), 6)
    }

    func testSizesOutsideBoundsAreRejected() {
        XCTAssertNil(WindowController.zoomedFontSize(72, delta: 1))
        XCTAssertNil(WindowController.zoomedFontSize(6, delta: -1))
    }
}
