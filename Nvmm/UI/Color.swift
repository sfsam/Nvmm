//
//  Nvmm
//  Color.swift
//
//  An sRGB color as delivered by Neovim's UI protocol.
//
//  Neovim packs colors as a 24-bit `0xRRGGBB` integer. This type stores them in
//  a 32-bit value whose lowest three bytes are red, green, blue (in that
//  order), so the raw value maps directly onto a GPU-friendly RGBA byte layout.
//  The high bit flags a "default" color: a highlight attribute that Neovim did
//  not set explicitly, to be filled in from the default highlight group.
//

import Foundation

/// An sRGB color with a "default" flag, matching Neovim's highlight model.
nonisolated struct RGBColor: Sendable, Equatable {
    /// Byte layout: `0x00BBGGRR`, with bit 31 set when the color is a default.
    private var value: UInt32

    private static let isDefaultBit: UInt32 = 1 << 31

    /// A zero color with no default flag.
    init() { value = 0 }

    /// Builds a color from Neovim's packed `0xRRGGBB` integer.
    init(neovim rgb: UInt32) {
        // 0x00RRGGBB -> shift to 0xRRGGBB00 -> byte-swap to 0x00BBGGRR.
        value = (rgb << 8).byteSwapped
    }

    /// Builds a color from Neovim's packed integer and marks it a default color.
    init(neovim rgb: UInt32, default _: Void) {
        value = (rgb << 8).byteSwapped | Self.isDefaultBit
    }

    /// Builds a color from individual components; never a default color.
    init(red: UInt8, green: UInt8, blue: UInt8) {
        value = (UInt32(blue) << 16) | (UInt32(green) << 8) | UInt32(red)
    }

    /// True if this color stands in for the default highlight group's color.
    var isDefault: Bool { value & Self.isDefaultBit != 0 }

    var red: UInt8 { UInt8(value & 0xFF) }
    var green: UInt8 { UInt8((value >> 8) & 0xFF) }
    var blue: UInt8 { UInt8((value >> 16) & 0xFF) }

    /// The 24-bit `0x00BBGGRR` value with the default flag cleared.
    var rgb: UInt32 { value & 0xFFFFFF }

    /// The color as `0xFF` alpha over its RGB bytes.
    var opaque: UInt32 { (value & 0xFFFFFF) | 0xFF000000 }
}
