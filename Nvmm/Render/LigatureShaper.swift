//
//  Nvmm
//  LigatureShaper.swift
//
//  Resolves programming ligatures to one substituted glyph per cell.
//
//  Neovim's grid gives each cell its own grapheme, so a cell shaped alone can
//  never form a ligature: `->` is a hyphen beside a greater-than. Fonts built
//  for code — Fira Code, Iosevka, JetBrains Mono, Cascadia Code — substitute
//  one glyph per character at the font's normal advance, so column alignment
//  survives. Shaping a run of cells together and keeping the substituted ids
//  therefore yields the ligature while leaving every cell one glyph at its own
//  position, in its own color. Where the ink lands within the run is the
//  font's business; see `LigaturePlacement`.
//
//  Runs are maximal sequences of adjacent ASCII-punctuation cells sharing one
//  face. Restricting the alphabet to punctuation covers every programming
//  ligature and keeps the shaping cache small: letters and digits would make it
//  grow with each distinct word on screen. A font that collapses characters
//  into fewer glyphs, or that resolves the run through a fallback face, is
//  rejected outright; those cells fall back to ordinary per-cell rendering.
//

import CoreText
import Foundation

/// Where one cell's ligature glyph sits.
///
/// A ligature's ink is not spread evenly over its cells: a font may leave every
/// cell but one empty and put the whole mark in a single glyph that reaches
/// back across the others. The run it belongs to travels with the glyph so the
/// renderer can anchor the run at its first cell, which is what lets that ink
/// cover every cell it spans.
nonisolated struct LigaturePlacement: Equatable, Sendable {
    /// The substituted glyph, or 0 when the cell renders from its grapheme.
    var glyph: CGGlyph = 0
    /// The run's first column within the row.
    var start: Int16 = 0
    /// The run's length in cells.
    var length: Int16 = 0
}

/// Shapes runs of ASCII punctuation and caches the substituted glyph ids.
final class LigatureShaper {
    /// Runs are short and drawn from a 32-character alphabet, so this bound is
    /// reached only by pathological text. Clearing wholesale keeps the cache
    /// free of eviction bookkeeping; the cost is one reshape per visible run.
    private static let maximumCachedRuns = 2048

    private struct Key: Hashable {
        let font: CTFont
        let text: String

        static func == (lhs: Key, rhs: Key) -> Bool {
            lhs.font === rhs.font && lhs.text == rhs.text
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(font))
            hasher.combine(text)
        }
    }

    /// Substituted glyph ids per run, or nil when the run does not ligate.
    private var cache: [Key: [CGGlyph]?] = [:]
    private var scratch: [UInt8] = []

    // Nonisolated so teardown skips the isolated-deinit executor hop that trips
    // a libmalloc double-free under XCTest's post-test memory checker.
    nonisolated deinit {}

    /// Discards cached runs, releasing the fonts they retain.
    func reset() {
        cache.removeAll(keepingCapacity: true)
    }

    /// Fills `glyphs` with one entry per cell of `row`: the substituted glyph
    /// for a cell inside a ligature, or a zero glyph for a cell to render
    /// normally.
    func shape(row: ArraySlice<Cell>, family: FontFamily,
               into glyphs: inout [LigaturePlacement]) {
        let count = row.count
        if glyphs.count == count {
            for index in glyphs.indices { glyphs[index] = LigaturePlacement() }
        } else {
            glyphs = [LigaturePlacement](repeating: LigaturePlacement(),
                                         count: count)
        }

        let base = row.startIndex
        var start = 0
        while start < count {
            guard let face = runFace(row[base + start]) else {
                start += 1
                continue
            }
            var end = start + 1
            while end < count, runFace(row[base + end]) == face { end += 1 }
            if end - start >= 2 {
                apply(row: row, base: base, range: start..<end,
                      font: family.font(face), into: &glyphs)
            }
            start = end
        }
    }

    /// The face a cell would shape with, or nil if it cannot join a run.
    private func runFace(_ cell: Cell) -> FontAttributes? {
        guard cell.width == 1 else { return nil }
        var scalars = cell.text.unicodeScalars.makeIterator()
        guard let scalar = scalars.next(), scalars.next() == nil,
              Self.isRunCharacter(scalar) else {
            return nil
        }
        return cell.fontAttributes
    }

    /// The printable ASCII punctuation and symbols, excluding the space.
    private static func isRunCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: return true
        default: return false
        }
    }

    /// Writes one run's substituted glyphs, shaping it on first use.
    private func apply(row: ArraySlice<Cell>, base: Int, range: Range<Int>,
                       font: CTFont, into glyphs: inout [LigaturePlacement]) {
        scratch.removeAll(keepingCapacity: true)
        for index in range {
            // Every run character is one ASCII byte, checked by `runFace`.
            scratch.append(row[base + index].text.utf8.first!)
        }
        // Runs of 15 or fewer characters stay in Swift's inline string
        // representation, so the common lookup allocates nothing.
        let text = String(decoding: scratch, as: UTF8.self)
        let key = Key(font: font, text: text)

        let shaped: [CGGlyph]?
        if let cached = cache[key] {
            shaped = cached
        } else {
            shaped = Self.substitutedGlyphs(font: font, text: text)
            if cache.count >= Self.maximumCachedRuns {
                cache.removeAll(keepingCapacity: true)
            }
            cache[key] = shaped
        }

        guard let shaped else { return }
        for (offset, index) in range.enumerated() {
            glyphs[index] = LigaturePlacement(
                glyph: shaped[offset], start: Int16(range.lowerBound),
                length: Int16(range.count))
        }
    }

    /// The glyphs CoreText substitutes for `text`, or nil when the font leaves
    /// the run unchanged, needs a fallback face, or does not keep one glyph per
    /// character. The result never contains 0, so callers can use it as the
    /// "no ligature here" marker.
    private static func substitutedGlyphs(font: CTFont,
                                          text: String) -> [CGGlyph]? {
        // The run is ASCII, so UTF-16 units, characters, and cells all agree.
        var characters = Array(text.utf16)
        let count = characters.count

        // Only the font is set, as the rasterizer does, so CoreText applies the
        // font's default features — which include contextual alternates.
        let attributed = NSAttributedString(
            string: text,
            attributes: [.init(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun],
              let run = runs.first, runs.count == 1,
              CTRunGetGlyphCount(run) == count else {
            return nil
        }
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let selected = attributes[kCTFontAttributeName],
              CFEqual(selected as! CTFont, font) else {
            return nil
        }

        var shaped = [CGGlyph](repeating: 0, count: count)
        CTRunGetGlyphs(run, CFRangeMake(0, count), &shaped)
        guard !shaped.contains(0) else { return nil }

        var plain = [CGGlyph](repeating: 0, count: count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &plain, count),
              shaped != plain else {
            return nil
        }
        return shaped
    }
}
