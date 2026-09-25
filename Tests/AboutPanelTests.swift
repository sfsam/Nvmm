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

        XCTAssertEqual(credits.string, "NVIM v0.12.4\n\nmowglii.com/nvmm\n")
        let linkRange = (credits.string as NSString).range(of: "mowglii.com/nvmm")
        let link = credits.attribute(.link, at: linkRange.location,
                                     effectiveRange: nil) as? URL
        XCTAssertEqual(link, URL(string: "https://mowglii.com/nvmm"))

        // A missing or empty version leaves just the link.
        for version in [nil, ""] {
            XCTAssertEqual(
                NvmmApplication.aboutCredits(nvimVersion: version).string,
                "mowglii.com/nvmm\n")
        }
    }
}
