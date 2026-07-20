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
//  set before the first draw. Input handling and IME composition are added in
//  later phases; this view is the renderer.
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

final class GridView: NSView, CALayerDelegate {
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

    // MARK: - Setup

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layerContentsPlacement = .topLeft
        // Force the backing layer so metalLayer is ready before any geometry or
        // configuration call touches it.
        _ = layer
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
        grid = newGrid
        cursorVisible = true
        restartBlink()
        needsDisplay = true
    }

    var gridValue: Grid? { grid }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        metalLayer.drawableSize = convertToBacking(newSize)
    }

    /// Disables blinking and forces a block-outline cursor, as inactive windows
    /// do in the system terminal.
    func setInactive() {
        guard !inactive else { return }
        inactive = true
        blinkTimer?.invalidate()
        blinkTimer = nil
        cursorVisible = true
        needsDisplay = true
    }

    /// Restores the cursor style and blink loop from the current grid.
    func setActive() {
        guard inactive else { return }
        inactive = false
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

        let uniformSize = MemoryLayout<uniform_data>.stride
        let backgroundSize = gridSize * MemoryLayout<UInt32>.stride
        let glyphSize = gridSize * stride
        let cellGraphicSize = gridSize * cellGraphicStride
        let lineSize = gridSize * lineStride * 4

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
                                                capacity: gridSize)
        let cellGraphics = cellGraphicRegion.ptr.bindMemory(
            to: cell_graphic_data.self, capacity: gridSize)
        let lines = lineRegion.ptr.bindMemory(to: line_data.self,
                                              capacity: gridSize * 4)

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
               glyphOffset: glyphRegion.offset, glyphCount: glyphCount,
               cellGraphicOffset: cellGraphicRegion.offset,
               cellGraphicCount: cellGraphicCount,
               lineOffset: lineRegion.offset, lineCount: lineCount,
               cursorShape: drawnShape)
    }

    private func encode(context: RenderContext, drawable: CAMetalDrawable,
                        buffer: MTLBuffer, frame: MetalFrameBuffer, index: Int,
                        gridSize: Int, uniformOffset: Int, backgroundOffset: Int,
                        glyphOffset: Int, glyphCount: Int,
                        cellGraphicOffset: Int, cellGraphicCount: Int,
                        lineOffset: Int, lineCount: Int,
                        cursorShape: CursorShape?) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 1, green: 1, blue: 1, alpha: 1)
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

        if cellGraphicCount > 0 {
            encoder.setRenderPipelineState(context.cellGraphicPipeline)
            encoder.setVertexBufferOffset(cellGraphicOffset, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: 4, instanceCount: cellGraphicCount)
        }

        if glyphCount > 0 {
            encoder.setRenderPipelineState(context.glyphPipeline)
            encoder.setVertexBufferOffset(glyphOffset, index: 1)
            encoder.setFragmentTexture(context.glyphManager.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: 4, instanceCount: glyphCount)
        }

        if lineCount > 0 {
            encoder.setRenderPipelineState(context.linePipeline)
            encoder.setVertexBufferOffset(lineOffset, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: 4, instanceCount: lineCount)
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
    /// views always outline; a hidden or blinked-off cursor draws nothing.
    private func renderedCursorShape(grid: Grid, cursor: Cursor) -> CursorShape? {
        if grid.hideCursor || !cursorVisible { return nil }
        if inactive { return .blockOutline }
        return cursor.shape
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

    // MARK: - Key input

    override func keyDown(with event: NSEvent) {
        handleKeyDown(event, keyEvent: makeKeyboardEvent(event))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let keyEvent = makeKeyboardEvent(event)
        let menuOwnsEvent = Self.menuContainsKeyEquivalent(NSApp.mainMenu, event)
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
}
