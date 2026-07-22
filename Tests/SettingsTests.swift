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

    /// The context-sensitive cursor is on unless it is turned off, which only
    /// holds because it is registered; every other setting is off until set,
    /// which is what an unwritten key already reads as.
    @MainActor
    func testRegisteredDefaults() {
        let defaults = UserDefaults.standard
        let keys = [Settings.contextSensitiveCursorKey,
                    Settings.openFilesInBuffersKey,
                    Settings.terminateAfterLastWindowKey,
                    Settings.titlebarAppearsTransparentKey]

        // The user's own values must not decide the outcome, and must survive
        // the test: only the registration domain is under test here.
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        for key in keys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in saved { defaults.set(value, forKey: key) }
        }

        Settings.registerDefaults()

        XCTAssertTrue(Settings.contextSensitiveCursor)
        XCTAssertFalse(Settings.openFilesInBuffers)
        XCTAssertFalse(Settings.terminateAfterLastWindow)
        XCTAssertFalse(Settings.titlebarAppearsTransparent)
    }
}
