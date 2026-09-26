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

    /// Defaults registered as enabled are on unless explicitly turned off;
    /// every other Boolean setting is off until set.
    @MainActor
    func testRegisteredDefaults() {
        let defaults = UserDefaults.standard
        let keys = [Settings.appearanceModeKey,
                    Settings.contextSensitiveCursorKey,
                    Settings.nativePowerlineSymbolsKey,
                    Settings.openFilesInBuffersKey,
                    Settings.terminateAfterLastWindowKey,
                    Settings.titlebarAppearsTransparentKey,
                    Settings.documentProxyIconKey,
                    Settings.verticalScrollbarKey,
                    Settings.progressBarKey,
                    Settings.cursorTrailStrengthKey,
                    Settings.fontThicknessKey,
                    Settings.ligaturesKey,
                    Settings.useCustomNeovimKey,
                    Settings.customNeovimPathKey]

        // The user's own values must not decide the outcome, and must survive
        // the test: only the registration domain is under test here.
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        for key in keys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in saved { defaults.set(value, forKey: key) }
        }

        Settings.registerDefaults()

        XCTAssertEqual(Settings.appearanceMode, .system)
        XCTAssertTrue(Settings.contextSensitiveCursor)
        XCTAssertTrue(Settings.nativePowerlineSymbols)
        XCTAssertTrue(Settings.progressBar)
        XCTAssertFalse(Settings.openFilesInBuffers)
        XCTAssertFalse(Settings.terminateAfterLastWindow)
        XCTAssertFalse(Settings.titlebarAppearsTransparent)
        XCTAssertFalse(Settings.documentProxyIcon)
        XCTAssertFalse(Settings.verticalScrollbar)
        XCTAssertEqual(Settings.cursorTrailStrength, 0)
        XCTAssertEqual(Settings.fontThickness, 50)
        XCTAssertFalse(Settings.ligatures)
        XCTAssertFalse(Settings.useCustomNeovim)
        XCTAssertEqual(Settings.customNeovimPath, "")
    }

    @MainActor
    func testInvalidAppearanceModeFallsBackToSystem() {
        let defaults = UserDefaults.standard
        let key = Settings.appearanceModeKey
        let saved = defaults.object(forKey: key)
        defer { defaults.set(saved, forKey: key) }

        defaults.set(99, forKey: key)

        XCTAssertEqual(Settings.appearanceMode, .system)
    }

    @MainActor
    func testAppearanceMappings() throws {
        XCTAssertNil(editorAppearanceName(mode: .system,
                                           neovimBackgroundOption: .dark))
        XCTAssertEqual(editorAppearanceName(mode: .light,
                                             neovimBackgroundOption: .dark),
                       .aqua)
        XCTAssertEqual(editorAppearanceName(mode: .dark,
                                             neovimBackgroundOption: .light),
                       .darkAqua)
        XCTAssertEqual(editorAppearanceName(mode: .neovimBackground,
                                             neovimBackgroundOption: .light),
                       .aqua)
        XCTAssertEqual(editorAppearanceName(mode: .neovimBackground,
                                             neovimBackgroundOption: .dark),
                       .darkAqua)
        XCTAssertNil(editorAppearanceName(mode: .neovimBackground,
                                           neovimBackgroundOption: nil))

        // The effective system appearance, as published to Neovim.
        let cases: [(NSAppearance.Name, Bool, OSAppearance)] = [
            (.aqua, false, .light),
            (.darkAqua, false, .dark),
            (.aqua, true, .highContrastLight),
            (.darkAqua, true, .highContrastDark),
        ]
        for (name, increasedContrast, expected) in cases {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            XCTAssertEqual(
                osAppearance(
                    appearance, increasedContrast: increasedContrast),
                expected)
        }
    }

    @MainActor
    func testRangedSettingsAreClamped() {
        let defaults = UserDefaults.standard
        let keys = [Settings.cursorTrailStrengthKey, Settings.fontThicknessKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved { defaults.set(value, forKey: key) }
        }

        defaults.set(-1, forKey: Settings.cursorTrailStrengthKey)
        XCTAssertEqual(Settings.cursorTrailStrength, 0)
        defaults.set(4, forKey: Settings.cursorTrailStrengthKey)
        XCTAssertEqual(Settings.cursorTrailStrength, 3)

        defaults.set(-1, forKey: Settings.fontThicknessKey)
        XCTAssertEqual(Settings.fontThickness, 0)
        defaults.set(256, forKey: Settings.fontThicknessKey)
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
    func testSettingsWindowContainsBoundControls() throws {
        let controller = SettingsWindowController()
        let contentView = try XCTUnwrap(controller.window?.contentView)

        func descendants(of view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }

        let views = descendants(of: contentView)
        let popup = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }
            .first { $0.identifier?.rawValue == "appearanceMode" })
        XCTAssertEqual(popup.itemTitles,
                       ["System", "Light", "Dark",
                        "Use Neovim ‘background’ option"])
        XCTAssertNotNil(popup.action)

        let sliders = views.compactMap { $0 as? NSSlider }
        XCTAssertEqual(sliders.count, 2)
        let cursorSlider = try XCTUnwrap(sliders.first {
            $0.identifier?.rawValue == "cursorTrailStrength"
        })
        XCTAssertEqual(cursorSlider.minValue, 0)
        XCTAssertEqual(cursorSlider.maxValue, 3)
        XCTAssertEqual(cursorSlider.numberOfTickMarks, 4)
        XCTAssertTrue(cursorSlider.allowsTickMarkValuesOnly)
        XCTAssertTrue(cursorSlider.isContinuous)
        XCTAssertNotNil(cursorSlider.infoForBinding(.value))

        let buttons = views.compactMap { $0 as? NSButton }
        let proxyIcon = try XCTUnwrap(buttons.first {
            $0.title == "Document proxy icon in title bar"
        })
        XCTAssertNotNil(proxyIcon.infoForBinding(.value))
    }

    /// The Neovim popup lists Bundled, the chosen custom nvim when there is
    /// one, and Other…, selects the current choice, and records a new one.
    @MainActor
    func testNeovimPopupFollowsDefaults() throws {
        let defaults = UserDefaults.standard
        let keys = [Settings.useCustomNeovimKey, Settings.customNeovimPathKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        for key in keys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in saved { defaults.set(value, forKey: key) }
        }

        // A control holds its target weakly, so each controller is kept for
        // the test's length or its popup's actions would go nowhere.
        var controllers: [SettingsWindowController] = []
        func popup() throws -> NSPopUpButton {
            let controller = SettingsWindowController()
            controllers.append(controller)
            func descendants(of view: NSView) -> [NSView] {
                view.subviews + view.subviews.flatMap(descendants)
            }
            let content = try XCTUnwrap(controller.window?.contentView)
            return try XCTUnwrap(descendants(of: content)
                .compactMap { $0 as? NSPopUpButton }
                .first { $0.identifier?.rawValue == "neovim" })
        }
        func choose(_ tag: Int, in popup: NSPopUpButton) {
            popup.selectItem(withTag: tag)
            _ = popup.sendAction(popup.action, to: popup.target)
        }

        let bundledOnly = try popup()
        XCTAssertEqual(bundledOnly.itemArray.map(\.tag), [0, 0, 2])
        XCTAssertTrue(bundledOnly.itemArray[1].isSeparatorItem)
        XCTAssertTrue(bundledOnly.itemArray[0].title.hasPrefix("Bundled"))
        XCTAssertEqual(bundledOnly.itemArray[2].title, "Other…")
        XCTAssertEqual(bundledOnly.selectedTag(), 0)

        defaults.set("/opt/homebrew/bin/nvim",
                     forKey: Settings.customNeovimPathKey)
        let withPath = try popup()
        XCTAssertEqual(withPath.itemTitles.filter { !$0.isEmpty }.count, 3)
        let custom = try XCTUnwrap(withPath.item(at:
            withPath.indexOfItem(withTag: 1)))
        XCTAssertEqual(custom.title, "/opt/homebrew/bin/nvim")
        XCTAssertEqual(withPath.selectedTag(), 0)

        // The popup matches the appearance popup, and a longer path is
        // shortened rather than widening both.
        func widths(_ popup: NSPopUpButton) throws -> (CGFloat, CGFloat) {
            popup.window?.layoutIfNeeded()
            let appearance = try XCTUnwrap(
                popup.superview?.subviews.compactMap { $0 as? NSPopUpButton }
                    .first { $0.identifier?.rawValue == "appearanceMode" })
            return (popup.frame.width, appearance.frame.width)
        }
        let (shortWidth, shortAppearance) = try widths(withPath)
        XCTAssertEqual(shortWidth, shortAppearance)
        defaults.set("/opt/" + String(repeating: "long/", count: 40) + "nvim",
                     forKey: Settings.customNeovimPathKey)
        let (longWidth, longAppearance) = try widths(try popup())
        XCTAssertEqual(longWidth, longAppearance)
        XCTAssertEqual(longAppearance, shortAppearance)
        defaults.set("/opt/homebrew/bin/nvim",
                     forKey: Settings.customNeovimPathKey)

        choose(1, in: withPath)
        XCTAssertTrue(Settings.useCustomNeovim)
        XCTAssertEqual(try popup().selectedTag(), 1)
        choose(0, in: withPath)
        XCTAssertFalse(Settings.useCustomNeovim)
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
