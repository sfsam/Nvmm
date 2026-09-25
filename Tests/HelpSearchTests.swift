//
//  NvmmTests
//  HelpSearchTests.swift
//

import Foundation
import XCTest
@testable import Nvmm

final class HelpTopicIndexTests: XCTestCase {
    private let index = HelpTopicIndex(contents: """
    'shiftwidth'\toptions.txt\t/*'shiftwidth'*
    help\thelphelp.txt\t/*help*
    help-context\thelphelp.txt\t/*help-context*
    i_CTRL-X\tinsert.txt\t/*i_CTRL-X*
    malformed

    """)

    func testParsesTagAndFileAndSkipsMalformedLines() {
        XCTAssertEqual(index.topics, [
            HelpTopic(tag: "'shiftwidth'", file: "options.txt"),
            HelpTopic(tag: "help", file: "helphelp.txt"),
            HelpTopic(tag: "help-context", file: "helphelp.txt"),
            HelpTopic(tag: "i_CTRL-X", file: "insert.txt"),
        ])
    }

    func testSearchRequiresEveryTermIgnoringCase() {
        XCTAssertEqual(index.search("CTRL i_", limit: 20), [
            HelpTopic(tag: "i_CTRL-X", file: "insert.txt"),
        ])
        XCTAssertTrue(index.search("  \t ", limit: 20).isEmpty)
    }

    /// An exact match sorts first and counts toward the limit; without one,
    /// the partial matches stop at the limit.
    func testSearchOrderAndLimit() {
        XCTAssertEqual(index.search("help", limit: 20).map(\.tag),
                       ["help", "help-context"])
        XCTAssertEqual(index.search("help", limit: 1).map(\.tag), ["help"])
        XCTAssertTrue(index.search("help", limit: 0).isEmpty)
        XCTAssertEqual(index.search("help-", limit: 1).map(\.tag),
                       ["help-context"])
    }
}

final class HelpSearchControllerTests: XCTestCase {
    func testDefersReadingTagsUntilFirstSearch() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        let controller = HelpSearchController(tagsURL: url) { _ in }
        try "help\thelphelp.txt\t/*help*\n".write(
            to: url, atomically: true, encoding: .utf8)

        var items: [Any] = []
        controller.searchForItems(
            withSearch: "help", resultLimit: 10,
            matchedItemHandler: { items = $0 })

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(controller.localizedTitles(forItem: items[0]),
                       ["helphelp.txt", "help"])
    }
}
