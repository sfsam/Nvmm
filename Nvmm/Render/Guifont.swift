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

/// Parses a `guifont` option string into an ordered list of entries.
///
/// - Parameters:
///   - guifont: The option string, e.g. `"Menlo:h13,Fira Code:h14"`.
///   - defaultSize: The size to use for an entry that omits `:h<size>`.
/// - Returns: The entries in list order; empty when `guifont` is empty.
nonisolated func parseGuifont(_ guifont: String,
                              defaultSize: CGFloat) -> [GuifontEntry] {
    var fonts: [GuifontEntry] = []
    if guifont.isEmpty { return fonts }

    let chars = Array(guifont)
    var index = 0

    while true {
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
    var index = chars.count
    var multiply = 1
    var size = 0

    // Accumulate a run of trailing ASCII digits, least significant first.
    while index > 0 {
        index -= 1
        let c = chars[index]
        if c.isASCII, c.isNumber, let digit = c.wholeNumberValue {
            size += multiply * digit
            multiply *= 10
        } else {
            break
        }
    }

    if size != 0 && index != 0 && chars[index] == "h" && chars[index - 1] == ":" {
        return GuifontEntry(name: String(chars[0..<(index - 1)]),
                            size: CGFloat(size))
    }

    return GuifontEntry(name: String(chars), size: defaultSize)
}
