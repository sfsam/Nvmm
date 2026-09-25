//
//  NvmmTests
//  FontZoomTests.swift
//
//  Coverage for the editor window's one-point font zoom limits.
//

import XCTest
@testable import Nvmm

final class FontZoomTests: XCTestCase {

    /// Zoom moves by the delta within 6...72 points, bounds included, and
    /// refuses to step outside them.
    func testZoomStaysWithinBounds() {
        let cases: [(CGFloat, CGFloat, CGFloat?)] = [
            (15, 1, 16), (15, -1, 14),
            (71, 1, 72), (7, -1, 6),
            (72, 1, nil), (6, -1, nil),
        ]
        for (size, delta, expected) in cases {
            XCTAssertEqual(WindowController.zoomedFontSize(size, delta: delta),
                           expected, "\(size) \(delta)")
        }
    }
}
