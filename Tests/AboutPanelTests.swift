//
//  NvmmTests
//  AboutPanelTests.swift
//
//  Covers the attributed information shown in AppKit's standard About panel.
//

import AppKit
import XCTest
@testable import Nvmm

final class AboutPanelTests: XCTestCase {

    func testCreditsShowNeovimVersionAndLink() {
        let credits = NvmmApplication.aboutCredits(
            nvimVersion: "NVIM v0.12.4")

        XCTAssertEqual(credits.string, "NVIM v0.12.4\n\nmowglii.com")
        let linkRange = (credits.string as NSString).range(of: "mowglii.com")
        let link = credits.attribute(.link, at: linkRange.location,
                                     effectiveRange: nil) as? URL
        XCTAssertEqual(link, URL(string: "https://mowglii.com"))
    }

    func testCreditsOmitMissingVersion() {
        let missing = NvmmApplication.aboutCredits(nvimVersion: nil)
        let empty = NvmmApplication.aboutCredits(nvimVersion: "")

        XCTAssertEqual(missing.string, "mowglii.com")
        XCTAssertEqual(empty.string, "mowglii.com")
    }

    func testCreditsAreCenteredAndUseSmallSystemFont() {
        let credits = NvmmApplication.aboutCredits(
            nvimVersion: "NVIM v0.12.4")
        let paragraph = credits.attribute(
            .paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let font = credits.attribute(
            .font, at: 0, effectiveRange: nil) as? NSFont

        XCTAssertEqual(paragraph?.alignment, .center)
        XCTAssertEqual(font?.pointSize,
                       NSFont.systemFontSize(for: .small))
    }
}
