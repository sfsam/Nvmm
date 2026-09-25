//
//  NvmmTests
//  OpenRecentMenuTests.swift
//

import AppKit
import XCTest
@testable import Nvmm

final class OpenRecentMenuTests: XCTestCase {

    /// AppKit manages the Open Recent menu, and hands a chosen item to the
    /// application delegate.
    func testMainMenuUsesAppKitRecentDocumentsMenu() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let menuURL = repository
            .appendingPathComponent("Nvmm/Base.lproj/MainMenu.xib")
        let source = try String(contentsOf: menuURL, encoding: .utf8)

        XCTAssertTrue(source.contains("systemMenu=\"recentDocuments\""))
        XCTAssertTrue(source.contains("selector=\"clearRecentDocuments:\""))
        XCTAssertTrue(AppDelegate.instancesRespond(
            to: NSSelectorFromString("application:openFile:")))
    }
}
