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

/// One configured font at its user-facing, unscaled point size.
struct ResolvedGuifontEntry {
    let descriptor: CTFontDescriptor
    let unscaledSize: CGFloat
}

/// The four faces of one typeface at a fixed size, plus layout metrics.
struct FontFamily {
    /// Faces indexed by `FontAttributes` raw order: none, bold, italic,
    /// bold italic.
    private var fonts: [CTFont]
    private var wideFonts: [CTFont]?

    /// The ordered source descriptors and sizes used to build this family.
    /// The first entry is primary; later entries are explicit fallbacks.
    fileprivate let resolvedEntries: [ResolvedGuifontEntry]
    fileprivate let wideEntry: ResolvedGuifontEntry?

    /// The primary size before applying `scaleFactor`, in points.
    var unscaledSize: CGFloat { resolvedEntries[0].unscaledSize }

    /// The backing-scale multiplier applied to `unscaledSize`.
    let scaleFactor: CGFloat

    fileprivate init(fonts: [CTFont], wideFonts: [CTFont]?,
                     resolvedEntries: [ResolvedGuifontEntry],
                     wideEntry: ResolvedGuifontEntry?,
                     scaleFactor: CGFloat) {
        self.fonts = fonts
        self.wideFonts = wideFonts
        self.resolvedEntries = resolvedEntries
        self.wideEntry = wideEntry
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
        let descriptor: CTFontDescriptor
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

    /// Resolves installed entries while preserving their configured order.
    static func makeResolvedGuifontEntries(
        _ entries: [GuifontEntry]
    ) -> [ResolvedGuifontEntry] {
        entries.compactMap { entry -> ResolvedGuifontEntry? in
            guard let descriptor = makeDescriptor(entry.name) else {
                return nil
            }
            return ResolvedGuifontEntry(
                descriptor: descriptor, unscaledSize: entry.size)
        }
    }

    private func font(for descriptor: CTFontDescriptor, size: CGFloat) -> CTFont {
        for entry in usedFonts where entry.size == size
            && CFEqual(entry.descriptor, descriptor) {
            return entry.font
        }

        let font = CTFontCreateWithFontDescriptorAndOptions(
            descriptor, size, nil, [])
        if usedFonts.count >= Self.maximumCachedFonts {
            usedFonts.removeFirst()
        }
        usedFonts.append(Entry(
            font: font, descriptor: descriptor, size: size))
        return font
    }

    /// A family built from primary and optional double-width descriptors.
    func family(descriptor: CTFontDescriptor, size: CGFloat,
                scaleFactor: CGFloat,
                wideDescriptor: CTFontDescriptor? = nil,
                wideSize: CGFloat? = nil) -> FontFamily {
        let primary = ResolvedGuifontEntry(
            descriptor: descriptor, unscaledSize: size)
        let wideEntry = wideDescriptor.map {
            ResolvedGuifontEntry(
                descriptor: $0, unscaledSize: wideSize ?? size)
        }
        return family(resolvedEntries: [primary], scaleFactor: scaleFactor,
                      wideEntry: wideEntry)
    }

    /// A family built from a nonempty ordered list: primary, then fallbacks.
    func family(resolvedEntries: [ResolvedGuifontEntry], scaleFactor: CGFloat,
                wideEntry: ResolvedGuifontEntry? = nil) -> FontFamily {
        precondition(!resolvedEntries.isEmpty)
        let primary = resolvedEntries[0]
        let fonts = faces(
            for: primary.descriptor,
            size: primary.unscaledSize * scaleFactor,
            fallbacks: Array(resolvedEntries.dropFirst()),
            scaleFactor: scaleFactor)
        let wideFonts: [CTFont]?
        if let wideEntry {
            wideFonts = faces(
                for: wideEntry.descriptor,
                size: wideEntry.unscaledSize * scaleFactor)
        } else {
            wideFonts = nil
        }
        return FontFamily(fonts: fonts, wideFonts: wideFonts,
                          resolvedEntries: resolvedEntries,
                          wideEntry: wideEntry,
                          scaleFactor: scaleFactor)
    }

    /// A copy of `family` with a new wide-font entry, reusing its existing
    /// primary and fallback descriptors unchanged.
    ///
    /// This still rebuilds the cascaded descriptor and goes through
    /// `font(for:size:)`; the non-wide faces come back identical only
    /// because that cache matches on `CFEqual(descriptor)` + size, not
    /// because construction is skipped. If the cache key ever changes,
    /// this stops being a no-op for those faces.
    func family(reusing family: FontFamily, wideEntry: ResolvedGuifontEntry?,
                scaleFactor: CGFloat) -> FontFamily {
        self.family(resolvedEntries: family.resolvedEntries,
                    scaleFactor: scaleFactor, wideEntry: wideEntry)
    }

    /// A copy of `family` at a new unscaled size, otherwise equivalent.
    func resized(_ family: FontFamily, size: CGFloat,
                 scaleFactor: CGFloat) -> FontFamily {
        let delta = size - family.unscaledSize
        let resolvedEntries = family.resolvedEntries.map {
            ResolvedGuifontEntry(
                descriptor: $0.descriptor,
                unscaledSize: max(1, $0.unscaledSize + delta))
        }
        let wideEntry = family.wideEntry.map {
            ResolvedGuifontEntry(
                descriptor: $0.descriptor,
                unscaledSize: max(1, $0.unscaledSize + delta))
        }
        return self.family(
            resolvedEntries: resolvedEntries,
            scaleFactor: scaleFactor, wideEntry: wideEntry)
    }

    private func faces(for descriptor: CTFontDescriptor,
                       size: CGFloat,
                       fallbacks: [ResolvedGuifontEntry] = [],
                       scaleFactor: CGFloat = 1) -> [CTFont] {
        let descriptor = cascadedDescriptor(
            descriptor, fallbacks: fallbacks, scaleFactor: scaleFactor)
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

    /// Attaches an ordered CoreText cascade to `descriptor`.
    ///
    /// Each fallback's own size attribute is set here for completeness, but
    /// CoreText does not honor it when substituting a glyph: a face picked
    /// from the cascade list is always sized to match the primary face,
    /// not its own configured size. Fallback fonts only ever contribute a
    /// choice of typeface, never an independent size.
    private func cascadedDescriptor(
        _ descriptor: CTFontDescriptor,
        fallbacks: [ResolvedGuifontEntry],
        scaleFactor: CGFloat
    ) -> CTFontDescriptor {
        guard !fallbacks.isEmpty else { return descriptor }
        let cascade = fallbacks.map { fallback in
            let attributes = [
                kCTFontSizeAttribute as String:
                    fallback.unscaledSize * scaleFactor,
            ] as CFDictionary
            return CTFontDescriptorCreateCopyWithAttributes(
                fallback.descriptor, attributes)
        }
        let attributes = [
            kCTFontCascadeListAttribute as String: cascade,
        ] as CFDictionary
        return CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes)
    }
}
