//
//  NvmmTests
//  LookupTests.swift
//
//  Look Up coverage: recovering the token under a grid point from the drawn
//  cells (identifier boundaries, blank cells, double-width columns), and
//  parsing the Visual-mode selection reply that a Look Up inside a selection
//  uses.
//

import XCTest
@testable import Nvmm

final class LookupTests: XCTestCase {

    // MARK: Grid helpers

    private func makeGrid(width: Int, height: Int = 1) -> Grid {
        var grid = Grid()
        grid.resize(width: width, height: height)
        return grid
    }

    /// Writes one grapheme per cell, starting at `column`.
    private func write(_ text: String, into grid: inout Grid,
                       row: Int = 0, column: Int = 0) {
        var index = column
        for character in text {
            grid.cells[row * grid.width + index] =
                Cell(text: String(character), attrs: CellAttributes())
            index += 1
        }
    }

    /// Writes one grapheme across two cells, the way Neovim draws a
    /// double-width character: the grapheme on the left, a blank right half
    /// carrying the same attributes.
    private func writeWide(_ text: String, into grid: inout Grid,
                           row: Int = 0, column: Int = 0) {
        var attrs = CellAttributes()
        attrs.flags.insert(.doublewidth)
        grid.cells[row * grid.width + column] = Cell(text: text, attrs: attrs)
        var right = Cell()
        right.setAttributes(attrs)
        grid.cells[row * grid.width + column + 1] = right
    }

    // MARK: Bounds

    func testGridContainsPoint() {
        let grid = makeGrid(width: 4, height: 2)
        XCTAssertTrue(LookupController.grid(grid, contains: GridPoint(row: 0, column: 0)))
        XCTAssertTrue(LookupController.grid(grid, contains: GridPoint(row: 1, column: 3)))
        XCTAssertFalse(LookupController.grid(grid, contains: GridPoint(row: 2, column: 0)))
        XCTAssertFalse(LookupController.grid(grid, contains: GridPoint(row: 0, column: 4)))
        XCTAssertFalse(LookupController.grid(grid, contains: GridPoint(row: -1, column: 0)))
        XCTAssertFalse(LookupController.grid(grid, contains: GridPoint(row: 0, column: -1)))
        XCTAssertFalse(LookupController.grid(Grid(), contains: GridPoint(row: 0, column: 0)))
        XCTAssertFalse(LookupController.grid(nil, contains: GridPoint(row: 0, column: 0)))
    }

    // MARK: Token extraction

    func testTokenSpansUnderscoresButNotSurroundingText() {
        var grid = makeGrid(width: 16)
        write("let foo_bar = 1", into: &grid)

        let token = LookupController.token(at: GridPoint(row: 0, column: 6),
                                           in: grid)
        XCTAssertEqual(token?.string, "foo_bar")
        XCTAssertEqual(token?.startColumn, 4)
        XCTAssertEqual(token?.endColumn, 10)
    }

    func testTokenIsNilOnABlankCell() {
        var grid = makeGrid(width: 8)
        write("ab cd", into: &grid)
        XCTAssertNil(LookupController.token(at: GridPoint(row: 0, column: 2),
                                            in: grid))
        // A cell Neovim never drew is blank too.
        XCTAssertNil(LookupController.token(at: GridPoint(row: 0, column: 7),
                                            in: grid))
    }

    func testTokenIsNilOnPunctuation() {
        var grid = makeGrid(width: 8)
        write("a = b", into: &grid)
        XCTAssertNil(LookupController.token(at: GridPoint(row: 0, column: 2),
                                            in: grid))
    }

    func testBlankCellsSeparateWords() {
        var grid = makeGrid(width: 12)
        write("foo", into: &grid, column: 0)
        write("bar", into: &grid, column: 6)

        let first = LookupController.token(at: GridPoint(row: 0, column: 1),
                                           in: grid)
        XCTAssertEqual(first?.string, "foo")
        XCTAssertEqual(first?.endColumn, 2)

        let second = LookupController.token(at: GridPoint(row: 0, column: 7),
                                            in: grid)
        XCTAssertEqual(second?.string, "bar")
        XCTAssertEqual(second?.startColumn, 6)
    }

    func testDoubleWidthCellsKeepColumnsAligned() {
        var grid = makeGrid(width: 8)
        writeWide("日", into: &grid, column: 0)
        write(" foo", into: &grid, column: 2)

        let token = LookupController.token(at: GridPoint(row: 0, column: 4),
                                           in: grid)
        XCTAssertEqual(token?.string, "foo")
        XCTAssertEqual(token?.startColumn, 3)
        XCTAssertEqual(token?.endColumn, 5)

        // The right half of the double-width cell carries no grapheme.
        XCTAssertNil(LookupController.token(at: GridPoint(row: 0, column: 1),
                                            in: grid))
    }

    func testTokenKeepsCombiningMarks() {
        var grid = makeGrid(width: 8)
        write("cafe\u{301}", into: &grid)

        let token = LookupController.token(at: GridPoint(row: 0, column: 0),
                                           in: grid)
        XCTAssertEqual(token?.string, "cafe\u{301}")
        XCTAssertEqual(token?.endColumn, 3)
    }

    func testTokenReadsTheRowThePointIsOn() {
        var grid = makeGrid(width: 8, height: 2)
        write("alpha", into: &grid, row: 0)
        write("beta", into: &grid, row: 1)

        XCTAssertEqual(LookupController.token(at: GridPoint(row: 1, column: 2),
                                              in: grid)?.string, "beta")
    }

    // MARK: Visual selection parsing

    private func screenpos(row: Int, col: Int) -> MPValue {
        .map([(.string("row"), .int(MPInteger(row))),
              (.string("col"), .int(MPInteger(col)))])
    }

    private func selectionReply(mode: String, start: MPValue, cursor: MPValue,
                                lines: [String]) -> MPValue {
        .array([.string(mode), start, cursor,
                .array(lines.map { .string($0) })])
    }

    func testParsesVisualSelection() {
        let reply = selectionReply(mode: "v",
                                   start: screenpos(row: 3, col: 5),
                                   cursor: screenpos(row: 4, col: 2),
                                   lines: ["alpha", "beta"])
        let selection = parseVisualSelection(reply)
        XCTAssertEqual(selection?.start, GridPoint(row: 2, column: 4))
        XCTAssertEqual(selection?.end, GridPoint(row: 3, column: 1))
        XCTAssertEqual(selection?.text, "alpha\nbeta")
    }

    func testParsesBackwardsSelectionInScreenOrder() {
        let reply = selectionReply(mode: "V",
                                   start: screenpos(row: 6, col: 3),
                                   cursor: screenpos(row: 2, col: 8),
                                   lines: ["one"])
        let selection = parseVisualSelection(reply)
        XCTAssertEqual(selection?.start, GridPoint(row: 1, column: 7))
        XCTAssertEqual(selection?.end, GridPoint(row: 5, column: 2))
    }

    func testRejectsNonVisualAndMalformedReplies() {
        let position = screenpos(row: 1, col: 1)
        XCTAssertNil(parseVisualSelection(
            selectionReply(mode: "n", start: position, cursor: position,
                           lines: ["x"])))
        // An off-screen position: `screenpos()` reports an empty dictionary.
        XCTAssertNil(parseVisualSelection(
            selectionReply(mode: "v", start: .map([]), cursor: position,
                           lines: ["x"])))
        XCTAssertNil(parseVisualSelection(
            selectionReply(mode: "v", start: position, cursor: position,
                           lines: [])))
        XCTAssertNil(parseVisualSelection(.array([.string("v"), position])))
        XCTAssertNil(parseVisualSelection(.null))
    }

    func testSelectionContainsPoint() {
        var selection = VisualSelection()
        selection.start = GridPoint(row: 2, column: 4)
        selection.end = GridPoint(row: 2, column: 6)
        XCTAssertTrue(selection.contains(GridPoint(row: 2, column: 4)))
        XCTAssertTrue(selection.contains(GridPoint(row: 2, column: 6)))
        XCTAssertFalse(selection.contains(GridPoint(row: 2, column: 7)))
        XCTAssertFalse(selection.contains(GridPoint(row: 3, column: 5)))

        selection.end = GridPoint(row: 4, column: 2)
        XCTAssertTrue(selection.contains(GridPoint(row: 2, column: 9)))
        XCTAssertFalse(selection.contains(GridPoint(row: 2, column: 3)))
        XCTAssertTrue(selection.contains(GridPoint(row: 3, column: 0)))
        XCTAssertTrue(selection.contains(GridPoint(row: 4, column: 2)))
        XCTAssertFalse(selection.contains(GridPoint(row: 4, column: 3)))
    }
}
