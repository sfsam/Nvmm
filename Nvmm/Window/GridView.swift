//
//  Nvmm
//  GridView.swift
//
//  A Metal-backed view that renders a grid snapshot.
//
//  Each frame draws five passes in order: cell backgrounds, procedural cell
//  graphics (block and shade characters), glyphs, line decorations, and the
//  cursor. Rendering is independent of the view's size — too small crops the
//  output, too large pads it. A grid, a font, and a render context must all be
//  set before the first draw.
//
//  The view is also the `NSTextInputClient`. Keyboard events in a text-entry
//  mode are offered to Cocoa so dead keys, multi-scalar emoji, and IMEs work;
//  the marked-text state machine lives in `TextInputCoordinator`, and the
//  provisional preedit is drawn in-grid as a sixth pass overlaid on the cursor's
//  row. Preedit placement uses the window's editable-text geometry, fetched
//  asynchronously from Neovim and cached, so the synchronous text-input queries
//  never block; a generation counter discards geometry a later resize or focus
//  change has invalidated.
//

import AppKit
import Carbon.HIToolbox
import CoreText
import Metal
import QuartzCore
import simd

/// Rounds `value` up to the nearest multiple of `multiple`.
private func roundUp(_ value: CGFloat, toMultipleOf multiple: Int) -> CGFloat {
    let mult = CGFloat(multiple)
    return (value / mult).rounded(.up) * mult
}

/// The procedural cell-graphic kinds understood by the cell-graphic shader.
private enum CellGraphicKind: UInt32 {
    case fullBlock = 1
    case darkShade = 2
    case mediumShade = 3
    case lightShade = 4
    case diagonalUpperRightToLowerLeft = 5
    case diagonalUpperLeftToLowerRight = 6

    /// The kind a grapheme maps to, or nil if it is not a cell graphic.
    init?(grapheme: String) {
        switch grapheme {
        case "\u{2588}": self = .fullBlock       // █
        case "\u{2593}": self = .darkShade        // ▓
        case "\u{2592}": self = .mediumShade      // ▒
        case "\u{2591}": self = .lightShade       // ░
        case "\u{2571}": self = .diagonalUpperRightToLowerLeft // ╱
        case "\u{2572}": self = .diagonalUpperLeftToLowerRight // ╲
        default: return nil
        }
    }
}

final class GridView: NSView, CALayerDelegate, NSTextInputClient,
                      TextInputCoordinatorDelegate, NSUserInterfaceValidations {
    private var metalLayer: CAMetalLayer!

    private var renderContext: RenderContext?
    private var fontFamily: FontFamily?
    private var grid: Grid?

    // Cell metrics, in backing pixels unless noted.
    private var backingCellSize = NSSize(width: 1, height: 1)
    private var cellSizePixels = SIMD2<Float>(1, 1)
    private var baselineTranslate = SIMD2<Float>(0, 0)
    private var cursorLineThickness: UInt32 = 2

    // Line-decoration shapes derived from the font metrics.
    private var underline = line_metrics()
    private var underdouble = line_metrics()
    private var underdotted = line_metrics()
    private var underdashed = line_metrics()
    private var undercurl = line_metrics()
    private var overline = line_metrics()
    private var strikethrough = line_metrics()
    private var compositionUnderline = line_metrics()

    // A small ring of frame buffers keeps frames from stalling on the GPU.
    private let frameBuffers = [MetalFrameBuffer(), MetalFrameBuffer(),
                                MetalFrameBuffer()]
    private var frameIndex: UInt64 = 0

    // Cursor blink and activation state.
    private var cursorVisible = true
    private var blinkTimer: Timer?
    private var inactive = false

    private enum BlinkPhase { case off, on }

    // MARK: Input

    /// Sends a key-notation payload to Neovim (`nvim_input`).
    var sendInput: ((String) -> Void)?

    /// Sends a mouse event to Neovim (`nvim_input_mouse`).
    var sendMouse: ((_ button: String, _ action: String, _ modifiers: String,
                     _ row: Int, _ col: Int) -> Void)?

    /// Sends committed text too large or multiline for `nvim_input` as a paste.
    var sendPaste: ((String) -> Void)?

    /// Feeds a raw key sequence to Neovim (`nvim_feedkeys`), for the mode-aware
    /// copy/paste/cut menu actions.
    var sendFeedkeys: ((String) -> Void)?

    /// Fetches the current window's editable-text geometry for preedit layout.
    /// Async so it never blocks the main thread; the reply is generation-checked
    /// and cached (see `refreshCompositionGeometry`).
    var fetchCompositionGeometry: (() async -> CompositionGeometry?)?

    /// Fetches the current Visual-mode selection, for a Look Up gesture made
    /// inside one. Async, and its reply is checked against the token and grid
    /// tick that were current when the gesture happened.
    var fetchVisualSelection: (() async -> VisualSelection?)?

    /// Per-button drag state. A `nil` origin means the press began outside the
    /// grid, so its drag and release are ignored. `location` and `modifiers`
    /// hold the most recent drag so the drag timer can resend it.
    private struct MousePress {
        var origin: GridPoint?
        var isDragging = false
        var location = GridPoint(row: 0, column: 0)
        var modifiers = ""
    }
    private var mouseState: [MousePress] = [MousePress(), MousePress(), MousePress()]

    /// Resends the active drags at a fixed rate. A drag held past the grid edge
    /// keeps scrolling Neovim even while the pointer is stationary, so the drag
    /// must be resent when no mouse-moved events are arriving. Runs only while
    /// at least one button is dragging.
    private var dragTimer: DispatchSourceTimer?
    private var draggingButtons = 0
    private static let dragResendHz = 120

    /// Accumulated fractional trackpad scroll, in backing pixels, spent one
    /// whole cell at a time.
    private var scrollingDelta = SIMD2<Double>(0, 0)

    private var trackingArea: NSTrackingArea?

    // MARK: Composition

    /// The marked-text state machine. Created in `init`; `self` is its delegate.
    private var textInputCoordinator: TextInputCoordinator!

    /// One synthetic preedit cell: the cell to draw, its grid position, the UTF-16
    /// range of the source marked grapheme (for hit testing), and whether it is
    /// marked text (underlined) or a displaced buffer cell.
    private struct CompositionRenderCell {
        var cell: Cell
        var position: SIMD2<Int16>
        var utf16Range: NSRange
        var marked: Bool
    }

    /// Protects async geometry-request ordering: `generation` invalidates a reply
    /// whose request a later resize/focus change superseded.
    private struct CompositionRequestState {
        var pending = false
        var generation: UInt64 = 0
    }

    /// The client-side anchor for the active marked session and the commit bridge
    /// that carries a just-committed width across to the next preedit's anchor.
    private struct CompositionSessionState {
        var anchored = false
        var awaitingCommitRedraw = false
        var anchor = GridPoint(row: 0, column: 0)
        var pendingAnchorAdvance = 0
    }

    /// The cached synthetic cells for the current preedit, plus the row and the
    /// half-open clear range they occupy.
    private struct CompositionRenderState {
        var cells: [CompositionRenderCell] = []
        var clearStart = 0
        var clearEnd = 0
        var row = 0
        var valid = false
        var background = RGBColor()
    }

    private var compositionRequest = CompositionRequestState()
    private var compositionSession = CompositionSessionState()
    private var compositionRender = CompositionRenderState()
    private var compositionGeometry: CompositionGeometry?
    private var compositionWidthPolicy = CompositionWidthPolicy()

    /// Builds the text and anchor point for a Look Up gesture.
    private let lookupController = LookupController()

    // MARK: - Setup

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layerContentsPlacement = .topLeft
        // Force the backing layer so metalLayer is ready before any geometry or
        // configuration call touches it.
        _ = layer
        textInputCoordinator = TextInputCoordinator(delegate: self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.delegate = self
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.allowsNextDrawableTimeout = false
        layer.autoresizingMask = [.layerHeightSizable, .layerWidthSizable]
        layer.needsDisplayOnBoundsChange = true
        layer.presentsWithTransaction = true
        metalLayer = layer
        return layer
    }

    override var isFlipped: Bool { true }

    // MARK: - Configuration

    /// Sets the render context and binds the Metal layer to its device.
    func setRenderContext(_ context: RenderContext) {
        renderContext = context
        metalLayer.device = context.device
        needsDisplay = true
    }

    var renderContextValue: RenderContext? { renderContext }

    /// Sets the font and recomputes cell and line-decoration metrics.
    func setFont(_ font: FontFamily) {
        fontFamily = font

        let leading = font.leading.rounded(.down)
        let descent = font.descent.rounded(.down)
        let ascent = font.ascent.rounded(.down)
        let width = font.width.rounded(.down)

        // Cell metrics are in backing pixels. Quantize the cell to a whole
        // number of points so its point size is not fractional: otherwise a
        // grid with an odd cell count needs a fractional-point window size,
        // which AppKit rounds to a whole point, leaving the drawable a pixel
        // larger than the grid it holds — a thin strip of the clear color along
        // an edge. Rounding the cell up to a whole point keeps every window
        // size integral and the drawable exactly grid-sized. The extra pixels
        // fall below the descent as padding.
        let scale = max(1, Int(font.scaleFactor.rounded()))
        let cellHeight = roundUp(leading + descent + ascent, toMultipleOf: scale)
        let cellWidth = roundUp(width, toMultipleOf: scale)

        cellSizePixels = SIMD2<Float>(Float(cellWidth), Float(cellHeight))
        backingCellSize = convertSize(from: NSSize(width: cellWidth,
                                                   height: cellHeight))
        baselineTranslate = SIMD2<Float>(0, Float(ascent))

        let underlinePosition = font.underlinePosition
        let lineThickness = UInt16(floor(font.underlineThickness + 1.0))
        let scaleFactor = font.scaleFactor
        let underlineTranslate: Int16 = underlinePosition >= 0
            ? Int16(floor(underlinePosition + 0.5))
            : Int16(floor(underlinePosition - 0.5))

        strikethrough = line_metrics(ytranslate: Int16(ascent / 3), period: 0,
                                     thickness: lineThickness, style: 0)

        underline = line_metrics(ytranslate: underlineTranslate, period: 0,
                                 thickness: lineThickness, style: 0)

        // A preedit underline is heavier than a normal underline so the marked
        // text reads as provisional.
        compositionUnderline = underline
        compositionUnderline.thickness = max(underline.thickness * 2,
                                             UInt16((2 * scaleFactor).rounded(.up)))

        underdouble = underline
        underdouble.ytranslate -= Int16(lineThickness) * 2

        underdotted = underline
        underdotted.period = UInt16(max(4.0, floor(cellWidth / 3.0)))
        underdotted.thickness = max(lineThickness,
                                    UInt16((Double(underdotted.period) * 0.44).rounded(.up)))
        underdotted.style = 2

        underdashed = underline
        underdashed.period = UInt16(8 * scaleFactor)
        underdashed.style = 1

        undercurl = line_metrics(ytranslate: underlineTranslate, period: 0xFFFF,
                                 thickness: UInt16(4 * scaleFactor), style: 0)

        overline = line_metrics(ytranslate: Int16(ascent), period: 0,
                                thickness: lineThickness, style: 0)

        cursorLineThickness = UInt32(2 * scaleFactor)
        metalLayer.contentsScale = scaleFactor
        lookupController.setFontFamily(font)
        updateCompositionLayout()
        needsDisplay = true
    }

    var fontFamilyValue: FontFamily? { fontFamily }

    /// The size of a single-width cell in the view's coordinate space.
    var cellSize: NSSize { backingCellSize }

    /// The frame size needed to fit the current grid.
    var desiredFrameSize: NSSize {
        guard let grid else { return .zero }
        return NSSize(width: backingCellSize.width * CGFloat(grid.width),
                      height: backingCellSize.height * CGFloat(grid.height))
    }

    /// The largest grid that fits the current drawable size.
    var desiredGridSize: GridSize {
        let drawable = metalLayer.drawableSize
        return GridSize(width: Int(Float(drawable.width) / cellSizePixels.x),
                        height: Int(Float(drawable.height) / cellSizePixels.y))
    }

    // MARK: - Grid updates

    /// Publishes a new grid snapshot, redrawing and restarting the blink loop.
    func setGrid(_ newGrid: Grid) {
        let previousSize = grid?.size
        grid = newGrid
        cursorVisible = true
        // A new grid means any commit we were holding the final preedit frame
        // for has now landed.
        compositionSession.awaitingCommitRedraw = false

        let gridSizeChanged = previousSize != nil && previousSize != newGrid.size
        // A resize can reflow the buffer and move the cursor to a different
        // screen row while Cocoa keeps the same marked session alive. Across a
        // size change the newly published cursor is the authoritative location
        // of that insertion point.
        if gridSizeChanged, textInputCoordinator.isActive {
            let cursor = newGrid.cursor
            compositionSession.anchor = GridPoint(row: cursor.row,
                                                  column: cursor.column)
            compositionSession.pendingAnchorAdvance = 0
        }

        if textInputCoordinator.isActive, !newGrid.acceptsTextInput {
            textInputCoordinator.cancel(inputContext: inputContext)
            compositionStateDidChange()
        } else {
            if textInputCoordinator.isActive { compositionGeometry = nil }
            updateCompositionLayout()
            if textInputCoordinator.isActive { refreshCompositionGeometry() }
        }

        restartBlink()
        needsDisplay = true
    }

    var gridValue: Grid? { grid }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        metalLayer.drawableSize = convertToBacking(newSize)
        textInputGeometryDidChange()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        textInputGeometryDidChange()
    }

    /// Disables blinking and forces a block-outline cursor, as inactive windows
    /// do in the system terminal.
    func setInactive() {
        guard !inactive else { return }
        inactive = true
        // Losing focus suspends an IME session but cancels a dead-key one.
        textInputCoordinator.suspendOrCancel(inputContext: inputContext)
        blinkTimer?.invalidate()
        blinkTimer = nil
        cursorVisible = true
        needsDisplay = true
    }

    /// Restores the cursor style and blink loop from the current grid.
    func setActive() {
        guard inactive else { return }
        inactive = false
        textInputCoordinator.resume(inputContext: inputContext)
        restartBlink()
        needsDisplay = true
    }

    // MARK: - Cursor blink

    private func restartBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        cursorVisible = true

        guard !inactive, let grid, !grid.hideCursor else { return }
        let cursor = grid.cursor
        guard cursor.blinks, cursor.blinkon > 0, cursor.blinkoff > 0 else { return }
        scheduleBlink(afterMilliseconds: cursor.blinkwait, phase: .off)
    }

    private func scheduleBlink(afterMilliseconds ms: UInt16, phase: BlinkPhase) {
        blinkTimer = Timer.scheduledTimer(
            withTimeInterval: Double(ms) / 1000.0, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let grid = self.grid else { return }
                let cursor = grid.cursor
                switch phase {
                case .off:
                    self.cursorVisible = false
                    self.needsDisplay = true
                    self.scheduleBlink(afterMilliseconds: cursor.blinkoff, phase: .on)
                case .on:
                    if !grid.hideCursor { self.cursorVisible = true }
                    self.needsDisplay = true
                    self.scheduleBlink(afterMilliseconds: cursor.blinkon, phase: .off)
                }
            }
        }
    }

    // MARK: - Rendering

    func display(_ layer: CALayer) {
        guard let grid, let font = fontFamily, let context = renderContext,
              grid.width > 0, grid.height > 0 else {
            return
        }

        let index = Int(frameIndex % UInt64(frameBuffers.count))
        let frame = frameBuffers[index]

        // If the buffer is still on the GPU, drop this frame and try next loop.
        guard frame.tryLock() else {
            needsDisplay = true
            return
        }

        renderFrame(grid: grid, font: font, context: context, frame: frame,
                    index: index)
        frameIndex += 1
    }

    private func renderFrame(grid: Grid, font: FontFamily, context: RenderContext,
                             frame: MetalFrameBuffer, index: Int) {
        let glyphManager = context.glyphManager
        let cursor = grid.cursor
        let drawnShape = renderedCursorShape(grid: grid, cursor: cursor)
        let blockCursorApplies = drawnShape == .block

        let gridSize = grid.cellCount
        let stride = MemoryLayout<glyph_data>.stride
        let lineStride = MemoryLayout<line_data>.stride
        let cellGraphicStride = MemoryLayout<cell_graphic_data>.stride

        // Preedit cells are drawn on top of the grid: their glyphs and underlines
        // extend the glyph and line buffers, and their backgrounds (plus the
        // cleared range behind them) are full-block cell graphics.
        let compositionCellCount = compositionRender.valid
            ? compositionRender.cells.count : 0
        let compositionClearCount = compositionRender.valid
            ? max(0, compositionRender.clearEnd - compositionRender.clearStart) : 0
        let compositionBackgroundCount = compositionClearCount + compositionCellCount
        let renderCellCapacity = gridSize + compositionCellCount

        let uniformSize = MemoryLayout<uniform_data>.stride
        let backgroundSize = gridSize * MemoryLayout<UInt32>.stride
        let glyphSize = renderCellCapacity * stride
        let cellGraphicSize = (gridSize + compositionBackgroundCount) * cellGraphicStride
        let lineSize = renderCellCapacity * lineStride * 4

        // Pad for per-region alignment overallocation.
        let total = (256 * 5) + uniformSize + backgroundSize + glyphSize
                    + cellGraphicSize + lineSize
        frame.create(device: context.device, size: total)

        let uniformRegion = frame.allocate(uniformSize)
        let backgroundRegion = frame.allocate(backgroundSize)
        let glyphRegion = frame.allocate(glyphSize)
        let cellGraphicRegion = frame.allocate(cellGraphicSize)
        let lineRegion = frame.allocate(lineSize)

        let uniforms = uniformRegion.ptr.bindMemory(to: uniform_data.self,
                                                    capacity: 1)
        let backgrounds = backgroundRegion.ptr.bindMemory(to: UInt32.self,
                                                          capacity: gridSize)
        let glyphs = glyphRegion.ptr.bindMemory(to: glyph_data.self,
                                                capacity: renderCellCapacity)
        let cellGraphics = cellGraphicRegion.ptr.bindMemory(
            to: cell_graphic_data.self,
            capacity: gridSize + compositionBackgroundCount)
        let lines = lineRegion.ptr.bindMemory(to: line_data.self,
                                              capacity: renderCellCapacity * 4)

        let drawable = metalLayer.drawableSize
        let pixelSize = SIMD2<Float>(2, -2)
            / SIMD2<Float>(Float(drawable.width), Float(drawable.height))

        uniforms.pointee = uniform_data(
            pixel_size: pixelSize,
            cell_pixel_size: cellSizePixels,
            cell_size: cellSizePixels * pixelSize,
            baseline: baselineTranslate,
            cursor_position: SIMD2<Int16>(Int16(cursor.column), Int16(cursor.row)),
            cursor_color: cursor.background.rgb,
            cursor_line_width: cursorLineThickness,
            cursor_cell_width: UInt32(cursor.width),
            grid_width: UInt32(grid.width))

        var glyphCount = 0
        var cellGraphicCount = 0
        var lineCount = 0

        var undercurlNext = SIMD2<Int16>(-1, -1)
        var undercurlPosition: UInt16 = 0
        var underdottedNext = SIMD2<Int16>(-1, -1)
        var underdottedPosition: UInt16 = 0
        var underdashedNext = SIMD2<Int16>(-1, -1)
        var underdashedPosition: UInt16 = 0

        var backgroundIndex = 0
        for row in 0..<grid.height {
            for col in 0..<grid.width {
                var cell = grid.cell(row, col)
                if blockCursorApplies, row == cursor.row,
                   col >= cursor.column, col < cursor.column + cursor.width {
                    cell = cell.recolored(foreground: cursor.foreground,
                                          background: cursor.background,
                                          special: cursor.special)
                }

                let gridpos = SIMD2<Int16>(Int16(col), Int16(row))
                var foreground = cell.foreground
                let background = cell.background
                var lineColor = cell.special

                if cell.isDim {
                    foreground = dimColor(foreground, background)
                    if !cell.hasSpecialColor { lineColor = foreground }
                }

                backgrounds[backgroundIndex] = background.rgb
                backgroundIndex += 1

                if cell.hasLineEmphasis {
                    // Underline variants are mutually exclusive; undercurls win
                    // because they usually mark errors users want to see.
                    if cell.hasUndercurl {
                        undercurlPosition = undercurlNext == gridpos
                            ? undercurlPosition + 1 : 0
                        undercurlNext = SIMD2<Int16>(Int16(col + 1), Int16(row))
                        lines[lineCount] = makeLine(gridpos, lineColor, undercurl,
                                                    count: undercurlPosition)
                        lineCount += 1
                    } else if cell.hasUnderdouble {
                        lines[lineCount] = makeLine(gridpos, lineColor, underline)
                        lineCount += 1
                        lines[lineCount] = makeLine(gridpos, lineColor, underdouble)
                        lineCount += 1
                    } else if cell.hasUnderdotted {
                        underdottedPosition = underdottedNext == gridpos
                            ? underdottedPosition + 1 : 0
                        underdottedNext = SIMD2<Int16>(Int16(col + 1), Int16(row))
                        lines[lineCount] = makeLine(gridpos, lineColor, underdotted,
                                                    count: underdottedPosition)
                        lineCount += 1
                    } else if cell.hasUnderdashed {
                        underdashedPosition = underdashedNext == gridpos
                            ? underdashedPosition + 1 : 0
                        underdashedNext = SIMD2<Int16>(Int16(col + 1), Int16(row))
                        lines[lineCount] = makeLine(gridpos, lineColor, underdashed,
                                                    count: underdashedPosition)
                        lineCount += 1
                    } else if cell.hasUnderline {
                        lines[lineCount] = makeLine(gridpos, lineColor, underline)
                        lineCount += 1
                    }

                    if cell.hasOverline {
                        lines[lineCount] = makeLine(gridpos, lineColor, overline)
                        lineCount += 1
                    }

                    if cell.hasStrikethrough {
                        lines[lineCount] = makeLine(gridpos, lineColor, strikethrough)
                        lineCount += 1
                    }
                }

                if !cell.isEmpty {
                    if let kind = CellGraphicKind(grapheme: cell.text) {
                        cellGraphics[cellGraphicCount] = cell_graphic_data(
                            grid_position: gridpos,
                            cell_width: UInt32(cell.width),
                            color: foreground.opaque,
                            background_color: background.opaque,
                            kind: kind.rawValue)
                        cellGraphicCount += 1
                        continue
                    }

                    let glyph = glyphManager.glyph(
                        family: font, cell: cell,
                        background: background, foreground: foreground)
                    glyphs[glyphCount] = glyph_data(
                        grid_position: gridpos,
                        cell_width: UInt32(cell.width), rect: glyph)
                    glyphCount += 1
                }
            }
        }

        let gridGlyphCount = glyphCount
        let gridCellGraphicCount = cellGraphicCount
        let gridLineCount = lineCount

        if compositionRender.valid {
            appendComposition(glyphs: glyphs, glyphCount: &glyphCount,
                              cellGraphics: cellGraphics,
                              cellGraphicCount: &cellGraphicCount,
                              lines: lines, lineCount: &lineCount,
                              glyphManager: glyphManager, font: font)
        }

        frame.didModify(from: 0, length: cellGraphicRegion.offset
                        + cellGraphicCount * cellGraphicStride)
        if lineCount > 0 {
            frame.didModify(from: lineRegion.offset,
                            length: lineCount * lineStride)
        }

        guard let metalDrawable = metalLayer.nextDrawable(),
              let metalBuffer = frame.metalBuffer else {
            frame.unlock()
            return
        }

        encode(context: context, drawable: metalDrawable, buffer: metalBuffer,
               frame: frame, index: index, gridSize: gridSize,
               uniformOffset: uniformRegion.offset,
               backgroundOffset: backgroundRegion.offset,
               glyphOffset: glyphRegion.offset, gridGlyphCount: gridGlyphCount,
               compositionGlyphCount: glyphCount - gridGlyphCount,
               cellGraphicOffset: cellGraphicRegion.offset,
               gridCellGraphicCount: gridCellGraphicCount,
               compositionCellGraphicCount: cellGraphicCount - gridCellGraphicCount,
               lineOffset: lineRegion.offset, gridLineCount: gridLineCount,
               compositionLineCount: lineCount - gridLineCount,
               cursorShape: drawnShape,
               clearColor: clearColor(for: grid.defaultBackground))
    }

    /// Appends the preedit's synthetic cells after the grid's: full-block cell
    /// graphics for the cleared range and each cell's background, a glyph per
    /// non-blank cell, and a heavier accent underline under each marked cell —
    /// dimmed outside the active clause. Drawn after the grid so they layer on
    /// top.
    private func appendComposition(glyphs: UnsafeMutablePointer<glyph_data>,
                                   glyphCount: inout Int,
                                   cellGraphics: UnsafeMutablePointer<cell_graphic_data>,
                                   cellGraphicCount: inout Int,
                                   lines: UnsafeMutablePointer<line_data>,
                                   lineCount: inout Int,
                                   glyphManager: GlyphManager, font: FontFamily) {
        let accent = compositionAccentColor()
        let activeClause = textInputCoordinator.selectedRange()
        let hasActiveClause = activeClause.location != NSNotFound &&
                              activeClause.length > 0
        let row = Int16(compositionRender.row)

        let clear = compositionRender.background.opaque
        for col in compositionRender.clearStart..<compositionRender.clearEnd {
            cellGraphics[cellGraphicCount] = cell_graphic_data(
                grid_position: SIMD2<Int16>(Int16(col), row), cell_width: 1,
                color: clear, background_color: clear,
                kind: CellGraphicKind.fullBlock.rawValue)
            cellGraphicCount += 1
        }

        for entry in compositionRender.cells {
            let cell = entry.cell
            let background = cell.background.opaque
            cellGraphics[cellGraphicCount] = cell_graphic_data(
                grid_position: entry.position, cell_width: UInt32(cell.width),
                color: background, background_color: background,
                kind: CellGraphicKind.fullBlock.rawValue)
            cellGraphicCount += 1

            if !cell.isEmpty {
                let glyph = glyphManager.glyph(family: font, cell: cell,
                                               background: cell.background,
                                               foreground: cell.foreground)
                glyphs[glyphCount] = glyph_data(grid_position: entry.position,
                                                cell_width: UInt32(cell.width),
                                                rect: glyph)
                glyphCount += 1
            }

            if entry.marked {
                let active = !hasActiveClause ||
                    NSIntersectionRange(entry.utf16Range, activeClause).length > 0
                let opacity: UInt8 = active ? 255 : 102 // 40% for inactive clauses
                lines[lineCount] = makeLine(entry.position, accent,
                                            compositionUnderline, opacity: opacity)
                lineCount += 1
                if cell.width == 2 {
                    let second = SIMD2<Int16>(entry.position.x + 1, entry.position.y)
                    lines[lineCount] = makeLine(second, accent, compositionUnderline,
                                                count: 1, opacity: opacity)
                    lineCount += 1
                }
            }
        }
    }

    /// The control-accent color in sRGB, used for the preedit underline.
    private func compositionAccentColor() -> RGBColor {
        let color = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        guard let color else { return RGBColor(red: 0, green: 122, blue: 255) }
        return RGBColor(red: UInt8((color.redComponent * 255).rounded()),
                        green: UInt8((color.greenComponent * 255).rounded()),
                        blue: UInt8((color.blueComponent * 255).rounded()))
    }

    /// The render pass clear color for the default background.
    ///
    /// Any pixel the grid does not cover — the sub-cell strip a fractional cell
    /// size can leave along an edge — takes this color, so it matches the text
    /// area instead of standing out against it.
    ///
    /// The drawable's pixel format is sRGB, and Metal applies the sRGB transfer
    /// function when it writes the clear value. The color therefore has to be
    /// given in linear space, which is also the space the shaders work in after
    /// unpacking their sRGB byte colors.
    private func clearColor(for background: RGBColor) -> MTLClearColor {
        func linear(_ component: UInt8) -> Double {
            let value = Double(component) / 255
            return value <= 0.04045 ? value / 12.92
                                    : pow((value + 0.055) / 1.055, 2.4)
        }
        return MTLClearColor(red: linear(background.red),
                             green: linear(background.green),
                             blue: linear(background.blue), alpha: 1)
    }

    private func encode(context: RenderContext, drawable: CAMetalDrawable,
                        buffer: MTLBuffer, frame: MetalFrameBuffer, index: Int,
                        gridSize: Int, uniformOffset: Int, backgroundOffset: Int,
                        glyphOffset: Int, gridGlyphCount: Int,
                        compositionGlyphCount: Int,
                        cellGraphicOffset: Int, gridCellGraphicCount: Int,
                        compositionCellGraphicCount: Int,
                        lineOffset: Int, gridLineCount: Int,
                        compositionLineCount: Int,
                        cursorShape: CursorShape?,
                        clearColor: MTLClearColor) {
        let glyphStride = MemoryLayout<glyph_data>.stride
        let lineStride = MemoryLayout<line_data>.stride
        let cellGraphicStride = MemoryLayout<cell_graphic_data>.stride

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].clearColor = clearColor
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store

        let commandBuffer = context.commandQueue.makeCommandBuffer()!
        let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: descriptor)!

        encoder.setRenderPipelineState(context.backgroundPipeline)
        encoder.setVertexBuffer(buffer, offset: uniformOffset, index: 0)
        encoder.setVertexBuffer(buffer, offset: backgroundOffset, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                               vertexCount: 4, instanceCount: gridSize)

        if gridCellGraphicCount > 0 {
            encoder.setRenderPipelineState(context.cellGraphicPipeline)
            encoder.setVertexBufferOffset(cellGraphicOffset, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: 4, instanceCount: gridCellGraphicCount)
        }

        if gridGlyphCount > 0 {
            encoder.setRenderPipelineState(context.glyphPipeline)
            encoder.setVertexBufferOffset(glyphOffset, index: 1)
            encoder.setFragmentTexture(context.glyphManager.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: 4, instanceCount: gridGlyphCount)
        }

        if gridLineCount > 0 {
            encoder.setRenderPipelineState(context.linePipeline)
            encoder.setVertexBufferOffset(lineOffset, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: 4, instanceCount: gridLineCount)
        }

        // Preedit passes reuse the same pipelines, drawn after the grid so the
        // marked text and its cleared background land on top.
        if compositionCellGraphicCount > 0 {
            encoder.setRenderPipelineState(context.cellGraphicPipeline)
            encoder.setVertexBufferOffset(
                cellGraphicOffset + gridCellGraphicCount * cellGraphicStride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: 4,
                                   instanceCount: compositionCellGraphicCount)
        }

        if compositionGlyphCount > 0 {
            encoder.setRenderPipelineState(context.glyphPipeline)
            encoder.setVertexBufferOffset(
                glyphOffset + gridGlyphCount * glyphStride, index: 1)
            encoder.setFragmentTexture(context.glyphManager.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: 4, instanceCount: compositionGlyphCount)
        }

        if compositionLineCount > 0 {
            encoder.setRenderPipelineState(context.linePipeline)
            encoder.setVertexBufferOffset(
                lineOffset + gridLineCount * lineStride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: 4, instanceCount: compositionLineCount)
        }

        switch cursorShape {
        case .vertical:
            encoder.setRenderPipelineState(context.cursorPipeline)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: 4, instanceCount: 1, baseInstance: 0)
        case .horizontal:
            encoder.setRenderPipelineState(context.cursorPipeline)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: 4, instanceCount: 1, baseInstance: 1)
        case .blockOutline:
            encoder.setRenderPipelineState(context.cursorPipeline)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: 4, instanceCount: 4, baseInstance: 0)
        case .block, .none:
            break // Block cursors are drawn by recoloring the grid.
        }

        encoder.endEncoding()
        commandBuffer.addCompletedHandler { _ in
            frame.unlock()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()
        drawable.present()

        context.glyphManager.evict()
    }

    /// The cursor shape to draw this frame, or nil to draw no cursor. Inactive
    /// views always outline; a hidden or blinked-off cursor, or a visible preedit
    /// covering the insertion point, draws nothing.
    private func renderedCursorShape(grid: Grid, cursor: Cursor) -> CursorShape? {
        if grid.hideCursor || !cursorVisible { return nil }
        if shouldSuppressNvimCursorForComposition() { return nil }
        if inactive { return .blockOutline }
        return cursor.shape
    }

    /// True while a visible preedit should hide Neovim's own cursor, or while the
    /// final preedit frame is held until the committing redraw lands.
    private func shouldSuppressNvimCursorForComposition() -> Bool {
        textInputCoordinator.suppressesNvimCursor ||
            compositionSession.awaitingCommitRedraw
    }

    private func makeLine(_ position: SIMD2<Int16>, _ color: RGBColor,
                          _ metrics: line_metrics, count: UInt16 = 0,
                          opacity: UInt8 = 255) -> line_data {
        let packed = (color.rgb & 0x00FF_FFFF) | (UInt32(opacity) << 24)
        return line_data(grid_position: position, color: packed,
                         ytranslate: metrics.ytranslate, period: metrics.period,
                         thickness: metrics.thickness, count: count,
                         style: metrics.style)
    }

    private func dimColor(_ foreground: RGBColor, _ background: RGBColor) -> RGBColor {
        RGBColor(
            red: UInt8((Int(foreground.red) + Int(background.red)) / 2),
            green: UInt8((Int(foreground.green) + Int(background.green)) / 2),
            blue: UInt8((Int(foreground.blue) + Int(background.blue)) / 2))
    }

    private func convertSize(from backing: NSSize) -> NSSize {
        convertFromBacking(backing)
    }

    // MARK: - Geometry

    /// The grid cell under a window-space point. May fall outside the grid.
    private func cellLocation(_ windowPoint: NSPoint) -> GridPoint {
        let viewPoint = convert(windowPoint, from: nil)
        return GridPoint(row: Int(floor(viewPoint.y / backingCellSize.height)),
                         column: Int(floor(viewPoint.x / backingCellSize.width)))
    }

    private func pointInGrid(_ point: GridPoint, _ size: GridSize) -> Bool {
        point.row >= 0 && point.row < size.height &&
            point.column >= 0 && point.column < size.width
    }

    /// Clamps a point into the grid, or nil if the grid is empty.
    private func clampToGrid(_ point: GridPoint, _ size: GridSize) -> GridPoint? {
        guard size.width > 0, size.height > 0 else { return nil }
        return GridPoint(row: min(max(point.row, 0), size.height - 1),
                         column: min(max(point.column, 0), size.width - 1))
    }

    // MARK: - First responder

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Copy / paste menu actions

    // Neovim's current mode, from the latest grid snapshot. The mode drives the
    // clipboard actions and their menu-item enablement; it is already carried on
    // every flush for the cursor shape, so no separate query is needed.
    private var currentMode: UIMode { grid?.modeState.semantic ?? .normal }

    // These route through the `+` register (via the clipboard provider) so the
    // Vim register type survives a copy-then-paste. Raw control bytes: CTRL-C
    // `\u{03}`, CTRL-G `\u{07}`, CTRL-O `\u{0f}`, CTRL-R `\u{12}`, CTRL-W
    // `\u{17}`.

    @objc func copy(_ sender: Any?) {
        switch currentMode {
        case .visual: sendFeedkeys?("\"+y")
        case .select: sendFeedkeys?("\u{0f}\"+ygv\u{07}")
        default: NSSound.beep()
        }
    }

    @objc func cut(_ sender: Any?) {
        switch currentMode {
        case .visual: sendFeedkeys?("\"+x")
        case .select: sendFeedkeys?("\u{0f}\"+x")
        default: NSSound.beep()
        }
    }

    @objc func paste(_ sender: Any?) {
        switch Clipboard.contentForPaste() {
        case .none:
            NSSound.beep()
        case .plainText(let text):
            // Text from another app has no register type; paste it directly.
            sendPaste?(text)
        case .vimRegister:
            // Read the `+` register so its register type is preserved.
            switch currentMode {
            case .normal: sendFeedkeys?("\"+gP")
            case .visual: sendFeedkeys?("\"+P")
            case .select: sendFeedkeys?("\u{0f}\"+P")
            case .insert, .replace, .virtualReplace: sendFeedkeys?("\u{12}\u{0f}+")
            case .commandLine: sendFeedkeys?("\u{12}+")
            case .terminal: sendFeedkeys?("\u{17}\"+")
            default: sendFeedkeys?("\u{03}\"+gP")  // operator-pending, etc.
            }
        }
    }

    override func selectAll(_ sender: Any?) {
        switch currentMode {
        case .normal: sendFeedkeys?("ggVG")
        case .visual, .commandLine: sendFeedkeys?("\u{03}ggVG")
        case .insert, .replace, .virtualReplace:
            sendFeedkeys?("\u{0f}gg\u{0f}VG")
        case .select: sendFeedkeys?("\u{03}gggH\u{0f}G")
        default: NSSound.beep()
        }
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)):
            // Copy and cut only act on a selection.
            return currentMode == .visual || currentMode == .select
        case #selector(paste(_:)):
            return Clipboard.contentForPaste() != .none
        default:
            return true
        }
    }

    // MARK: - Key input

    override func keyDown(with event: NSEvent) {
        handleKeyDown(event, keyEvent: makeKeyboardEvent(event))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let keyEvent = makeKeyboardEvent(event)
        let menuOwnsEvent = Self.menuContainsKeyEquivalent(NSApp.mainMenu, event)
        // A menu is about to run its action, so commit any preedit first rather
        // than leaving it stranded.
        if event.type == .keyDown, menuOwnsEvent, textInputCoordinator.isActive {
            textInputCoordinator.commitForExternalAction(inputContext: inputContext)
        }
        let action = arbitrateKeyEquivalent(
            isKeyDown: event.type == .keyDown,
            hasEnabledMenuEquivalent: menuOwnsEvent, event: keyEvent)
        if action == .forwardToKeyDown {
            handleKeyDown(event, keyEvent: keyEvent)
            return true
        }
        return false
    }

    private func handleKeyDown(_ event: NSEvent, keyEvent: KeyboardEvent) {
        NSCursor.setHiddenUntilMouseMoves(true)
        let wasComposing = textInputCoordinator.isActive
        // Dead-key Delete must cancel before Cocoa sees it: keyboard-layout
        // input otherwise commits the standalone accent. IME Delete stays
        // Cocoa-owned so it can edit the provisional string.
        if wasComposing, textInputCoordinator.shouldCancelDeleteBeforeCocoa(),
           keyEvent.named == .backspace || keyEvent.named == .deleteForward {
            textInputCoordinator.cancel(inputContext: inputContext)
            compositionStateDidChange()
            return
        }

        let mode = grid?.textEntryMode ?? .directNeovim
        if shouldOfferToCocoa(mode: mode, compositionActive: wasComposing,
                              event: keyEvent) {
            textInputCoordinator.beginInputContextEvent()
            // handleEvent may synchronously call back into this view's
            // NSTextInputClient methods before it returns.
            let handled = inputContext?.handleEvent(event) ?? false
            let deleteKey = keyEvent.named == .backspace ||
                            keyEvent.named == .deleteForward
            let result = textInputCoordinator.finishInputContextEvent(
                handled: handled, escape: keyEvent.named == .escape,
                deleteKey: deleteKey)
            switch result {
            case .consume:
                return
            case .routeToNeovim:
                break
            case .commitAndConsume:
                textInputCoordinator.commit()
                compositionStateDidChange()
                return
            case .commitAndRouteToNeovim:
                textInputCoordinator.commit()
                compositionStateDidChange()
            case .cancelAndConsume:
                textInputCoordinator.cancel(inputContext: inputContext)
                compositionStateDidChange()
                return
            }
        }

        let input = routeKeyEvent(keyEvent)
        if !input.isEmpty { sendInput?(input) }
    }

    /// Builds a normalized keyboard event from an `NSEvent`.
    private func makeKeyboardEvent(_ event: NSEvent) -> KeyboardEvent {
        let flags = event.modifierFlags
        let resolved = event.charactersIgnoringModifiers ?? ""

        // Shift folded into a symbol (for example `^` from Shift-6) carries no
        // letter, so re-encoding S- would change the key. Detect that here.
        var shiftIsEmbodied = false
        if flags.contains(.shift), !resolved.isEmpty {
            shiftIsEmbodied = resolved.rangeOfCharacter(from: .letters) == nil
        }

        let needsUnmodified =
            flags.contains(.command) || flags.contains(.control)

        var result = KeyboardEvent(
            keyCode: event.keyCode,
            characters: event.characters ?? "",
            keyCharacters: needsUnmodified
                ? Self.unmodifiedKeyCharacters(event.keyCode) : "",
            resolvedKeyCharacters: resolved,
            modifierKeys: KeyModifiers(
                shift: flags.contains(.shift),
                control: flags.contains(.control),
                option: flags.contains(.option),
                command: flags.contains(.command)),
            named: Self.namedKey(event.keyCode),
            physical: Self.physicalKey(event.keyCode),
            capsLock: flags.contains(.capsLock),
            shiftIsEmbodied: shiftIsEmbodied,
            isRepeat: event.isARepeat)
        setOptionSides(&result, rawFlags: UInt(flags.rawValue))
        return result
    }

    /// The unshifted, layout-resolved characters for a key code, obtained from
    /// a synthetic modifier-free event. Only the Command/Control routing path
    /// needs it, so it is computed lazily.
    private static func unmodifiedKeyCharacters(_ keyCode: UInt16) -> String {
        guard let cgEvent = CGEvent(keyboardEventSource: nil,
                                    virtualKey: keyCode, keyDown: true) else {
            return ""
        }
        cgEvent.flags = []
        guard let event = NSEvent(cgEvent: cgEvent) else { return "" }
        return (event.charactersIgnoringModifiers ?? "").lowercased()
    }

    private static func namedKey(_ code: UInt16) -> NamedKey? {
        switch Int(code) {
        case kVK_Return:        return .carriageReturn
        case kVK_Tab:           return .tab
        case kVK_Space:         return .space
        case kVK_Delete:        return .backspace
        case kVK_ForwardDelete: return .deleteForward
        case kVK_Escape:        return .escape
        // macOS reports Insert-labelled external keys as kVK_Help too, so there
        // is no distinct Insert mapping available here.
        case kVK_Help:          return .help
        case kVK_Home:          return .home
        case kVK_End:           return .end
        case kVK_PageUp:        return .pageUp
        case kVK_PageDown:      return .pageDown
        case kVK_LeftArrow:     return .left
        case kVK_RightArrow:    return .right
        case kVK_UpArrow:       return .up
        case kVK_DownArrow:     return .down
        case kVK_VolumeUp:      return .volumeUp
        case kVK_VolumeDown:    return .volumeDown
        case kVK_Mute:          return .mute
        case kVK_F1:  return .f1;  case kVK_F2:  return .f2;  case kVK_F3:  return .f3
        case kVK_F4:  return .f4;  case kVK_F5:  return .f5;  case kVK_F6:  return .f6
        case kVK_F7:  return .f7;  case kVK_F8:  return .f8;  case kVK_F9:  return .f9
        case kVK_F10: return .f10; case kVK_F11: return .f11; case kVK_F12: return .f12
        case kVK_F13: return .f13; case kVK_F14: return .f14; case kVK_F15: return .f15
        case kVK_F16: return .f16; case kVK_F17: return .f17; case kVK_F18: return .f18
        case kVK_F19: return .f19; case kVK_F20: return .f20
        default: return nil
        }
    }

    private static func physicalKey(_ code: UInt16) -> PhysicalKey {
        switch Int(code) {
        case kVK_ANSI_2:      return .digit2
        case kVK_ANSI_6:      return .digit6
        case kVK_ANSI_Minus:  return .minus
        case kVK_ANSI_Period: return .period
        default:              return .other
        }
    }

    /// Whether the main menu has an enabled item whose key equivalent matches
    /// the event, so AppKit should own it rather than routing it to Neovim.
    private static func menuContainsKeyEquivalent(_ menu: NSMenu?,
                                                  _ event: NSEvent) -> Bool {
        guard let menu else { return false }
        let mask: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let eventFlags = event.modifierFlags.intersection(mask)
        guard let characters = event.charactersIgnoringModifiers,
              !characters.isEmpty else { return false }

        for item in menu.items {
            if let submenu = item.submenu,
               menuContainsKeyEquivalent(submenu, event) {
                return true
            }
            guard item.isEnabled, item.action != nil,
                  !item.keyEquivalent.isEmpty else { continue }
            if item.keyEquivalentModifierMask.intersection(mask) != eventFlags {
                continue
            }
            if item.keyEquivalent.caseInsensitiveCompare(characters) == .orderedSame {
                return true
            }
        }
        return false
    }

    // MARK: - Mouse input

    private static let mouseButtonNames = ["left", "right", "middle"]

    /// Vim-notation modifier prefix for a mouse event, e.g. `S-C-`.
    private func mouseModifiers(_ flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.shift)   { result += "S-" }
        if flags.contains(.command) { result += "D-" }
        if flags.contains(.control) { result += "C-" }
        if flags.contains(.option)  { result += "M-" }
        return result
    }

    private func mousePress(_ event: NSEvent, button: Int) {
        let location = cellLocation(event.locationInWindow)
        guard let grid, pointInGrid(location, grid.size) else {
            mouseState[button] = MousePress(origin: nil)
            return
        }
        mouseState[button] = MousePress(origin: location)
        sendMouse?(Self.mouseButtonNames[button], "press",
                   mouseModifiers(event.modifierFlags),
                   location.row, location.column)
    }

    private func mouseDrag(_ event: NSEvent, button: Int) {
        guard mouseState[button].origin != nil else { return }
        // Unclamped: a drag past an edge yields an out-of-grid cell, which
        // Neovim reads as a request to scroll the window in that direction.
        mouseState[button].location = cellLocation(event.locationInWindow)
        mouseState[button].modifiers = mouseModifiers(event.modifierFlags)
        if !mouseState[button].isDragging {
            mouseState[button].isDragging = true
            draggingButtons += 1
            startDragTimer()
        }
        sendDrag(button: button)
    }

    private func mouseRelease(_ event: NSEvent, button: Int) {
        guard mouseState[button].origin != nil else { return }
        let wasDragging = mouseState[button].isDragging
        mouseState[button] = MousePress(origin: nil)
        if wasDragging {
            draggingButtons -= 1
            if draggingButtons == 0 { stopDragTimer() }
        }
        guard let grid,
              let location = clampToGrid(cellLocation(event.locationInWindow),
                                         grid.size) else { return }
        sendMouse?(Self.mouseButtonNames[button], "release",
                   mouseModifiers(event.modifierFlags),
                   location.row, location.column)
    }

    /// Sends a button's most recent drag, used both by the live drag handler and
    /// the resend timer.
    private func sendDrag(button: Int) {
        let state = mouseState[button]
        sendMouse?(Self.mouseButtonNames[button], "drag", state.modifiers,
                   state.location.row, state.location.column)
    }

    /// Starts the drag-resend timer if it is not already running.
    private func startDragTimer() {
        guard dragTimer == nil else { return }
        let interval = DispatchTimeInterval.nanoseconds(1_000_000_000 / Self.dragResendHz)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval,
                       leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for button in self.mouseState.indices
                where self.mouseState[button].isDragging {
                    self.sendDrag(button: button)
                }
            }
        }
        timer.resume()
        dragTimer = timer
    }

    private func stopDragTimer() {
        dragTimer?.cancel()
        dragTimer = nil
    }

    override func mouseDown(with event: NSEvent) { mousePress(event, button: 0) }
    override func mouseDragged(with event: NSEvent) { mouseDrag(event, button: 0) }
    override func mouseUp(with event: NSEvent) { mouseRelease(event, button: 0) }

    override func rightMouseDown(with event: NSEvent) { mousePress(event, button: 1) }
    override func rightMouseDragged(with event: NSEvent) { mouseDrag(event, button: 1) }
    override func rightMouseUp(with event: NSEvent) { mouseRelease(event, button: 1) }

    override func otherMouseDown(with event: NSEvent) { mousePress(event, button: 2) }
    override func otherMouseDragged(with event: NSEvent) { mouseDrag(event, button: 2) }
    override func otherMouseUp(with event: NSEvent) { mouseRelease(event, button: 2) }

    override func scrollWheel(with event: NSEvent) {
        guard let grid else { return }
        let location = cellLocation(event.locationInWindow)
        guard pointInGrid(location, grid.size) else { return }

        var flags = event.modifierFlags
        var deltaX = event.scrollingDeltaX
        var deltaY = event.scrollingDeltaY

        if event.hasPreciseScrollingDeltas {
            let cell = backingCellSize
            if event.phase == .began { scrollingDelta = SIMD2<Double>(0, 0) }

            scrollingDelta.y += deltaY
            deltaY = floor(scrollingDelta.y / cell.height)
            scrollingDelta.y -= deltaY * cell.height

            scrollingDelta.x += deltaX
            deltaX = floor(scrollingDelta.x / cell.width)
            scrollingDelta.x -= deltaX * cell.width
        } else {
            // A real scroll wheel: Shift flips the axis, so ignore it, and clamp
            // each notch to a single line.
            flags.remove(.shift)
            deltaY = deltaY > 0 ? 1 : (deltaY < 0 ? -1 : 0)
            deltaX = deltaX > 0 ? 1 : (deltaX < 0 ? -1 : 0)
        }

        let modifiers = mouseModifiers(flags)
        emitScroll(count: Int(abs(deltaY)),
                   direction: deltaY > 0 ? "up" : "down",
                   modifiers: modifiers, location: location, active: deltaY != 0)
        emitScroll(count: Int(abs(deltaX)),
                   direction: deltaX > 0 ? "left" : "right",
                   modifiers: modifiers, location: location, active: deltaX != 0)
    }

    private func emitScroll(count: Int, direction: String, modifiers: String,
                            location: GridPoint, active: Bool) {
        guard active else { return }
        for _ in 0..<count {
            sendMouse?("wheel", direction, modifiers, location.row, location.column)
        }
    }

    // MARK: - Mouse cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                      .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateMouseCursor(event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    /// Sets a context-sensitive mouse cursor: a resize cursor over a window
    /// separator or status line, an arrow over the tab line, and an I-beam
    /// where the editor accepts text input.
    private func updateMouseCursor(_ windowPoint: NSPoint) {
        guard let grid else { return }
        guard Settings.contextSensitiveCursor else {
            NSCursor.arrow.set()
            return
        }
        let size = grid.size
        let cell = cellLocation(windowPoint)
        guard pointInGrid(cell, size) else {
            NSCursor.arrow.set()
            return
        }

        let group = grid.pointerStyle(cell.row, cell.column)
        // The last row is always the command line — never show resize there.
        let isResizable = cell.row < size.height - 1
        let isTabline = cell.row == 0 && group.contains(.tabline)
        let isSeparator = grid.isVerticalSeparatorChar(cell.row, cell.column) &&
            group.contains(.separator)

        if isTabline {
            NSCursor.arrow.set()
        } else if isResizable && isSeparator {
            NSCursor.resizeLeftRight.set()
        } else if isResizable && group.contains(.statusLine) {
            NSCursor.resizeUpDown.set()
        } else if grid.acceptsTextInput {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Text input (NSTextInputClient)

    func insertText(_ string: Any, replacementRange: NSRange) {
        textInputCoordinator.insertText(string, replacementRange: replacementRange)
        compositionStateDidChange()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange,
                       replacementRange: NSRange) {
        textInputCoordinator.setMarkedText(string, selectedRange: selectedRange,
                                           replacementRange: replacementRange)
        compositionStateDidChange()
    }

    func unmarkText() {
        textInputCoordinator.unmarkText()
        compositionStateDidChange()
    }

    func hasMarkedText() -> Bool { textInputCoordinator.hasMarkedText() }
    func markedRange() -> NSRange { textInputCoordinator.markedRange() }
    func selectedRange() -> NSRange { textInputCoordinator.selectedRange() }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? {
        textInputCoordinator.attributedSubstring(forProposedRange: range,
                                                  actualRange: actualRange)
    }

    override func doCommand(by selector: Selector) {
        textInputCoordinator.doCommandBySelector(selector, inputContext: inputContext)
    }

    func characterIndex(for point: NSPoint) -> Int {
        guard compositionRender.valid, let window else { return NSNotFound }
        // Map a screen point to a UTF-16 index in the marked string. The render
        // cache holds each visible marked grapheme's cell span and UTF-16 range,
        // so double-width and surrogate-pair graphemes are never split.
        let windowPoint = window.convertPoint(fromScreen: point)
        let viewPoint = convert(windowPoint, from: nil)
        let col = Int(floor(viewPoint.x / backingCellSize.width))
        let row = Int(floor(viewPoint.y / backingCellSize.height))
        for entry in compositionRender.cells {
            guard entry.marked, entry.utf16Range.location != NSNotFound,
                  row == Int(entry.position.y), col >= Int(entry.position.x),
                  col < Int(entry.position.x) + entry.cell.width else { continue }
            let midpoint = (Double(entry.position.x) + Double(entry.cell.width) * 0.5)
                * Double(backingCellSize.width)
            return Double(viewPoint.x) < midpoint
                ? entry.utf16Range.location : NSMaxRange(entry.utf16Range)
        }
        return NSNotFound
    }

    func firstRect(forCharacterRange range: NSRange,
                   actualRange: NSRangePointer?) -> NSRect {
        // Candidate windows follow Cocoa UTF-16 ranges, but the visible preedit
        // is synthetic grid cells. Prefer the rendered marked-cell mapping and
        // fall back to the Neovim cursor when the range is not visible.
        if compositionRender.valid, let window, range.location != NSNotFound {
            for entry in compositionRender.cells {
                guard entry.marked,
                      entry.utf16Range.location != NSNotFound else { continue }
                let insertionAtEnd = range.length == 0 &&
                    range.location == NSMaxRange(entry.utf16Range)
                if !insertionAtEnd,
                   !NSLocationInRange(range.location, entry.utf16Range) { continue }
                var x = Double(entry.position.x) * Double(backingCellSize.width)
                if insertionAtEnd {
                    x += Double(entry.cell.width) * Double(backingCellSize.width)
                }
                let viewRect = NSRect(
                    x: x, y: Double(entry.position.y) * Double(backingCellSize.height),
                    width: insertionAtEnd
                        ? 1 : Double(entry.cell.width) * Double(backingCellSize.width),
                    height: Double(backingCellSize.height))
                actualRange?.pointee = range.length > 0
                    ? entry.utf16Range : NSRange(location: range.location, length: 0)
                return window.convertToScreen(convert(viewRect, to: nil))
            }
        }
        actualRange?.pointee = NSRange(location: 0, length: 0)
        guard let window else { return .zero }
        guard let grid, backingCellSize.width > 0, backingCellSize.height > 0,
              grid.width > 0, grid.height > 0 else {
            return window.convertToScreen(convert(NSRect.zero, to: nil))
        }
        let cursor = grid.cursor
        let col = min(cursor.column, grid.width - 1)
        let row = min(cursor.row, grid.height - 1)
        let viewRect = NSRect(
            x: Double(col) * Double(backingCellSize.width),
            y: Double(row) * Double(backingCellSize.height),
            width: Double(max(1, cursor.width)) * Double(backingCellSize.width),
            height: Double(backingCellSize.height))
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    // MARK: - Composition support

    func commitCompositionString(_ text: String) {
        // Cocoa can commit the current dead-key composition and start a new
        // marked session in the same handleEvent transaction. Neovim cannot
        // redraw its cursor between those synchronous callbacks, so advance the
        // client-side anchor by the committed display width to avoid anchoring
        // the new preedit one transaction behind.
        if compositionSession.anchored, !text.isEmpty {
            compositionSession.awaitingCommitRedraw = true
            refreshCompositionWidthPolicy()
            let widthPolicy = compositionWidthPolicy
            var committedCells = 0
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                     options: .byComposedCharacterSequences) {
                substring, _, _, _ in
                if let substring {
                    committedCells += compositionGraphemeWidth(substring, widthPolicy)
                }
            }
            let rightToLeft = compositionGeometry?.rightToLeft ?? false
            compositionSession.pendingAnchorAdvance +=
                rightToLeft ? -committedCells : committedCells
            // Clear the pending advance next runloop turn if no redraw used it.
            DispatchQueue.main.async { [weak self] in
                self?.compositionSession.pendingAnchorAdvance = 0
            }
            compositionSession.anchored = false
        }
        sendCommittedString(text)
    }

    private func sendCommittedString(_ text: String) {
        let operation = routeCommittedText(text)
        switch operation.transport {
        case .none: return
        case .input: sendInput?(operation.utf8)
        case .paste: sendPaste?(operation.utf8)
        }
    }

    private func refreshCompositionWidthPolicy() {
        guard let grid else { return }
        compositionWidthPolicy.ambiguousIsDouble = grid.ambiguousWidthDouble
        compositionWidthPolicy.emojiIsDouble = grid.emojiWidthDouble
    }

    /// Notes a change to the preedit state and relayouts, refreshing geometry
    /// when a fresh session needs its anchor bounds.
    private func compositionStateDidChange() {
        if textInputCoordinator.isActive, !compositionSession.anchored {
            compositionGeometry = nil
            refreshCompositionGeometry()
        }
        updateCompositionLayout()
        needsDisplay = true
    }

    /// Relayouts against a safe fallback and refreshes geometry when the view's
    /// geometry changes underneath an active session.
    func textInputGeometryDidChange() {
        if textInputCoordinator?.isActive == true {
            compositionGeometry = nil
            if compositionRequest.pending {
                compositionRequest.generation += 1
                compositionRequest.pending = false
            }
            refreshCompositionGeometry()
        }
        updateCompositionLayout()
        inputContext?.invalidateCharacterCoordinates()
    }

    /// Fetches the window's editable-text geometry asynchronously. A generation
    /// number lets a later resize, split, or focus change invalidate an older
    /// request before its reply installs stale bounds.
    private func refreshCompositionGeometry() {
        guard textInputCoordinator.isActive, let fetch = fetchCompositionGeometry,
              !compositionRequest.pending else { return }
        compositionRequest.pending = true
        compositionRequest.generation += 1
        let generation = compositionRequest.generation
        Task { [weak self] in
            let geometry = await fetch()
            guard let self,
                  generation == self.compositionRequest.generation else { return }
            self.compositionRequest.pending = false
            if let geometry {
                self.compositionWidthPolicy.overrides = geometry.cellwidthOverrides
            }
            self.compositionGeometry = geometry
            self.updateCompositionLayout()
        }
    }

    /// Rebuilds the preedit render cache from the marked string, the cached
    /// geometry, and the width policy, converting the pure layout result into
    /// synthetic cells.
    private func updateCompositionLayout() {
        guard textInputCoordinator != nil else { return }
        if !textInputCoordinator.isActive, compositionSession.awaitingCommitRedraw,
           compositionRender.valid {
            // Cocoa committed, but Neovim has not published the redraw yet.
            // Preserve the final preedit frame so displaced cells do not snap
            // back for a single frame.
            needsDisplay = true
            return
        }
        guard textInputCoordinator.isActive, let grid,
              grid.width > 0, grid.height > 0,
              backingCellSize.width > 0, backingCellSize.height > 0 else {
            compositionRender.cells.removeAll(keepingCapacity: true)
            compositionRender.valid = false
            compositionSession.anchored = false
            return
        }

        let cursor = grid.cursor
        if !compositionSession.anchored {
            // The first layout of a session captures the Neovim cursor as a
            // stable client-side anchor. Later redraws must not drag the preedit
            // unless a resize/reflow explicitly resets the session.
            compositionSession.anchor = GridPoint(
                row: cursor.row,
                column: cursor.column + compositionSession.pendingAnchorAdvance)
            compositionSession.pendingAnchorAdvance = 0
            compositionSession.anchored = true
        }

        let row = clampCompositionRow(compositionSession.anchor.row,
                                      gridHeight: grid.height)
        var left = 0
        var right = grid.width
        var geometryApplies = false
        var rightToLeft = false
        // Geometry is usable only while the anchor still falls in the editable
        // text rectangle. Otherwise use full-grid LTR overwrite fallback rather
        // than displacing cells with stale bounds.
        if let geometry = compositionGeometry,
           compositionSession.anchor.row >= Int(geometry.textRow),
           compositionSession.anchor.row < Int(geometry.textRow) + Int(geometry.textHeight),
           compositionSession.anchor.column >= Int(geometry.textCol),
           compositionSession.anchor.column < Int(geometry.textCol) + Int(geometry.textWidth) {
            left = max(0, Int(geometry.textCol))
            right = min(grid.width, Int(geometry.textCol) + Int(geometry.textWidth))
            geometryApplies = left < right
            rightToLeft = geometryApplies && geometry.rightToLeft
        }

        refreshCompositionWidthPolicy()
        let marked = textInputCoordinator.markedText?.string ?? ""
        struct Grapheme { var text: String; var range: NSRange; var width: Int }
        var graphemes: [Grapheme] = []
        marked.enumerateSubstrings(in: marked.startIndex..<marked.endIndex,
                                   options: .byComposedCharacterSequences) {
            substring, substringRange, _, _ in
            guard let substring else { return }
            let nsRange = NSRange(substringRange, in: marked)
            let width = compositionGraphemeWidth(substring, self.compositionWidthPolicy)
            graphemes.append(Grapheme(text: substring, range: nsRange, width: width))
        }

        let selection = textInputCoordinator.selectedRange()
        var input = CompositionLayoutInput()
        input.gridWidth = grid.width
        input.gridHeight = grid.height
        input.anchorRow = compositionSession.anchor.row
        input.anchorColumn = compositionSession.anchor.column
        input.textLeft = left
        input.textWidth = right - left
        input.geometryValid = geometryApplies
        input.rightToLeft = rightToLeft
        input.insertMode = grid.displacesForComposition
        input.selectionLocation = UInt32(selection.location)
        input.graphemes = graphemes.map {
            CompositionGrapheme(width: $0.width,
                                utf16Location: UInt32($0.range.location),
                                utf16Length: UInt32($0.range.length))
        }
        // Only valid LTR Insert-mode geometry can safely displace existing cells;
        // other cases render the preedit as an overwrite overlay.
        if input.geometryValid, input.insertMode, !rightToLeft {
            var col = min(max(compositionSession.anchor.column, left), right - 1)
            while col < right {
                let width = grid.cell(row, col).width
                input.sourceCells.append(CompositionSourceCell(column: col, width: width))
                col += width
            }
        }

        let layout = layoutComposition(input)

        var attributes = CellAttributes()
        let underCursor = grid.cell(row, layout.cursorColumn)
        attributes.foreground = underCursor.foreground
        attributes.background = underCursor.background
        attributes.special = underCursor.foreground
        attributes.flags = [.underline]
        attributes.blend = CellAttributes.noBlend

        compositionRender.cells.removeAll(keepingCapacity: true)
        compositionRender.row = layout.row
        compositionRender.clearStart = layout.clearStart
        compositionRender.clearEnd = layout.clearEnd
        compositionRender.background = attributes.background
        for placement in layout.placements {
            let position = SIMD2<Int16>(Int16(placement.column), Int16(layout.row))
            switch placement.kind {
            case .marked:
                let grapheme = graphemes[placement.sourceIndex]
                var cellAttributes = attributes
                if grapheme.width == 2 { cellAttributes.flags.insert(.doublewidth) }
                let cell = Cell(text: grapheme.text, attrs: cellAttributes)
                compositionRender.cells.append(CompositionRenderCell(
                    cell: cell, position: position, utf16Range: grapheme.range,
                    marked: true))
            case .displaced:
                let source = input.sourceCells[placement.sourceIndex]
                compositionRender.cells.append(CompositionRenderCell(
                    cell: grid.cell(layout.row, source.column), position: position,
                    utf16Range: NSRange(location: NSNotFound, length: 0),
                    marked: false))
            }
        }
        compositionRender.valid = true
        inputContext?.invalidateCharacterCoordinates()
        needsDisplay = true
    }

    // MARK: - Look Up

    /// Identifies the most recent gesture, so an earlier selection query that
    /// answers late is discarded instead of opening a stale popover.
    private var lookupRequestToken: UInt64 = 0

    /// The text baseline within a row, in the view's coordinate space. The
    /// popover's leader line points here, so it must match where the renderer
    /// puts the glyphs.
    private var lookupBaseline: CGFloat {
        convertFromBacking(NSSize(width: 0,
                                  height: CGFloat(baselineTranslate.y))).height
    }

    override func quickLook(with event: NSEvent) {
        lookupRequestToken &+= 1
        let token = lookupRequestToken
        let point = cellLocation(event.locationInWindow)
        guard let grid, LookupController.grid(grid, contains: point) else { return }

        // In Visual mode the selection is what the user is pointing at,
        // and only Neovim knows its text — a linewise or multi-line
        // selection covers more than the row under the pointer.
        if grid.isVisualMode {
            requestVisualLookup(at: point, token: token, gridTick: grid.tick)
            return
        }
        showRenderedLookup(at: point)
    }

    /// Looks up the word under the point, read straight from the drawn grid.
    private func showRenderedLookup(at point: GridPoint) {
        guard let result = lookupController.renderedLookup(
                at: point, in: grid, cellSize: backingCellSize,
                baseline: lookupBaseline) else { return }
        showDefinition(for: result.attributedString, at: result.anchorPoint)
    }

    /// Asks Neovim for the Visual selection and looks it up, anchored at its
    /// first cell. Nothing is shown if the gesture was superseded, the grid
    /// changed underneath, or the point turns out to be outside the selection.
    private func requestVisualLookup(at point: GridPoint, token: UInt64,
                                     gridTick: UInt64) {
        guard let fetch = fetchVisualSelection else { return }

        Task { [weak self] in
            let selection = await fetch()
            guard let self, let selection, self.lookupRequestToken == token,
                  let grid = self.grid, grid.tick == gridTick,
                  selection.contains(point) else { return }

            let cell = self.backingCellSize
            let baseline = self.lookupBaseline
            let anchor = self.lookupController.renderedLookup(
                at: selection.start, in: grid, cellSize: cell,
                baseline: baseline)?.anchorPoint
                ?? NSPoint(x: CGFloat(selection.start.column) * cell.width,
                           y: CGFloat(selection.start.row) * cell.height + baseline)

            self.showDefinition(
                for: self.lookupController.attributedString(selection.text),
                at: anchor)
        }
    }
}
