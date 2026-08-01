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
            documentTypes[0], name: "Text Document",
            contentType: "public.text", role: "Editor", rank: "Default")
        assertDocumentType(
            documentTypes[1], name: "Data File",
            contentType: "public.data", role: "Viewer", rank: "Alternate")
    }

    private func assertDocumentType(
        _ documentType: [String: Any],
        name: String,
        contentType: String,
        role: String,
        rank: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            documentType["CFBundleTypeName"] as? String,
            name, file: file, line: line)
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
