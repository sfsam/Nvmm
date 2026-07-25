//
//  NvmmTests
//  ProgressIndicatorTests.swift
//
//  Progress indicator color, geometry, and immediate visibility behavior.
//

import Cocoa
import XCTest
@testable import Nvmm

final class ProgressIndicatorTests: XCTestCase {

    @MainActor
    func testFillIsFixedBlueAndTrackIsTranslucent() {
        let indicator = ProgressIndicator(frame: .zero)
        guard let trackCG = indicator.layer?.sublayers?.first?.backgroundColor,
              let fillCG = indicator.layer?.sublayers?.last?.backgroundColor,
              let trackRGB = NSColor(cgColor: trackCG)?
                .usingColorSpace(.sRGB),
              let fillRGB = NSColor(cgColor: fillCG)?
                .usingColorSpace(.sRGB) else {
            return XCTFail("expected sRGB progress colors")
        }

        XCTAssertEqual(fillRGB.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(fillRGB.greenComponent, 122.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(fillRGB.blueComponent, 1, accuracy: 0.001)
        XCTAssertEqual(fillRGB.alphaComponent, 1, accuracy: 0.001)
        XCTAssertEqual(trackRGB.redComponent, fillRGB.redComponent,
                       accuracy: 0.001)
        XCTAssertEqual(trackRGB.greenComponent, fillRGB.greenComponent,
                       accuracy: 0.001)
        XCTAssertEqual(trackRGB.blueComponent, fillRGB.blueComponent,
                       accuracy: 0.001)
        XCTAssertEqual(trackRGB.alphaComponent, 0.4, accuracy: 0.001)
    }

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
