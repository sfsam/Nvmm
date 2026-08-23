//
//  Nvmm
//  Guifont.swift
//
//  Parsing of Neovim's `guifont` option into font names and sizes.
//
//  `guifont` is a comma-separated list of fonts, each optionally suffixed with
//  `:h<size>` (a point size). Commas inside a font name are backslash-escaped.
//  The list is tried in order; the window uses the first face installed on the
//  system. This is pure value logic with no AppKit dependency.
//

import CoreGraphics

/// One parsed `guifont` entry: a font name and the size to render it at.
nonisolated struct GuifontEntry: Sendable, Equatable {
    var name: String
    var size: CGFloat
}

/// The integer point sizes a `:h` suffix may carry.
private nonisolated let guifontSizeRange = 1...512

/// Returns the concrete `guifont` value for a font-panel selection.
///
/// AppKit supplies a PostScript font name, which CoreText accepts directly.
/// The panel permits fractional and out-of-range sizes, so convert and clamp
/// the selection to a size the `:h` parser accepts.
nonisolated func guifontSpec(fontName: String,
                             pointSize: CGFloat) -> String? {
    guard !fontName.isEmpty, pointSize.isFinite else { return nil }
    let size = Int(min(max(pointSize, CGFloat(guifontSizeRange.lowerBound)),
                       CGFloat(guifontSizeRange.upperBound)))
    return "\(fontName):h\(size)"
}

/// Parses a `guifont` option string into an ordered list of entries.
///
/// - Parameters:
///   - guifont: The option string, e.g. `"Menlo:h13,Fira Code:h14"`.
///   - defaultSize: The size to use for an entry that omits `:h<size>`.
/// - Returns: The entries in list order; empty when `guifont` is empty.
nonisolated func parseGuifont(_ guifont: String,
                              defaultSize: CGFloat) -> [GuifontEntry] {
    let maximumEntries = 32
    var fonts: [GuifontEntry] = []
    if guifont.isEmpty { return fonts }

    let chars = Array(guifont)
    var index = 0

    while fonts.count < maximumEntries {
        guard let pos = findUnescapedComma(chars, from: index) else {
            fonts.append(makeGuifontEntry(chars[index...], defaultSize: defaultSize))
            break
        }

        fonts.append(makeGuifontEntry(chars[index..<pos], defaultSize: defaultSize))

        // Skip spaces after the separating comma, matching Vim's list syntax.
        var next = pos + 1
        while next < chars.count && chars[next] == " " { next += 1 }
        index = next

        // A trailing comma leaves nothing to parse. An empty name would never
        // match a font, so stop rather than adding an entry for it.
        if index >= chars.count { break }
    }

    return fonts
}

/// Returns the index of the next comma at or after `from` that is not escaped
/// by a preceding backslash, or nil when there is none.
private nonisolated func findUnescapedComma(_ chars: [Character],
                                            from: Int) -> Int? {
    var pos = from
    while pos < chars.count {
        if chars[pos] == "," && (pos == 0 || chars[pos - 1] != "\\") {
            return pos
        }
        pos += 1
    }
    return nil
}

/// Builds an entry from one list element, splitting off a trailing `:h<size>`
/// suffix. Without a valid suffix the whole element is the name and
/// `defaultSize` is used.
private nonisolated func makeGuifontEntry(_ fontstr: ArraySlice<Character>,
                                          defaultSize: CGFloat) -> GuifontEntry {
    let chars = Array(fontstr)

    // Find where the run of trailing ASCII digits begins.
    var start = chars.count
    while start > 0, chars[start - 1].isASCII, chars[start - 1].isNumber {
        start -= 1
    }

    // Read it most significant digit first, saturating one past the largest
    // accepted size. That keeps an oversized run out of range without
    // overflowing, however many digits it holds. The scan above accepted only
    // ASCII digits, so each has a numeric value.
    var size = 0
    for character in chars[start...] {
        size = min(size * 10 + (character.wholeNumberValue ?? 0),
                   guifontSizeRange.upperBound + 1)
    }

    // The run must be introduced by ":h" for it to be a size.
    if guifontSizeRange.contains(size), start >= 2,
       chars[start - 1] == "h", chars[start - 2] == ":" {
        return GuifontEntry(name: String(chars[0..<(start - 2)]),
                            size: CGFloat(size))
    }

    return GuifontEntry(name: String(chars), size: defaultSize)
}
