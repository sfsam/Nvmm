//
//  NvmmTests
//  ProgressIndicatorTests.swift
//
//  Progress indicator geometry, accessibility, and immediate visibility
//  behavior.
//

import Cocoa
import XCTest
@testable import Nvmm

final class ProgressIndicatorTests: XCTestCase {

    @MainActor
    func testImmediateProgressAndVisibilityUpdateLayerState() {
        let indicator = ProgressIndicator(
            frame: NSRect(x: 0, y: 0, width: 100, height: 2))
        indicator.layoutSubtreeIfNeeded()
        indicator.setProgress(40, animated: false)
        indicator.setVisible(true, animated: false)

        XCTAssertEqual(indicator.accessibilityValue() as? Double, 40)
        XCTAssertEqual(indicator.accessibilityRole(), .progressIndicator)
        XCTAssertEqual(indicator.accessibilityMinValue() as? Double, 0)
        XCTAssertEqual(indicator.accessibilityMaxValue() as? Double, 100)
        XCTAssertEqual(indicator.layer?.sublayers?.first?.frame.width, 100)
        XCTAssertEqual(indicator.layer?.sublayers?.last?.bounds.width, 40)
        XCTAssertFalse(indicator.isHidden)
        XCTAssertEqual(indicator.alphaValue, 1)

        indicator.setVisible(false, animated: false)
        XCTAssertTrue(indicator.isHidden)
        XCTAssertEqual(indicator.alphaValue, 0)
    }

    @MainActor
    func testProgressDoesNotAnimateUntilIndicatorIsVisible() {
        let indicator = ProgressIndicator(
            frame: NSRect(x: 0, y: 0, width: 100, height: 2))
        indicator.layoutSubtreeIfNeeded()

        indicator.setProgress(100, animated: false)
        indicator.setProgress(0)

        let fill = indicator.layer?.sublayers?.last
        XCTAssertEqual(fill?.bounds.width, 0)
        XCTAssertNil(fill?.animation(forKey: "progress"))
    }
}
