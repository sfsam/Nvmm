//
//  Nvmm
//  Cell.swift
//
//  A single grid cell: a grapheme plus its resolved highlight attributes.
//
//  Neovim's grid model gives each cell one grapheme cluster (up to `maxcombine`
//  code points) and a highlight id resolved here into `CellAttributes`. A blank
//  cell — a lone space, or the right half of a double-width character — carries
//  no grapheme; `isEmpty` reports that. `pointerStyle` is the raw `HLGroup`
//  bitset for the cell, resolved from its highlight id during `grid_line`.
//

import Foundation

/// Cell attributes that select a font face.
nonisolated enum FontAttributes: Sendable {
    case none, bold, italic, boldItalic
}

/// One cell of a grid.
nonisolated struct Cell: Sendable, Equatable {
    /// The cell's grapheme, or the empty string for a blank cell.
    private(set) var text: String
    private(set) var attrs: CellAttributes
    /// The raw `HLGroup` bitset resolved from the cell's highlight id.
    var pointerStyle: UInt8

    /// A blank cell with default attributes and no blend.
    init() {
        text = ""
        attrs = CellAttributes()
        pointerStyle = 0
    }

    /// Builds a cell from grapheme text and attributes.
    ///
    /// A single space is stored as a blank cell, matching Neovim, so an all-space
    /// run and an empty run render identically.
    init(text: String, attrs: CellAttributes, pointerStyle: UInt8 = 0) {
        self.attrs = attrs
        self.pointerStyle = pointerStyle
        self.text = text == " " ? "" : text
    }

    /// True if the cell has no grapheme (blank or the right of a double-width char).
    var isEmpty: Bool { text.isEmpty }

    var foreground: RGBColor { attrs.foreground }
    var background: RGBColor { attrs.background }
    var special: RGBColor { attrs.special }

    /// The font face selected by the bold/italic flags.
    var fontAttributes: FontAttributes {
        switch (attrs.flags.contains(.bold), attrs.flags.contains(.italic)) {
        case (false, false): return .none
        case (true, false): return .bold
        case (false, true): return .italic
        case (true, true): return .boldItalic
        }
    }

    var hasLineEmphasis: Bool { !attrs.flags.isDisjoint(with: .lineEmphasis) }
    var hasUnderline: Bool { !attrs.flags.isDisjoint(with: .anyUnderline) }
    var hasUnderdouble: Bool { attrs.flags.contains(.underdouble) }
    var hasUnderdotted: Bool { attrs.flags.contains(.underdotted) }
    var hasUnderdashed: Bool { attrs.flags.contains(.underdashed) }
    var hasUndercurl: Bool { attrs.flags.contains(.undercurl) }
    var hasOverline: Bool { attrs.flags.contains(.overline) }
    var hasStrikethrough: Bool { attrs.flags.contains(.strikethrough) }
    var isDim: Bool { attrs.flags.contains(.dim) }
    var hasNocombine: Bool { attrs.flags.contains(.nocombine) }
    var hasSpecialColor: Bool { attrs.flags.contains(.specialColor) }

    /// The highlight blend percentage, or nil when Neovim provided none.
    var blend: UInt8? { attrs.blend == CellAttributes.noBlend ? nil : attrs.blend }

    /// 1 for single-width characters, 2 for double-width.
    var width: Int { attrs.flags.contains(.doublewidth) ? 2 : 1 }

    /// A copy with its three colors replaced, keeping text, flags, and blend.
    func recolored(foreground: RGBColor, background: RGBColor,
                   special: RGBColor) -> Cell {
        var copy = self
        copy.attrs.foreground = foreground
        copy.attrs.background = background
        copy.attrs.special = special
        return copy
    }

    /// The cell's resolved highlight attributes.
    var attributes: CellAttributes { attrs }

    // Mutating hooks used by the UI controller while applying redraw events.

    /// Replaces the cell's attributes wholesale (used to propagate double-width).
    mutating func setAttributes(_ attributes: CellAttributes) { attrs = attributes }

    /// Marks the cell as the left half of a double-width character.
    mutating func addDoubleWidth() { attrs.flags.insert(.doublewidth) }

    /// Clears the grapheme, marking the cell blank.
    mutating func clearText() { text = "" }

    /// Adjusts default colors in place against a default highlight group.
    mutating func adjustDefaults(_ def: CellAttributes) {
        adjustDefaultColors(&attrs, against: def)
    }
}
