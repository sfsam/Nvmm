//
//  NvmmTests
//  SettingsTests.swift
//
//  The defaults' resting values: which settings are on before the user has
//  ever opened the settings window. Registration is what makes the difference,
//  so it is checked rather than assumed.
//

import XCTest
@testable import Nvmm

final class SettingsTests: XCTestCase {

    /// The context-sensitive cursor and the progress bar are on unless they are
    /// turned off, which only holds because they are registered; every other
    /// setting is off until set, which is what an unwritten key already reads
    /// as.
    @MainActor
    func testRegisteredDefaults() {
        let defaults = UserDefaults.standard
        let keys = [Settings.contextSensitiveCursorKey,
                    Settings.openFilesInBuffersKey,
                    Settings.terminateAfterLastWindowKey,
                    Settings.titlebarAppearsTransparentKey,
                    Settings.verticalScrollbarKey,
                    Settings.progressBarKey,
                    Settings.cursorTrailEnabledKey,
                    Settings.cursorTrailLengthFractionKey,
                    Settings.cursorTrailOpacityKey]

        // The user's own values must not decide the outcome, and must survive
        // the test: only the registration domain is under test here.
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        for key in keys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in saved { defaults.set(value, forKey: key) }
        }

        Settings.registerDefaults()

        XCTAssertTrue(Settings.contextSensitiveCursor)
        XCTAssertTrue(Settings.progressBar)
        XCTAssertFalse(Settings.openFilesInBuffers)
        XCTAssertFalse(Settings.terminateAfterLastWindow)
        XCTAssertFalse(Settings.titlebarAppearsTransparent)
        XCTAssertFalse(Settings.verticalScrollbar)
        XCTAssertFalse(Settings.cursorTrailEnabled)
        XCTAssertEqual(
            Settings.cursorTrailLengthFraction, 0.55, accuracy: 0.001)
        XCTAssertEqual(Settings.cursorTrailOpacity, 0.55, accuracy: 0.001)
    }

    @MainActor
    func testCursorTrailValuesAreClamped() {
        let defaults = UserDefaults.standard
        let lengthKey = Settings.cursorTrailLengthFractionKey
        let opacityKey = Settings.cursorTrailOpacityKey
        let savedLength = defaults.object(forKey: lengthKey)
        let savedOpacity = defaults.object(forKey: opacityKey)
        defer {
            defaults.set(savedLength, forKey: lengthKey)
            defaults.set(savedOpacity, forKey: opacityKey)
        }

        defaults.set(-1, forKey: lengthKey)
        defaults.set(2, forKey: opacityKey)

        XCTAssertEqual(
            Settings.cursorTrailLengthFraction,
            Settings.cursorTrailMinimumValue)
        XCTAssertEqual(
            Settings.cursorTrailOpacity,
            Settings.cursorTrailMaximumValue)
    }

    @MainActor
    func testSettingsWindowContainsBoundCursorTrailSliders() throws {
        let controller = SettingsWindowController()
        let contentView = try XCTUnwrap(controller.window?.contentView)

        func descendants(of view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }

        let sliders = descendants(of: contentView)
            .compactMap { $0 as? NSSlider }
        XCTAssertEqual(sliders.count, 2)
        for slider in sliders {
            XCTAssertEqual(slider.minValue, Settings.cursorTrailMinimumValue)
            XCTAssertEqual(slider.maxValue, Settings.cursorTrailMaximumValue)
            XCTAssertNotNil(slider.infoForBinding(.value))
            XCTAssertNotNil(slider.infoForBinding(.enabled))
            XCTAssertTrue(slider.isContinuous)
        }

        let colorBoundLabels = descendants(of: contentView)
            .compactMap { $0 as? NSTextField }
            .filter { $0.infoForBinding(.textColor) != nil }
        XCTAssertEqual(colorBoundLabels.count, 2)
    }
}
