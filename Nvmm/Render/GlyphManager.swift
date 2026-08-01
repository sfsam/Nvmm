//
//  Nvmm
//  GlyphManager.swift
//
//  Rasterizes glyphs on demand and caches them in a texture cache.
//
//  A glyph manager guarantees that every glyph needed to render a frame is in
//  GPU memory. Cached glyphs are keyed by font identity, grapheme text, and the
//  foreground/background pair (colors matter because the rasterizer bakes them
//  into the bitmap). After committing a frame, call `evict` to let the manager
//  cull old cache pages.
//

import CoreText
import Metal
import simd

final class GlyphManager {
    private struct Key: Hashable {
        let font: CTFont
        let text: String
        let background: UInt32
        let foreground: UInt32

        static func == (lhs: Key, rhs: Key) -> Bool {
            lhs.font === rhs.font && lhs.text == rhs.text &&
                lhs.background == rhs.background &&
                lhs.foreground == rhs.foreground
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(font))
            hasher.combine(text)
            hasher.combine(background)
            hasher.combine(foreground)
        }
    }

    private let rasterizer: GlyphRasterizer
    private let textureCache: GlyphTextureCache
    private let evictThreshold: Int
    private let evictPreserve: Int
    private var map: [Key: glyph_rect] = [:]
    private var needsEviction = false

    init(rasterizer: GlyphRasterizer, textureCache: GlyphTextureCache,
         evictThreshold: Int, evictPreserve: Int) {
        self.rasterizer = rasterizer
        self.textureCache = textureCache
        self.evictThreshold = evictThreshold
        self.evictPreserve = evictPreserve
    }

    // Nonisolated so teardown skips the isolated-deinit executor hop that trips
    // a libmalloc double-free under XCTest's post-test memory checker.
    nonisolated deinit {}

    /// The texture holding the cached glyphs.
    var texture: MTLTexture { textureCache.texture }

    /// A cached glyph for the given font, text, and colors, rasterizing and
    /// caching it on first use.
    func glyph(font: CTFont, text: String, background: RGBColor,
               foreground: RGBColor) -> glyph_rect {
        let key = Key(font: font, text: text,
                      background: background.opaque, foreground: foreground.opaque)

        if let cached = map[key] { return cached }

        let bitmap = rasterizer.rasterize(font: font, background: background,
                                          foreground: foreground, text: text)
        guard let position = textureCache.add(bitmap) else {
            needsEviction = true
            return glyph_rect(size: .zero, position: .zero,
                              texture_origin: .zero)
        }

        let rect = glyph_rect(
            size: simd_short2(bitmap.width, bitmap.height),
            position: simd_short2(bitmap.leftBearing, -bitmap.ascent),
            texture_origin: position)

        map[key] = rect
        return rect
    }

    /// A cached glyph for a cell, using the cell's own font face and colors.
    func glyph(family: FontFamily, cell: Cell) -> glyph_rect {
        let font = family.font(cell.fontAttributes)
        return glyph(font: font, text: cell.text,
                     background: cell.background, foreground: cell.foreground)
    }

    /// A cached glyph for a cell rendered with explicit colors.
    func glyph(family: FontFamily, cell: Cell, background: RGBColor,
               foreground: RGBColor) -> glyph_rect {
        let font = family.font(cell.fontAttributes)
        return glyph(font: font, text: cell.text,
                     background: background, foreground: foreground)
    }

    /// Evicts old cache pages once the allocated page count exceeds the
    /// eviction threshold.
    func evict() {
        if needsEviction || textureCache.pagesCapacity > evictThreshold {
            needsEviction = !performEviction()
        }
    }

    private func performEviction() -> Bool {
        guard let evicted = textureCache.evict(
            preserve: evictPreserve) else {
            return false
        }

        if evicted == 0 {
            if evictPreserve == 0 { map.removeAll() }
            return true
        }

        let shift = Int16(evicted)
        var newMap: [Key: glyph_rect] = [:]
        newMap.reserveCapacity(map.count)
        for (key, value) in map where value.texture_origin.z >= shift {
            var shifted = value
            shifted.texture_origin.z -= shift
            newMap[key] = shifted
        }
        map = newMap
        return true
    }
}
