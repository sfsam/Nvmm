//
//  Nvmm
//  Composition.swift
//
//  Pure preedit layout math for marked-text composition (dead keys and IMEs).
//
//  A marked-text session shows a provisional string — a dead-key accent, a
//  multi-scalar emoji, or an IME preedit with a candidate window — inside the
//  Neovim grid before it commits. `layoutComposition` places that string on a
//  single grid row without any AppKit, RPC, grid-mutation, or rendering
//  dependency, so it is unit tested in isolation. `compositionGraphemeWidth`
//  gives each grapheme the same display width Neovim would, using utf8proc for
//  the East-Asian-width and emoji classification the standard library omits.
//

import Foundation

// MARK: - Width policy

/// A `getcellwidths()` entry: scalars in `[first, last]` render at `width` cells.
nonisolated struct CellwidthOverride: Sendable, Equatable {
    var first: Int32
    var last: Int32
    var width: Int32
}

/// The inputs that decide a grapheme's display width, matching Neovim's model.
/// `ambiguousIsDouble` follows `ambiwidth`; `emojiIsDouble` follows `emoji`.
nonisolated struct CompositionWidthPolicy: Sendable, Equatable {
    var ambiguousIsDouble = false
    var emojiIsDouble = true
    var overrides: [CellwidthOverride] = []
}

private nonisolated func isEmojiLike(_ boundclass: UInt32) -> Bool {
    boundclass == UInt32(UTF8PROC_BOUNDCLASS_EXTENDED_PICTOGRAPHIC.rawValue) ||
    boundclass == UInt32(UTF8PROC_BOUNDCLASS_REGIONAL_INDICATOR.rawValue)
}

/// The Neovim-compatible display width, in cells, of one grapheme.
nonisolated func compositionGraphemeWidth(_ grapheme: String,
                                          _ policy: CompositionWidthPolicy) -> Int {
    var scalars = grapheme.unicodeScalars.makeIterator()
    guard let first = scalars.next() else { return 1 }
    let value = first.value
    let scalar = Int32(value)

    for override in policy.overrides {
        if scalar >= override.first && scalar <= override.last {
            return Int(override.width)
        }
    }

    guard let property = utf8proc_get_property(scalar) else { return 1 }
    let charwidth = property.pointee.charwidth
    if charwidth == 2 { return 2 }
    let ambiguous = property.pointee.ambiguous_width != 0
    if policy.ambiguousIsDouble && ambiguous { return 2 }

    let emojiLike = isEmojiLike(UInt32(property.pointee.boundclass))
    // Pictographs at or above the emoji planes render double unless they are
    // East-Asian-ambiguous, matching Neovim's emoji width rule.
    if policy.emojiIsDouble && value >= 0x1F000 && !ambiguous && emojiLike {
        return 2
    }
    // A narrow pictograph followed by U+FE0F (emoji variation selector) is
    // presented in emoji style and takes two cells.
    if policy.emojiIsDouble && charwidth == 1 && emojiLike {
        if let next = scalars.next(), next.value == 0xFE0F { return 2 }
    }
    return 1
}

// MARK: - Layout

/// A marked grapheme with its Neovim display width and original UTF-16 range.
nonisolated struct CompositionGrapheme: Sendable, Equatable {
    var width: Int
    var utf16Location: UInt32
    var utf16Length: UInt32
}

/// An existing grid cell available for Insert-mode displacement past the preedit.
nonisolated struct CompositionSourceCell: Sendable, Equatable {
    var column: Int
    var width: Int
}

nonisolated enum CompositionPlacementKind: Sendable, Equatable { case marked, displaced }

/// One placed cell: `sourceIndex` indexes the input graphemes or source cells
/// depending on `kind`, and `column` is the grid column it occupies.
nonisolated struct CompositionPlacement: Sendable, Equatable {
    var kind: CompositionPlacementKind
    var sourceIndex: Int
    var column: Int
}

/// Everything `layoutComposition` needs. Geometry fields apply only when
/// `geometryValid` is true; otherwise layout uses full-grid overwrite fallback.
nonisolated struct CompositionLayoutInput: Sendable {
    var gridWidth = 0
    var gridHeight = 0
    /// Client-side preedit anchor in grid coordinates.
    var anchorRow = 0
    var anchorColumn = 0
    /// Editable text-area bounds, used only when `geometryValid` is true.
    var textLeft = 0
    var textWidth = 0
    /// False means geometry is missing or stale: fall back to full-grid
    /// overwrite and disable displacement.
    var geometryValid = false
    /// Place marked graphemes toward the leading edge of a right-left window.
    var rightToLeft = false
    /// Insert-mode preedit may displace source cells when geometry is valid.
    var insertMode = false
    /// Cocoa UTF-16 selection location, used to keep the active clause of a long
    /// preedit visible when clipping.
    var selectionLocation: UInt32 = 0
    /// Marked text split into complete graphemes.
    var graphemes: [CompositionGrapheme] = []
    /// Existing cells from the anchor, available for Insert-mode displacement.
    var sourceCells: [CompositionSourceCell] = []
}

/// The placement result. `placements` is renderer-neutral; the view converts it
/// into synthetic cells. `clearStart`/`clearEnd` is a half-open cell range to
/// clear before drawing.
nonisolated struct CompositionLayoutOutput: Sendable, Equatable {
    var valid = false
    /// True when source cells should be redrawn after the marked text.
    var displaced = false
    var row = 0
    /// Clamped anchor column used for color sampling and fallback geometry.
    var cursorColumn = 0
    var clearStart = 0
    var clearEnd = 0
    var placements: [CompositionPlacement] = []
}

/// Clamps a preedit anchor row into the grid.
nonisolated func clampCompositionRow(_ anchorRow: Int, gridHeight: Int) -> Int {
    min(max(anchorRow, 0), gridHeight - 1)
}

/// Computes single-row preedit placement with no AppKit, RPC, grid-mutation, or
/// rendering dependency.
nonisolated func layoutComposition(_ input: CompositionLayoutInput) -> CompositionLayoutOutput {
    var output = CompositionLayoutOutput()
    if input.gridWidth <= 0 || input.gridHeight <= 0 { return output }
    output.valid = true
    output.row = clampCompositionRow(input.anchorRow, gridHeight: input.gridHeight)

    let left = input.geometryValid
        ? min(max(input.textLeft, 0), input.gridWidth) : 0
    let right = input.geometryValid
        ? min(max(input.textLeft + input.textWidth, left), input.gridWidth)
        : input.gridWidth
    if left >= right { return output }
    output.cursorColumn = min(max(input.anchorColumn, left), right - 1)

    var totalWidth = 0
    for grapheme in input.graphemes { totalWidth += grapheme.width }
    // Prefer placing the whole preedit in the trailing space from the anchor;
    // otherwise shift it toward the leading boundary without wrapping rows.
    let trailing = input.rightToLeft
        ? output.cursorColumn - left + 1 : right - output.cursorColumn
    var origin = input.rightToLeft
        ? (totalWidth <= trailing ? output.cursorColumn - totalWidth + 1 : left)
        : (totalWidth <= trailing ? output.cursorColumn
                                  : max(left, right - totalWidth))

    var selected = input.graphemes.count
    for i in input.graphemes.indices {
        let grapheme = input.graphemes[i]
        if input.selectionLocation <= grapheme.utf16Location + grapheme.utf16Length {
            selected = i
            break
        }
    }
    // If the preedit is wider than the text area, drop leading graphemes only
    // until the selected clause/insertion point remains visible.
    var first = 0
    var visibleWidth = totalWidth
    while visibleWidth > right - left && first < selected {
        visibleWidth -= input.graphemes[first].width
        first += 1
    }
    visibleWidth = min(visibleWidth, right - left)
    if totalWidth > right - left {
        origin = input.rightToLeft ? right - visibleWidth : left
    }

    var column = input.rightToLeft ? min(right - 1, output.cursorColumn) : origin
    for i in first..<input.graphemes.count {
        let grapheme = input.graphemes[i]
        let cellColumn = input.rightToLeft ? column - grapheme.width + 1 : column
        if cellColumn < left || cellColumn + grapheme.width > right { break }
        output.placements.append(
            CompositionPlacement(kind: .marked, sourceIndex: i, column: cellColumn))
        column += input.rightToLeft ? -grapheme.width : grapheme.width
    }

    // Displacement mirrors Insert mode by moving existing cells after the marked
    // text, but only when Neovim supplied trustworthy LTR text bounds.
    output.displaced = input.insertMode && input.geometryValid &&
        !input.rightToLeft && totalWidth < trailing
    if output.displaced {
        var destination = output.cursorColumn + totalWidth
        for i in input.sourceCells.indices {
            let cell = input.sourceCells[i]
            if destination + cell.width > right { break }
            output.placements.append(
                CompositionPlacement(kind: .displaced, sourceIndex: i, column: destination))
            destination += cell.width
        }
    }

    output.clearStart = right
    output.clearEnd = left
    for placement in output.placements {
        let width = placement.kind == .marked
            ? input.graphemes[placement.sourceIndex].width
            : input.sourceCells[placement.sourceIndex].width
        output.clearStart = min(output.clearStart, placement.column)
        output.clearEnd = max(output.clearEnd, placement.column + width)
    }
    // Displaced cells may be clipped at the trailing boundary, so clear through
    // the boundary to remove original cells that have shifted out of view.
    if output.displaced { output.clearEnd = right }
    if output.clearStart >= output.clearEnd {
        output.clearStart = 0
        output.clearEnd = 0
    }
    return output
}
