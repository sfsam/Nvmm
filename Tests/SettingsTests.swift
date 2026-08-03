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
                    Settings.cursorTrailOpacityKey,
                    Settings.fontThicknessKey]

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
        XCTAssertEqual(Settings.fontThickness, 50)
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
    func testFontThicknessIsClamped() {
        let defaults = UserDefaults.standard
        let key = Settings.fontThicknessKey
        let saved = defaults.object(forKey: key)
        defer { defaults.set(saved, forKey: key) }

        defaults.set(-1, forKey: key)
        XCTAssertEqual(Settings.fontThickness, 0)
        defaults.set(256, forKey: key)
        XCTAssertEqual(Settings.fontThickness, 255)
    }

    func testFontThicknessDetentMapping() {
        XCTAssertEqual(Settings.fontThicknessLevel(for: 0), 0)
        XCTAssertEqual(Settings.fontThicknessLevel(for: 25), 1)
        XCTAssertEqual(Settings.fontThicknessLevel(for: 50), 1)
        XCTAssertEqual(Settings.fontThicknessLevel(for: 100), 2)
        XCTAssertEqual(Settings.fontThicknessLevel(for: 150), 2)
        XCTAssertEqual(Settings.fontThicknessLevel(for: 200), 3)
        XCTAssertEqual(Settings.fontThicknessLevel(for: 255), 3)
        XCTAssertEqual(Settings.fontThicknessValue(for: -1), 0)
        XCTAssertEqual(Settings.fontThicknessValue(for: 0), 0)
        XCTAssertEqual(Settings.fontThicknessValue(for: 1), 50)
        XCTAssertEqual(Settings.fontThicknessValue(for: 2), 150)
        XCTAssertEqual(Settings.fontThicknessValue(for: 3), 250)
        XCTAssertEqual(Settings.fontThicknessValue(for: 4), 250)
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
        let cursorSliders = sliders.filter {
            $0.identifier?.rawValue != "fontThickness"
        }
        XCTAssertEqual(sliders.count, 3)
        XCTAssertEqual(cursorSliders.count, 2)
        for slider in cursorSliders {
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

    @MainActor
    func testFontThicknessSliderDebouncesAndAppliesDetents() async throws {
        let defaults = UserDefaults.standard
        let keys = [Settings.fontThicknessKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved { defaults.set(value, forKey: key) }
        }
        defaults.set(50, forKey: Settings.fontThicknessKey)

        let controller = SettingsWindowController()
        let content = try XCTUnwrap(controller.window?.contentView)
        func descendants(of view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        let views = descendants(of: content)
        let slider = try XCTUnwrap(views.compactMap { $0 as? NSSlider }
            .first { $0.identifier?.rawValue == "fontThickness" })

        XCTAssertEqual(slider.minValue, 0)
        XCTAssertEqual(slider.maxValue, 3)
        XCTAssertEqual(slider.numberOfTickMarks, 4)
        XCTAssertTrue(slider.allowsTickMarkValuesOnly)
        XCTAssertTrue(slider.isContinuous)
        XCTAssertEqual(slider.integerValue, 1)
        let action = try XCTUnwrap(slider.action)
        XCTAssertTrue(controller.responds(to: action))

        func sendThicknessAction() {
            _ = controller.perform(action, with: slider)
        }

        slider.integerValue = 2
        sendThicknessAction()
        slider.integerValue = 3
        sendThicknessAction()
        XCTAssertEqual(Settings.fontThickness, 50)

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(Settings.fontThickness, 250)

        slider.integerValue = 0
        sendThicknessAction()
        controller.close()
        XCTAssertEqual(Settings.fontThickness, 250)

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(Settings.fontThickness, 0)
    }
}
