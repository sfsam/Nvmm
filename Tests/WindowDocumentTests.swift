//
//  NvmmTests
//  WindowDocumentTests.swift
//

import Foundation
import XCTest
@testable import Nvmm

final class WindowDocumentTests: XCTestCase {
    func testRepresentedDocumentURLRequiresExistingLocalItem() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let state = DocumentState(path: file.path, isModified: false)
        XCTAssertEqual(
            WindowController.representedDocumentURL(
                for: state, documentPathsAreLocal: true),
            file.standardizedFileURL)

        let missing = DocumentState(
            path: file.appendingPathExtension("missing").path,
            isModified: false)
        XCTAssertNil(WindowController.representedDocumentURL(
            for: missing, documentPathsAreLocal: true))
        XCTAssertNil(WindowController.representedDocumentURL(
            for: .empty, documentPathsAreLocal: true))
    }

    func testRemoteDocumentCannotResolveMatchingLocalPath() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let state = DocumentState(path: file.path, isModified: true)
        XCTAssertNil(WindowController.representedDocumentURL(
            for: state, documentPathsAreLocal: false))
    }
}
