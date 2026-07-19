//
//  Nvmm
//  Highlight.swift
//
//  Highlight attributes and semantic highlight groups.
//
//  `CellAttributes` is the resolved appearance of a highlight id: three colors,
//  a bitset of style flags, and an optional blend percentage. Neovim predefines
//  highlights in a table keyed by id (see `hl_attr_define`); index 0 is the
//  default group. `HLGroup` classifies a handful of semantic groups (status
//  line, separator, tab line) that the renderer treats specially.
//

import Foundation

/// The style flags a highlight can carry, matching Neovim's `hl_attr_define` keys.
nonisolated struct CellFlags: OptionSet, Sendable, Hashable {
    let rawValue: UInt16
    init(rawValue: UInt16) { self.rawValue = rawValue }

    static let bold          = CellFlags(rawValue: 1 << 0)
    static let italic        = CellFlags(rawValue: 1 << 1)
    static let emoji         = CellFlags(rawValue: 1 << 2)
    static let underline     = CellFlags(rawValue: 1 << 3)
    static let undercurl     = CellFlags(rawValue: 1 << 4)
    static let strikethrough = CellFlags(rawValue: 1 << 5)
    static let doublewidth   = CellFlags(rawValue: 1 << 6)
    static let reverse       = CellFlags(rawValue: 1 << 7)
    static let underdouble   = CellFlags(rawValue: 1 << 8)
    static let underdotted   = CellFlags(rawValue: 1 << 9)
    static let underdashed   = CellFlags(rawValue: 1 << 10)
    static let overline      = CellFlags(rawValue: 1 << 11)
    static let dim           = CellFlags(rawValue: 1 << 12)
    static let nocombine     = CellFlags(rawValue: 1 << 13)
    static let specialColor  = CellFlags(rawValue: 1 << 14)

    /// The flags that place a line on or through the glyph.
    static let lineEmphasis: CellFlags = [
        .underline, .undercurl, .strikethrough, .underdouble,
        .underdotted, .underdashed, .overline
    ]

    /// The flags that draw an underline in any of its styles.
    static let anyUnderline: CellFlags = [
        .underline, .underdouble, .underdotted, .underdashed
    ]
}

/// The resolved appearance of a highlight id.
nonisolated struct CellAttributes: Sendable, Equatable {
    /// The value of `blend` when Neovim provided no blend percentage.
    static let noBlend: UInt8 = .max

    var background = RGBColor()
    var foreground = RGBColor()
    var special = RGBColor()
    var flags: CellFlags = []
    var blend: UInt8 = CellAttributes.noBlend

    init() {}

    /// The default highlight group: all three colors are flagged as defaults.
    static var defaultGroup: CellAttributes {
        var attrs = CellAttributes()
        attrs.foreground = RGBColor(neovim: 0, default: ())
        attrs.background = RGBColor(neovim: 0, default: ())
        attrs.special = RGBColor(neovim: 0, default: ())
        return attrs
    }
}

/// Fills a highlight's default-flagged colors from the default group `def`.
///
/// A reversed highlight swaps foreground and background when pulling defaults. A
/// missing special color uses the (already resolved) foreground when the highlight
/// draws a line, otherwise the default group's special color.
nonisolated func adjustDefaultColors(_ attrs: inout CellAttributes,
                                     against def: CellAttributes) {
    let reversed = attrs.flags.contains(.reverse)

    if attrs.foreground.isDefault {
        attrs.foreground = reversed ? def.background : def.foreground
    }
    if attrs.background.isDefault {
        attrs.background = reversed ? def.foreground : def.background
    }
    if attrs.special.isDefault {
        attrs.special = attrs.flags.isDisjoint(with: .lineEmphasis)
            ? def.special : attrs.foreground
    }
}

/// A semantic classification of a highlight group, used to give the renderer
/// pointer-style hints. Multiple groups can share a highlight id, so this is a
/// bitset.
nonisolated struct HLGroup: OptionSet, Sendable, Hashable {
    let rawValue: UInt8
    init(rawValue: UInt8) { self.rawValue = rawValue }

    /// No semantic group; the renderer treats the cell normally.
    static let normal: HLGroup = []
    static let statusLine = HLGroup(rawValue: 1 << 0)
    static let separator  = HLGroup(rawValue: 1 << 1)
    static let tabline    = HLGroup(rawValue: 1 << 2)
}
