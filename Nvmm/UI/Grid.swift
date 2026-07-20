//
//  Nvmm
//  Grid.swift
//
//  The grid model: a 2-D array of cells plus cursor, mode, and viewport state.
//
//  A `Grid` is a value type. The UI controller mutates one authoritative grid
//  as redraw events arrive and, on `flush`, publishes an immutable copy — a
//  snapshot the renderer consumes without locks. This value-semantics hand-off
//  lets a completed frame cross to the renderer with no shared mutable state.
//
//  Mode classification lives here too: Neovim describes the current mode with a
//  name and a short name; `UIMode` reduces those to the small set of
//  distinctions the UI acts on (text entry, visual selection, composition
//  displacement).
//

import Foundation

// MARK: - Modes

/// Neovim's descriptive UI mode, reduced to the cases the UI distinguishes.
nonisolated enum UIMode: Sendable {
    case normal, insert, replace, virtualReplace, commandLine
    case terminal, visual, select, prompt, other
}

/// The text-entry policy a mode implies, driving how committed text is routed.
nonisolated enum TextEntryMode: Sendable, Equatable {
    case insert, replace, commandLine, terminal, directNeovim
}

/// Maps a Neovim mode `name` (from `mode_info_set`) to a `UIMode`, if recognized.
nonisolated func classifyUIModeName(_ name: String) -> UIMode? {
    switch name {
    case "normal": return .normal
    case "insert": return .insert
    case "replace": return .replace
    case "vreplace": return .virtualReplace
    case "cmdline_normal", "cmdline_insert", "cmdline_replace": return .commandLine
    case "terminal": return .terminal
    case "visual": return .visual
    case "visual_select", "select": return .select
    case "prompt": return .prompt
    default: return nil
    }
}

/// Maps a Neovim mode short name to a `UIMode`, if recognized. Used as a fallback
/// when a mode's descriptive name is absent or unknown.
nonisolated func classifyUIModeShortname(_ shortname: String) -> UIMode? {
    switch shortname {
    case "n": return .normal
    case "i", "ic", "ix": return .insert
    case "R", "Rc", "Rx": return .replace
    case "Rv", "Rvc", "Rvx": return .virtualReplace
    case "c", "cv", "ce": return .commandLine
    case "t": return .terminal
    case "v", "V", "\u{16}": return .visual
    case "s", "S", "\u{13}": return .select
    case "r": return .prompt
    default: return nil
    }
}

/// True if the mode is a linewise/charwise Visual selection (not Select mode).
nonisolated func isVisualSelection(_ mode: UIMode) -> Bool { mode == .visual }

/// True if a composition preedit should displace cells rather than overwrite them.
nonisolated func displacesForComposition(_ mode: UIMode) -> Bool { mode == .insert }

/// The text-entry policy implied by a mode.
nonisolated func textEntryMode(for mode: UIMode) -> TextEntryMode {
    switch mode {
    case .insert: return .insert
    case .replace, .virtualReplace: return .replace
    case .commandLine: return .commandLine
    case .terminal: return .terminal
    default: return .directNeovim
    }
}

/// True if the mode accepts committed text (as opposed to raw key routing).
nonisolated func acceptsTextInput(_ mode: UIMode) -> Bool {
    textEntryMode(for: mode) != .directNeovim
}

// MARK: - Cursor

/// The cursor shape Neovim requests for a mode.
nonisolated enum CursorShape: UInt8, Sendable {
    case block, horizontal, vertical, blockOutline
}

/// The appearance and blink behavior of the cursor in a given mode.
nonisolated struct CursorAttributes: Sendable, Equatable {
    var foreground = RGBColor()
    var background = RGBColor()
    var special = RGBColor()
    var shape: CursorShape = .block
    var blinks = false
    /// The mode's short name, packed as up to two little-endian UTF-8 bytes.
    var shortname: UInt16 = 0
    var percentage: UInt16 = 0
    var blinkwait: UInt16 = 0
    var blinkon: UInt16 = 0
    var blinkoff: UInt16 = 0

    /// Packs a mode short name the way `mode_info_set` stores it for matching.
    static func encodeShortname(_ value: String) -> UInt16 {
        var packed: UInt16 = 0
        for (index, byte) in value.utf8.prefix(2).enumerated() {
            packed |= UInt16(byte) << (8 * index)
        }
        return packed
    }
}

/// A mode's semantic classification paired with its cursor presentation.
nonisolated struct ModeState: Sendable, Equatable {
    var semantic: UIMode = .normal
    var cursor = CursorAttributes()
}

/// The grid's cursor: a position, the cell beneath it, and resolved colors.
///
/// Colors flagged as defaults are filled from the underlying cell. When both
/// foreground and background are defaults, they are swapped so the cursor inverts
/// the cell, matching Neovim's default cursor presentation.
nonisolated struct Cursor: Sendable, Equatable {
    let row: Int
    let column: Int
    let cell: Cell
    private(set) var foreground: RGBColor
    private(set) var background: RGBColor
    private(set) var special: RGBColor
    var shape: CursorShape
    let blinks: Bool
    let blinkwait: UInt16
    let blinkon: UInt16
    let blinkoff: UInt16

    init(row: Int, column: Int, cell: Cell, attributes: CursorAttributes) {
        self.row = row
        self.column = column
        self.cell = cell
        shape = attributes.shape
        blinks = attributes.blinks
        blinkwait = attributes.blinkwait
        blinkon = attributes.blinkon
        blinkoff = attributes.blinkoff

        special = attributes.special
        foreground = attributes.foreground
        background = attributes.background

        if special.isDefault { special = cell.special }

        if background.isDefault {
            if foreground.isDefault {
                background = cell.foreground
                foreground = cell.background
                return
            }
            background = cell.background
        }
        if foreground.isDefault {
            foreground = cell.foreground
        }
    }

    /// The width of the underlying cell.
    var width: Int { cell.width }
}

// MARK: - Geometry

/// A grid's dimensions in cells.
nonisolated struct GridSize: Sendable, Equatable {
    var width: Int
    var height: Int
}

/// A cell position within a grid.
nonisolated struct GridPoint: Sendable, Equatable {
    var row: Int
    var column: Int
}

/// The visible portion of the buffer, from `win_viewport`.
nonisolated struct ViewportState: Sendable, Equatable {
    var topline = 0
    var botline = 0
    var lineCount = 0
}

// MARK: - Grid

/// A 2-D array of cells with cursor, mode, and draw-tick state.
nonisolated struct Grid: Sendable {
    /// Row-major cell storage; `cells[row * width + column]`.
    var cells: [Cell] = []
    private(set) var width = 0
    private(set) var height = 0
    var modeState = ModeState()
    var cursorRow = 0
    var cursorCol = 0
    /// Monotonic counter bumped on each flush; 0 means never drawn.
    var drawTick: UInt64 = 0
    var cursorHidden = false
    /// The window title Neovim last set (`set_title`), carried on the snapshot
    /// so the window can restore it after showing the grid size during resize.
    var title = "NVIM"
    /// Neovim's default background color, carried on the snapshot so the window
    /// can tint its margins and pick a matching title-bar appearance.
    var defaultBackground = RGBColor()
    /// The `ambiwidth`/`emoji` option state, carried on the snapshot so the
    /// view's composition width policy matches Neovim without a live query.
    var ambiguousWidthDouble = false
    var emojiWidthDouble = true

    init() {
        // Start in normal mode so the first `mode_info_set` can match by short
        // name before any `mode_change`.
        modeState.cursor.shortname = CursorAttributes.encodeShortname("n")
        modeState.cursor.shape = .block
    }

    // MARK: Queries

    /// The cell at the given position. The caller must keep the position in bounds.
    func cell(_ row: Int, _ column: Int) -> Cell {
        cells[row * width + column]
    }

    var size: GridSize { GridSize(width: width, height: height) }
    var cellCount: Int { cells.count }
    var tick: UInt64 { drawTick }
    var hideCursor: Bool { cursorHidden }
    var semanticMode: UIMode { modeState.semantic }
    var acceptsTextInput: Bool { Nvmm.acceptsTextInput(modeState.semantic) }
    var isVisualMode: Bool { isVisualSelection(modeState.semantic) }
    var displacesForComposition: Bool { Nvmm.displacesForComposition(modeState.semantic) }
    var textEntryMode: TextEntryMode { Nvmm.textEntryMode(for: modeState.semantic) }

    /// The grid's cursor, with colors resolved against the cell beneath it.
    var cursor: Cursor {
        Cursor(row: cursorRow, column: cursorCol,
               cell: cell(cursorRow, cursorCol), attributes: modeState.cursor)
    }

    /// The semantic highlight group of the cell at the given position.
    func pointerStyle(_ row: Int, _ column: Int) -> HLGroup {
        HLGroup(rawValue: cell(row, column).pointerStyle)
    }

    /// True if the cell holds a common vertical-separator glyph.
    func isVerticalSeparatorChar(_ row: Int, _ column: Int) -> Bool {
        guard row < height, column < width else { return false }
        let text = cell(row, column).text
        return text == "│" || text == "┃" || text == "║" || text == "|"
    }

    // MARK: Mutation

    /// Resizes the grid, reallocating its cell storage.
    mutating func resize(width: Int, height: Int) {
        self.width = width
        self.height = height
        cells = Array(repeating: Cell(), count: width * height)
    }
}
