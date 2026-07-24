//
//  Nvmm
//  FontManager.swift
//
//  Font selection and metrics via CoreText.
//
//  A `FontFamily` bundles the four faces (regular, bold, italic, bold italic)
//  used to render a cell's `FontAttributes`, plus the metrics the renderer
//  needs to lay out cells and line decorations. A `FontManager` creates and
//  caches the underlying `CTFont` objects: equivalent fonts always share one
//  `CTFont`, so glyph caches can key on font identity cheaply.
//

import AppKit
import CoreText

/// The four faces of one typeface at a fixed size, plus layout metrics.
struct FontFamily {
    /// Faces indexed by `FontAttributes` raw order: none, bold, italic,
    /// bold italic.
    private var fonts: [CTFont]

    /// The size before applying `scaleFactor`, in points.
    let unscaledSize: CGFloat

    /// The backing-scale multiplier applied to `unscaledSize`.
    let scaleFactor: CGFloat

    fileprivate init(fonts: [CTFont], unscaledSize: CGFloat, scaleFactor: CGFloat) {
        self.fonts = fonts
        self.unscaledSize = unscaledSize
        self.scaleFactor = scaleFactor
    }

    /// The regular face.
    var regular: CTFont { fonts[0] }

    /// The face matching the given cell attributes.
    func font(_ attributes: FontAttributes) -> CTFont {
        switch attributes {
        case .none: return fonts[0]
        case .bold: return fonts[1]
        case .italic: return fonts[2]
        case .boldItalic: return fonts[3]
        }
    }

    /// The scaled point size (equal to `unscaledSize * scaleFactor`).
    var size: CGFloat { CTFontGetSize(regular) }

    var leading: CGFloat { CTFontGetLeading(regular) }
    var ascent: CGFloat { CTFontGetAscent(regular) }
    var descent: CGFloat { CTFontGetDescent(regular) }
    var underlinePosition: CGFloat { CTFontGetUnderlinePosition(regular) }
    var underlineThickness: CGFloat { CTFontGetUnderlineThickness(regular) }

    /// The advance width of a representative glyph. Assumes a monospaced font;
    /// for others this is a reasonable estimate.
    var width: CGFloat {
        var character = UniChar("M".utf16.first!)
        var glyph = CGGlyph(0)
        CTFontGetGlyphsForCharacters(regular, &character, &glyph, 1)

        if glyph == 0 {
            return CTFontGetBoundingBox(regular).size.width
        }

        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)
        return advance.width
    }
}

/// Creates and caches `CTFont` objects so equivalent fonts share one instance.
///
/// Fonts are retained for the manager's lifetime, so a font's address uniquely
/// identifies it for hashing and equality. This keeps fonts cheap to compare
/// and lets glyph caches key on font identity.
final class FontManager {
    private struct Entry {
        let font: CTFont
        let name: String
        let size: CGFloat
    }

    private var usedFonts: [Entry] = []

    // Nonisolated so teardown skips the isolated-deinit executor hop that trips
    // a libmalloc double-free under XCTest's post-test memory checker.
    nonisolated deinit {}

    /// A monospaced system-font descriptor with no symbolic traits set, ready
    /// to be resized and restyled.
    static func defaultDescriptor() -> CTFontDescriptor {
        // The empty-traits copy is what yields a normal, resizable, restylable
        // descriptor; a copy with traits later fails without it.
        let system = NSFont.systemFont(ofSize: 0).fontDescriptor
        let monospaced = system.withDesign(.monospaced) ?? system
        return monospaced.withSymbolicTraits([]) as CTFontDescriptor
    }

    /// A descriptor matching a named font, or nil if none matches.
    static func makeDescriptor(_ name: String) -> CTFontDescriptor? {
        let attributes = [kCTFontNameAttribute as String: name] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes)
        return CTFontDescriptorCreateMatchingFontDescriptor(descriptor, nil)
    }

    private func font(for descriptor: CTFontDescriptor, size: CGFloat) -> CTFont {
        let name = (CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute)
            as? String) ?? ""

        for entry in usedFonts where entry.size == size && entry.name == name {
            return entry.font
        }

        let font = CTFontCreateWithFontDescriptorAndOptions(
            descriptor, size, nil, [])
        usedFonts.append(Entry(font: font, name: name, size: size))
        return font
    }

    /// A family built from a descriptor at the given unscaled size.
    func family(descriptor: CTFontDescriptor, size: CGFloat,
                scaleFactor: CGFloat) -> FontFamily {
        let scaledSize = size * scaleFactor
        let mask: CTFontSymbolicTraits = [.traitBold, .traitItalic]

        let boldDescriptor = CTFontDescriptorCreateCopyWithSymbolicTraits(
            descriptor, .traitBold, mask)
        let italicDescriptor = CTFontDescriptorCreateCopyWithSymbolicTraits(
            descriptor, .traitItalic, mask)
        let boldItalicDescriptor = CTFontDescriptorCreateCopyWithSymbolicTraits(
            descriptor, mask, mask)

        let regular = font(for: descriptor, size: scaledSize)
        let bold = boldDescriptor.map { font(for: $0, size: scaledSize) } ?? regular
        let italic = italicDescriptor.map { font(for: $0, size: scaledSize) } ?? regular
        let boldItalic = boldItalicDescriptor.map {
            font(for: $0, size: scaledSize)
        } ?? regular

        return FontFamily(fonts: [regular, bold, italic, boldItalic],
                          unscaledSize: size, scaleFactor: scaleFactor)
    }

    /// A copy of `family` at a new unscaled size, otherwise equivalent.
    func resized(_ family: FontFamily, size: CGFloat,
                 scaleFactor: CGFloat) -> FontFamily {
        let scaledSize = size * scaleFactor
        let faces: [FontAttributes] = [.none, .bold, .italic, .boldItalic]
        let fonts = faces.map { face -> CTFont in
            let descriptor = CTFontCopyFontDescriptor(family.font(face))
            return font(for: descriptor, size: scaledSize)
        }
        return FontFamily(fonts: fonts, unscaledSize: size, scaleFactor: scaleFactor)
    }
}
