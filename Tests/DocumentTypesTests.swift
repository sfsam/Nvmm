//
//  NvmmTests
//  DocumentTypesTests.swift
//
//  Verifies the document roles registered with Launch Services.
//

import XCTest

final class DocumentTypesTests: XCTestCase {

    func testDocumentTypesDistinguishTextFromArbitraryData() throws {
        let documentTypes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes")
                as? [[String: Any]])

        XCTAssertEqual(documentTypes.count, 2)
        assertDocumentType(
            documentTypes[0], contentType: "public.text",
            role: "Editor", rank: "Default")
        assertDocumentType(
            documentTypes[1], contentType: "public.data",
            role: "Viewer", rank: "Alternate")
    }

    private func assertDocumentType(
        _ documentType: [String: Any],
        contentType: String,
        role: String,
        rank: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            documentType["LSItemContentTypes"] as? [String],
            [contentType], file: file, line: line)
        XCTAssertEqual(
            documentType["CFBundleTypeRole"] as? String,
            role, file: file, line: line)
        XCTAssertEqual(
            documentType["LSHandlerRank"] as? String,
            rank, file: file, line: line)
    }
}
