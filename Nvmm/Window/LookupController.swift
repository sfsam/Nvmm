//
//  Nvmm
//  LookupController.swift
//
//  Look Up: the word under a Force Touch (or three-finger tap), handed to
//  macOS's definition popover.
//
//  The grid is the only text this app has — there is no backing text storage
//  to ask — so the token is recovered from the drawn cells. A row is flattened
//  into a string (blank single-width cells become spaces, the right halves of
//  double-width characters contribute nothing) alongside a column-to-offset
//  map, the token is grown outward from the clicked offset, and the map turns
//  the token's range back into the columns that anchor the popover.
//
//  Token boundaries are tried in two passes: an identifier pass (alphanumerics,
//  underscore, and combining marks) so `foo_bar` reads as one word the way it
//  does in code, then Cocoa's localized word enumeration, which handles prose
//  and scripts that do not separate words with spaces.
//

import AppKit

// MARK: - Values

/// A word recovered from a grid row, with the columns it occupies.
nonisolated struct LookupToken: Sendable, Equatable {
    let string: String
    /// The token's range within the row's flattened text, in UTF-16 offsets.
    let stringRange: NSRange
    /// The first and last grid columns the token covers, inclusive.
    let startColumn: Int
    let endColumn: Int
}

/// Text to look up, plus the view-space baseline origin to anchor it at.
nonisolated struct LookupResult {
    let attributedString: NSAttributedString
    let anchorPoint: NSPoint
}

// MARK: - Controller

/// Builds the text and anchor point for a Look Up gesture over the grid.
@MainActor final class LookupController {
    /// The editor font at its unscaled (point, not backing-pixel) size, so the
    /// popover renders the word the same size the grid draws it.
    private var lookupFont: NSFont?
    private var cachedScaledFont: CTFont?
    private var cachedUnscaledSize: CGFloat = 0

    // The class is main-actor isolated, which would otherwise give it an
    // isolated deinit. A nonisolated deinit avoids the isolated-deinit
    // executor hop that trips a libmalloc double-free under XCTest's
    // post-test memory checker.
    nonisolated deinit {}

    /// Adopts the grid's font. Cheap to call on every font change: an
    /// equivalent family is recognized and rebuilds nothing.
    func setFontFamily(_ family: FontFamily) {
        let scaled = family.regular
        let unscaledSize = family.unscaledSize

        if lookupFont != nil, let cached = cachedScaledFont,
           CFEqual(cached, scaled), cachedUnscaledSize == unscaledSize {
            return
        }

        cachedScaledFont = scaled
        cachedUnscaledSize = unscaledSize
        lookupFont = CTFontCreateCopyWithAttributes(
            scaled, unscaledSize, nil, nil) as NSFont
    }

    /// The string in the editor font, falling back to the system font before
    /// a font has been set.
    func attributedString(_ string: String) -> NSAttributedString {
        let font = lookupFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return NSAttributedString(string: string,
                                  attributes: [.font: font])
    }

    /// The token under a grid point, anchored at its first column's baseline
    /// in the view's coordinate space. Nil when the point is off the grid, on
    /// a blank cell, or in no word.
    func renderedLookup(at point: GridPoint, in grid: Grid?, cellSize: NSSize,
                        baseline: CGFloat) -> LookupResult? {
        guard LookupController.grid(grid, contains: point),
              cellSize.width > 0, cellSize.height > 0,
              let token = LookupController.token(at: point, in: grid)
        else { return nil }

        return LookupResult(
            attributedString: attributedString(token.string),
            anchorPoint: NSPoint(
                x: CGFloat(token.startColumn) * cellSize.width,
                y: CGFloat(point.row) * cellSize.height + baseline))
    }

    // MARK: Token extraction

    /// The word under a grid point, recovered from the row's drawn cells.
    nonisolated static func token(at point: GridPoint,
                                  in grid: Grid?) -> LookupToken? {
        guard let grid, LookupController.grid(grid, contains: point),
              !grid.cell(point.row, point.column).isEmpty else { return nil }

        let row = rowText(grid, row: point.row)
        let index = row.columnToLocation[point.column]
        guard index != NSNotFound, index < row.string.length else { return nil }

        var range = identifierRange(in: row.string, containing: index)
        if range.location == NSNotFound {
            range = wordRange(in: row.string, containing: index)
        }
        guard range.location != NSNotFound, range.length != 0,
              let columns = columns(for: range, in: row) else { return nil }

        return LookupToken(string: row.string.substring(with: range),
                           stringRange: range,
                           startColumn: columns.start,
                           endColumn: columns.end)
    }

    /// True if the point names a cell of a non-empty grid.
    nonisolated static func grid(_ grid: Grid?, contains point: GridPoint) -> Bool {
        guard let grid, grid.width > 0, grid.height > 0 else { return false }
        return point.row >= 0 && point.column >= 0 &&
            point.row < grid.height && point.column < grid.width
    }
}

// MARK: - Row flattening

/// A grid row as one string, with the offset each column's text starts at.
private nonisolated struct RowText {
    let string: NSString
    /// Per column, the UTF-16 offset in `string` where that column's text
    /// begins, or `NSNotFound` for a column that contributes nothing.
    let columnToLocation: [Int]
}

/// The text a cell contributes to its row: its grapheme, a space for a blank
/// single-width cell, and nothing for the right half of a double-width one.
private nonisolated func visibleCellString(_ cell: Cell) -> String? {
    if !cell.isEmpty { return cell.text }
    return cell.width == 1 ? " " : nil
}

private nonisolated func rowText(_ grid: Grid, row: Int) -> RowText {
    let string = NSMutableString()
    var locations = [Int](repeating: NSNotFound, count: grid.width)

    for column in 0..<grid.width {
        guard let text = visibleCellString(grid.cell(row, column)) else { continue }
        locations[column] = string.length
        string.append(text)
    }
    return RowText(string: string, columnToLocation: locations)
}

/// The columns whose text falls inside a range of the flattened row, or nil
/// if the range covers no column.
private nonisolated func columns(for range: NSRange,
                                 in row: RowText) -> (start: Int, end: Int)? {
    let rangeEnd = NSMaxRange(range)
    var start = 0
    var end = 0
    var found = false

    for (column, location) in row.columnToLocation.enumerated() {
        guard location != NSNotFound, location >= range.location,
              location < rangeEnd else { continue }
        if !found {
            start = column
            found = true
        }
        end = column
    }
    return found ? (start, end) : nil
}

// MARK: - Word boundaries

/// Characters an identifier is made of: what a programming language allows in
/// a name, plus combining marks so a decomposed letter is not split.
private nonisolated let identifierCharacters: CharacterSet = {
    var set = CharacterSet.alphanumerics
    set.insert(charactersIn: "_")
    set.formUnion(.nonBaseCharacters)
    return set
}()

/// True if the composed character sequence at `index` is an identifier
/// character. Indices are UTF-16 offsets, so the sequence is resolved first.
private nonisolated func characterMatches(_ string: NSString, at index: Int,
                              _ characterSet: CharacterSet) -> Bool {
    guard index < string.length else { return false }
    let range = string.rangeOfComposedCharacterSequence(at: index)
    let sequence = string.substring(with: range)
    return sequence.rangeOfCharacter(from: characterSet) != nil
}

/// The run of identifier characters containing `index`, or a not-found range
/// if the character there is not one.
private nonisolated func identifierRange(in string: NSString,
                             containing index: Int) -> NSRange {
    guard characterMatches(string, at: index, identifierCharacters) else {
        return NSRange(location: NSNotFound, length: 0)
    }

    var start = index
    while start > 0 {
        let previous = string.rangeOfComposedCharacterSequence(at: start - 1).location
        guard characterMatches(string, at: previous, identifierCharacters) else { break }
        start = previous
    }

    var end = NSMaxRange(string.rangeOfComposedCharacterSequence(at: index))
    while end < string.length {
        guard characterMatches(string, at: end, identifierCharacters) else { break }
        end = NSMaxRange(string.rangeOfComposedCharacterSequence(at: end))
    }

    return NSRange(location: start, length: end - start)
}

/// The localized word containing `index`, which unlike the identifier pass
/// knows about scripts that do not separate words with spaces.
private nonisolated func wordRange(in string: NSString, containing index: Int) -> NSRange {
    var found = NSRange(location: NSNotFound, length: 0)
    string.enumerateSubstrings(in: NSRange(location: 0, length: string.length),
                               options: [.byWords, .localized]) {
        _, substringRange, _, stop in
        if NSLocationInRange(index, substringRange) {
            found = substringRange
            stop.pointee = true
        }
    }
    return found
}
