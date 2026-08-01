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
    private var wideFonts: [CTFont]?

    /// The size before applying `scaleFactor`, in points.
    let unscaledSize: CGFloat
    fileprivate let wideUnscaledSize: CGFloat?

    /// The backing-scale multiplier applied to `unscaledSize`.
    let scaleFactor: CGFloat

    fileprivate init(fonts: [CTFont], wideFonts: [CTFont]?,
                     unscaledSize: CGFloat, wideUnscaledSize: CGFloat?,
                     scaleFactor: CGFloat) {
        self.fonts = fonts
        self.wideFonts = wideFonts
        self.unscaledSize = unscaledSize
        self.wideUnscaledSize = wideUnscaledSize
        self.scaleFactor = scaleFactor
    }

    /// The regular face.
    var regular: CTFont { fonts[0] }

    /// The face matching the given cell attributes and display width.
    func font(_ attributes: FontAttributes, wide: Bool = false) -> CTFont {
        let faces = wide ? wideFonts ?? fonts : fonts
        switch attributes {
        case .none: return faces[0]
        case .bold: return faces[1]
        case .italic: return faces[2]
        case .boldItalic: return faces[3]
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
/// Recently used fonts are retained in a bounded cache so equivalent requests
/// normally share one object. Glyph-cache keys retain their fonts
/// independently, so an address remains unique for as long as identity is used.
final class FontManager {
    // Covers every integer zoom size from 6 through 72 with four primary and
    // four optional wide faces, plus room for the initial family.
    private static let maximumCachedFonts = 576

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
        if usedFonts.count >= Self.maximumCachedFonts {
            usedFonts.removeFirst()
        }
        usedFonts.append(Entry(font: font, name: name, size: size))
        return font
    }

    /// A family built from primary and optional double-width descriptors.
    func family(descriptor: CTFontDescriptor, size: CGFloat,
                scaleFactor: CGFloat,
                wideDescriptor: CTFontDescriptor? = nil,
                wideSize: CGFloat? = nil) -> FontFamily {
        let fonts = faces(for: descriptor, size: size * scaleFactor)
        let resolvedWideSize = wideDescriptor.map { _ in wideSize ?? size }
        let wideFonts: [CTFont]?
        if let wideDescriptor, let resolvedWideSize {
            wideFonts = faces(
                for: wideDescriptor, size: resolvedWideSize * scaleFactor)
        } else {
            wideFonts = nil
        }
        return FontFamily(fonts: fonts, wideFonts: wideFonts,
                          unscaledSize: size,
                          wideUnscaledSize: resolvedWideSize,
                          scaleFactor: scaleFactor)
    }

    /// A copy of `family` at a new unscaled size, otherwise equivalent.
    func resized(_ family: FontFamily, size: CGFloat,
                 scaleFactor: CGFloat) -> FontFamily {
        let faces: [FontAttributes] = [.none, .bold, .italic, .boldItalic]
        let fonts = faces.map {
            font(for: CTFontCopyFontDescriptor(family.font($0)),
                 size: size * scaleFactor)
        }
        let wideSize = family.wideUnscaledSize.map {
            max(1, $0 + size - family.unscaledSize)
        }
        let wideFonts = wideSize.map { wideSize in
            faces.map {
                font(for: CTFontCopyFontDescriptor(
                    family.font($0, wide: true)),
                     size: wideSize * scaleFactor)
            }
        }
        return FontFamily(fonts: fonts, wideFonts: wideFonts,
                          unscaledSize: size, wideUnscaledSize: wideSize,
                          scaleFactor: scaleFactor)
    }

    private func faces(for descriptor: CTFontDescriptor,
                       size: CGFloat) -> [CTFont] {
        let mask: CTFontSymbolicTraits = [.traitBold, .traitItalic]
        let boldDescriptor = CTFontDescriptorCreateCopyWithSymbolicTraits(
            descriptor, .traitBold, mask)
        let italicDescriptor = CTFontDescriptorCreateCopyWithSymbolicTraits(
            descriptor, .traitItalic, mask)
        let boldItalicDescriptor = CTFontDescriptorCreateCopyWithSymbolicTraits(
            descriptor, mask, mask)
        let regular = font(for: descriptor, size: size)
        let bold = boldDescriptor.map { font(for: $0, size: size) } ?? regular
        let italic = italicDescriptor.map { font(for: $0, size: size) } ?? regular
        let boldItalic = boldItalicDescriptor.map {
            font(for: $0, size: size)
        } ?? regular
        return [regular, bold, italic, boldItalic]
    }
}
