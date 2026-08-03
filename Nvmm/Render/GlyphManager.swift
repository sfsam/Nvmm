//
//  Nvmm
//  GlyphManager.swift
//
//  Rasterizes glyphs on demand and caches them in GPU texture atlases.
//
//  Ordinary text is cached independently of its display colors in a one-byte
//  coverage atlas. Color glyphs use a separate RGBA atlas; their key retains
//  the foreground because a CoreText grapheme can contain both color and text
//  runs. After committing a frame, call `evict` to cull old cache pages.
//

import CoreText
import Metal
import simd

/// A cached glyph and the atlas containing its pixels.
nonisolated struct CachedGlyph {
    let rect: glyph_rect
    let format: GlyphBitmapFormat
}

final class GlyphManager {
    private struct BaseKey: Hashable {
        let font: CTFont
        let text: String

        static func == (lhs: BaseKey, rhs: BaseKey) -> Bool {
            lhs.font === rhs.font && lhs.text == rhs.text
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(font))
            hasher.combine(text)
        }
    }

    private struct MaskKey: Hashable {
        let base: BaseKey
        let options: GlyphRasterizationOptions
    }

    private struct ColorKey: Hashable {
        let base: BaseKey
        let foreground: UInt32
        let options: GlyphRasterizationOptions
    }

    private let rasterizer: GlyphRasterizer
    private let maskCache: GlyphTextureCache
    private let colorCache: GlyphTextureCache
    private let evictThreshold: Int
    private let evictPreserve: Int
    private var options: GlyphRasterizationOptions
    private var maskMap: [MaskKey: CachedGlyph] = [:]
    private var colorMap: [ColorKey: CachedGlyph] = [:]
    private var maskNeedsEviction = false
    private var colorNeedsEviction = false

    init(rasterizer: GlyphRasterizer, maskCache: GlyphTextureCache,
         colorCache: GlyphTextureCache, evictThreshold: Int,
         evictPreserve: Int, options: GlyphRasterizationOptions) {
        self.rasterizer = rasterizer
        self.maskCache = maskCache
        self.colorCache = colorCache
        self.evictThreshold = evictThreshold
        self.evictPreserve = evictPreserve
        self.options = options
    }

    // Nonisolated so teardown skips the isolated-deinit executor hop that trips
    // a libmalloc double-free under XCTest's post-test memory checker.
    nonisolated deinit {}

    /// The coverage-mask texture for ordinary text.
    var maskTexture: MTLTexture { maskCache.texture }

    /// The premultiplied RGBA texture for intrinsically colored glyphs.
    var colorTexture: MTLTexture { colorCache.texture }

    /// Applies new rasterization settings and discards obsolete cache pages
    /// when replacement textures can be allocated. The options remain in each
    /// key, so a failed reset cannot return pixels made with an old setting.
    func update(options newOptions: GlyphRasterizationOptions) {
        guard newOptions != options else { return }
        options = newOptions
        if maskCache.reset() {
            maskMap.removeAll(keepingCapacity: true)
            maskNeedsEviction = false
        }
        if colorCache.reset() {
            colorMap.removeAll(keepingCapacity: true)
            colorNeedsEviction = false
        }
    }

    /// A cached glyph for the given font, text, and foreground, rasterizing and
    /// caching it on first use.
    func glyph(font: CTFont, text: String,
               foreground: RGBColor) -> CachedGlyph {
        let base = BaseKey(font: font, text: text)
        let maskKey = MaskKey(base: base, options: options)
        if let cached = maskMap[maskKey] { return cached }

        let colorKey = ColorKey(base: base, foreground: foreground.opaque,
                                options: options)
        if let cached = colorMap[colorKey] { return cached }

        let bitmap = rasterizer.rasterize(
            font: font, foreground: foreground, text: text, options: options)
        let cache = bitmap.format == .mask ? maskCache : colorCache
        guard let position = cache.add(bitmap) else {
            if bitmap.format == .mask {
                maskNeedsEviction = true
            } else {
                colorNeedsEviction = true
            }
            return CachedGlyph(
                rect: glyph_rect(size: .zero, position: .zero,
                                 texture_origin: .zero),
                format: bitmap.format)
        }

        let cached = CachedGlyph(
            rect: glyph_rect(
                size: simd_short2(bitmap.width, bitmap.height),
                position: simd_short2(bitmap.leftBearing, -bitmap.ascent),
                texture_origin: position),
            format: bitmap.format)
        if bitmap.format == .mask {
            maskMap[maskKey] = cached
        } else {
            colorMap[colorKey] = cached
        }
        return cached
    }

    /// A cached glyph for a cell, using the cell's own font and foreground.
    func glyph(family: FontFamily, cell: Cell,
               foreground: RGBColor) -> CachedGlyph {
        let font = family.font(cell.fontAttributes, wide: cell.width == 2)
        return glyph(font: font, text: cell.text, foreground: foreground)
    }

    /// Evicts old pages independently from both texture atlases.
    func evict() {
        if maskNeedsEviction || maskCache.pagesCapacity > evictThreshold {
            maskNeedsEviction = !performEviction(
                cache: maskCache, map: &maskMap)
        }
        if colorNeedsEviction || colorCache.pagesCapacity > evictThreshold {
            colorNeedsEviction = !performEviction(
                cache: colorCache, map: &colorMap)
        }
    }

    private func performEviction<Key: Hashable>(
        cache: GlyphTextureCache, map: inout [Key: CachedGlyph]
    ) -> Bool {
        guard let evicted = cache.evict(preserve: evictPreserve) else {
            return false
        }

        if evicted == 0 {
            if evictPreserve == 0 { map.removeAll() }
            return true
        }

        let shift = Int16(evicted)
        var newMap: [Key: CachedGlyph] = [:]
        newMap.reserveCapacity(map.count)
        for (key, value) in map where value.rect.texture_origin.z >= shift {
            var rect = value.rect
            rect.texture_origin.z -= shift
            newMap[key] = CachedGlyph(rect: rect, format: value.format)
        }
        map = newMap
        return true
    }
}
