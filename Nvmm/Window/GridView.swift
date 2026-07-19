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
import CoreText
import Metal
import QuartzCore
import simd

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

        let leading = floor(font.leading)
        let descent = floor(font.descent)
        let ascent = floor(font.ascent)
        let cellHeight = leading + descent + ascent
        let cellWidth = floor(font.width)

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
}
