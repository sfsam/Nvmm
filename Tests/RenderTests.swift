//
//  Nvmm
//  RenderTests.swift
//
//  Exercises the render pipeline against a real Metal device: render-context
//  construction, font metrics, and on-demand glyph rasterization into the
//  texture cache. Tests skip when no Metal device is available.
//

import CoreText
import Metal
import XCTest
@testable import Nvmm

@MainActor
final class RenderTests: XCTestCase {
    private let rasterOptions = GlyphRasterizationOptions(
        thicken: true, strength: 50)

    private func requireDevice() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available")
        }
    }

    /// A rendered BGRA target, read back for pixel assertions.
    private struct Pixels {
        let pixels: [UInt8]
        let width: Int
        let height: Int

        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            pixels[(y * width + x) * 4 + 3]
        }

        func red(_ x: Int, _ y: Int) -> UInt8 {
            pixels[(y * width + x) * 4 + 2]
        }
    }

    private func makeBuffer<T>(_ device: MTLDevice,
                               _ values: [T]) throws -> MTLBuffer {
        try XCTUnwrap(values.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
        })
    }

    /// Draws `instances` quads with `pipeline` into a transparent
    /// `width`x`height` target and reads the result back. The uniforms are
    /// bound to both stages at index 0 and the instance data to the vertex
    /// stage at index 1, as the renderer binds them.
    private func render(
        _ context: RenderContext, _ pipeline: MTLRenderPipelineState,
        width: Int, height: Int, uniforms: uniform_data,
        instances: MTLBuffer, count: Int,
        fragmentTextures: [MTLTexture] = []
    ) throws -> Pixels {
        let device = context.device
        let uniformBuffer = try makeBuffer(device, [uniforms])

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height,
            mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        let command = try XCTUnwrap(context.commandQueue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(
            descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(instances, offset: 0, index: 1)
        for (index, texture) in fragmentTextures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                               vertexCount: 4, instanceCount: count)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        output.getBytes(&pixels, bytesPerRow: width * 4,
                        from: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0)
        return Pixels(pixels: pixels, width: width, height: height)
    }

    /// Mask and color glyph atlases of one `side`-square page, the mask
    /// fully covered so a glyph's quad shows exactly where it is drawn.
    private func coveredAtlases(
        _ device: MTLDevice, side: Int
    ) throws -> [MTLTexture] {
        func atlas(_ format: MTLPixelFormat) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type2DArray
            descriptor.pixelFormat = format
            descriptor.width = side
            descriptor.height = side
            descriptor.arrayLength = 1
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        }
        let mask = try atlas(.r8Unorm)
        mask.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0,
                     slice: 0,
                     withBytes: [UInt8](repeating: 255, count: side * side),
                     bytesPerRow: side, bytesPerImage: 0)
        return [mask, try atlas(.rgba8Unorm)]
    }

    private func renderCellGraphics(
        _ rows: [[String]], cellWidth: Int = 12, cellHeight: Int = 18,
        lineWidth: UInt32 = 2
    ) throws -> Pixels {
        try requireDevice()
        let context = try RenderContextManager().defaultRenderContext()
        let columnCount = try XCTUnwrap(rows.first?.count)
        XCTAssertTrue(rows.allSatisfy { $0.count == columnCount })
        let outputWidth = cellWidth * columnCount
        let outputHeight = cellHeight * rows.count

        let uniforms = uniform_data(
            pixel_size: SIMD2<Float>(2.0 / Float(outputWidth),
                                     -2.0 / Float(outputHeight)),
            cell_pixel_size: SIMD2<Float>(Float(cellWidth), Float(cellHeight)),
            box_line_width: lineWidth,
            baseline: .zero, cursor_position: .zero, cursor_color: 0,
            cursor_line_width: 0, cursor_height: UInt32(cellHeight),
            cursor_top: 0, cursor_cell_width: 1,
            grid_width: UInt32(columnCount))

        var graphics: [cell_graphic_data] = []
        for (row, graphemes) in rows.enumerated() {
            for (column, grapheme) in graphemes.enumerated() {
                guard let kind = CellGraphicKind(
                    grapheme: grapheme, nativePowerlineSymbols: true
                ) else {
                    continue
                }
                graphics.append(cell_graphic_data(
                    grid_position: SIMD2<Int16>(Int16(column), Int16(row)),
                    cell_width: 1, color: UInt32.max, background_color: 0,
                    cursor_color: UInt32.max, cursor_background_color: 0,
                    kind: kind.rawValue, flags: 0))
            }
        }
        return try render(
            context, context.cellGraphicPipeline,
            width: outputWidth, height: outputHeight, uniforms: uniforms,
            instances: makeBuffer(context.device, graphics),
            count: graphics.count)
    }

    func testRenderContextBuildsPipelinesAndTexture() throws {
        try requireDevice()
        let manager = RenderContextManager()
        let context = try manager.defaultRenderContext()

        // A built context exposes separate mask and color texture arrays.
        XCTAssertEqual(context.glyphManager.maskTexture.textureType, .type2DArray)
        XCTAssertEqual(context.glyphManager.maskTexture.pixelFormat, .r8Unorm)
        XCTAssertEqual(context.glyphManager.colorTexture.textureType, .type2DArray)
        XCTAssertEqual(context.glyphManager.colorTexture.pixelFormat, .rgba8Unorm)

        // The same device returns the same cached context.
        let again = try manager.renderContext(for: context.device)
        XCTAssertTrue(again === context)
    }

    func testGridLayerUsesNativeDisplayP3Target() throws {
        let view = GridView(frame: .zero)
        let layer = try XCTUnwrap(view.layer as? CAMetalLayer)
        let name = try XCTUnwrap(layer.colorspace?.name)

        XCTAssertEqual(layer.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(name as String, CGColorSpace.displayP3 as String)
    }

    func testClearColorConvertsSRGBToDisplayP3() {
        let color = GridView.clearColor(
            for: RGBColor(red: 255, green: 0, blue: 0))

        XCTAssertEqual(color.red, 0.9175, accuracy: 0.001)
        XCTAssertEqual(color.green, 0.2003, accuracy: 0.001)
        XCTAssertEqual(color.blue, 0.1386, accuracy: 0.001)
        XCTAssertEqual(color.alpha, 1)
    }

    /// Separators run edge to edge, so adjacent cells join without a seam:
    /// the last row or column of one cell matches the first of the next.
    func testCellGraphicShaderJoinsSeparatorsAcrossCells() throws {
        let cellWidth = 12
        let cellHeight = 18
        for grapheme in ["│", "┃", "║"] {
            let image = try renderCellGraphics(
                [[grapheme], [grapheme]], cellWidth: cellWidth,
                cellHeight: cellHeight)
            for x in 0..<cellWidth {
                XCTAssertEqual(image.alpha(x, cellHeight - 1),
                               image.alpha(x, cellHeight), grapheme)
            }
            let edgeInk = (0..<cellWidth).map {
                image.alpha($0, cellHeight - 1)
            }.max()
            XCTAssertGreaterThan(edgeInk ?? 0, 0, grapheme)
        }
        for grapheme in ["─", "━", "═"] {
            let image = try renderCellGraphics(
                [[grapheme, grapheme]], cellWidth: cellWidth,
                cellHeight: cellHeight)
            for y in 0..<cellHeight {
                XCTAssertEqual(image.alpha(cellWidth - 1, y),
                               image.alpha(cellWidth, y), grapheme)
            }
            let edgeInk = (0..<cellHeight).map {
                image.alpha(cellWidth - 1, $0)
            }.max()
            XCTAssertGreaterThan(edgeInk ?? 0, 0, grapheme)
        }
    }

    /// Every grapheme drawn natively leaves ink in its cell: the whole Box
    /// Drawing and Block Elements ranges, and the Powerline set.
    func testCellGraphicShaderInksEveryNativeGrapheme() throws {
        let ranges: [(scalars: [Int], columns: Int, width: Int, height: Int)] = [
            (Array(0x2500...0x257F), 16, 12, 18),
            (Array(0x2580...0x259F), 16, 13, 19),
            (Array(0xE0B0...0xE0BF) + [0xE0D2, 0xE0D4, 0xE0D6, 0xE0D7],
             10, 13, 27),
        ]
        for range in ranges {
            let graphemes = range.scalars.map {
                String(UnicodeScalar($0)!)
            }
            let rows = stride(from: 0, to: graphemes.count,
                              by: range.columns).map {
                Array(graphemes[$0..<($0 + range.columns)])
            }
            let image = try renderCellGraphics(
                rows, cellWidth: range.width, cellHeight: range.height)

            for index in graphemes.indices {
                let column = index % range.columns
                let row = index / range.columns
                var hasInk = false
                for y in (row * range.height)..<((row + 1) * range.height) {
                    for x in (column * range.width)..<((column + 1) * range.width) {
                        hasInk = hasInk || image.alpha(x, y) > 0
                    }
                }
                XCTAssertTrue(hasInk, graphemes[index])
            }
        }
    }

    func testPowerlineMirrorPairsHaveMatchingCoverage() throws {
        let pairs = [("", ""), ("", ""),
                     ("", ""), ("", ""),
                     ("", ""), ("", ""),
                     ("", ""), ("", ""),
                     ("", ""), ("", "")]
        let width = 13
        let height = 27

        for (left, right) in pairs {
            let leftImage = try renderCellGraphics(
                [[left]], cellWidth: width, cellHeight: height)
            let rightImage = try renderCellGraphics(
                [[right]], cellWidth: width, cellHeight: height)
            for y in 0..<height {
                for x in 0..<width {
                    XCTAssertEqual(leftImage.alpha(x, y),
                                   rightImage.alpha(width - x - 1, y),
                                   "\(left) / \(right) at \(x),\(y)")
                }
            }
        }
    }

    func testPowerlineShapesFillSpacedCellHeight() throws {
        let graphemes = ["", "", "", "", ""]
        let width = 13
        let height = 31
        let image = try renderCellGraphics(
            [graphemes], cellWidth: width, cellHeight: height)

        for (column, grapheme) in graphemes.prefix(3).enumerated() {
            for y in 0..<height {
                let rowCoverage = (0..<width).map {
                    image.alpha(column * width + $0, y)
                }.max() ?? 0
                XCTAssertGreaterThan(rowCoverage, 0, "\(grapheme) row \(y)")
            }
        }
        for column in 3..<graphemes.count {
            let top = (0..<width).map {
                image.alpha(column * width + $0, 0)
            }.max() ?? 0
            let bottom = (0..<width).map {
                image.alpha(column * width + $0, height - 1)
            }.max() ?? 0
            XCTAssertGreaterThan(top, 0, graphemes[column])
            XCTAssertGreaterThan(bottom, 0, graphemes[column])
        }
    }

    func testPowerlineRoundedOutlineAndTrapezoidGap() throws {
        let width = 13
        let height = 27
        let image = try renderCellGraphics(
            [["", ""]], cellWidth: width, cellHeight: height,
            lineWidth: 2)
        let middle = height / 2

        XCTAssertEqual(image.alpha(0, middle), 0)
        XCTAssertGreaterThan(image.alpha(width - 1, middle), 0)
        XCTAssertGreaterThan(image.alpha(0, 0), 0)

        for x in 0..<width {
            XCTAssertEqual(image.alpha(width + x, middle), 0)
        }
        XCTAssertGreaterThan(image.alpha(width, 0), 0)
        XCTAssertGreaterThan(image.alpha(width, height - 1), 0)
    }

    func testBlockElementsUseSharedRoundedBoundaries() throws {
        let width = 13
        let height = 19
        let image = try renderCellGraphics(
            [["▀", "▄", "▌", "▐"]], cellWidth: width,
            cellHeight: height)
        let middleX = Int(floor(Double(width) / 2.0 + 0.5))
        let middleY = Int(floor(Double(height) / 2.0 + 0.5))

        for y in 0..<height {
            let upper = image.alpha(0, y) > 0
            let lower = image.alpha(width, y) > 0
            XCTAssertEqual(upper, y < middleY)
            XCTAssertEqual(lower, y >= middleY)
        }
        for x in 0..<width {
            let left = image.alpha(2 * width + x, 0) > 0
            let right = image.alpha(3 * width + x, 0) > 0
            XCTAssertEqual(left, x < middleX)
            XCTAssertEqual(right, x >= middleX)
        }
    }

    func testBlockElementEighthsUseFullCellDimensions() throws {
        let width = 13
        let height = 27
        let image = try renderCellGraphics(
            [["▅", "▋"]], cellWidth: width, cellHeight: height)
        let top = Int(floor(Double(height) * 3.0 / 8.0 + 0.5))
        let right = Int(floor(Double(width) * 5.0 / 8.0 + 0.5))

        for y in 0..<height {
            XCTAssertEqual(image.alpha(0, y) > 0, y >= top)
        }
        for y in 0..<height {
            for x in 0..<width {
                XCTAssertEqual(image.alpha(width + x, y) > 0, x < right)
            }
        }
    }

    func testBlockElementQuadrantMasks() throws {
        let graphemes = ["▖", "▗", "▘", "▙", "▚",
                         "▛", "▜", "▝", "▞", "▟"]
        let masks: [UInt32] = [
            CELL_GRAPHIC_QUADRANT_BOTTOM_LEFT,
            CELL_GRAPHIC_QUADRANT_BOTTOM_RIGHT,
            CELL_GRAPHIC_QUADRANT_TOP_LEFT,
            CELL_GRAPHIC_QUADRANT_TOP_LEFT
                | CELL_GRAPHIC_QUADRANT_BOTTOM_LEFT
                | CELL_GRAPHIC_QUADRANT_BOTTOM_RIGHT,
            CELL_GRAPHIC_QUADRANT_TOP_LEFT
                | CELL_GRAPHIC_QUADRANT_BOTTOM_RIGHT,
            CELL_GRAPHIC_QUADRANT_TOP_LEFT
                | CELL_GRAPHIC_QUADRANT_TOP_RIGHT
                | CELL_GRAPHIC_QUADRANT_BOTTOM_LEFT,
            CELL_GRAPHIC_QUADRANT_TOP_LEFT
                | CELL_GRAPHIC_QUADRANT_TOP_RIGHT
                | CELL_GRAPHIC_QUADRANT_BOTTOM_RIGHT,
            CELL_GRAPHIC_QUADRANT_TOP_RIGHT,
            CELL_GRAPHIC_QUADRANT_TOP_RIGHT
                | CELL_GRAPHIC_QUADRANT_BOTTOM_LEFT,
            CELL_GRAPHIC_QUADRANT_TOP_RIGHT
                | CELL_GRAPHIC_QUADRANT_BOTTOM_LEFT
                | CELL_GRAPHIC_QUADRANT_BOTTOM_RIGHT,
        ]
        let width = 13
        let height = 19
        let middleX = Int(floor(Double(width) / 2.0 + 0.5))
        let middleY = Int(floor(Double(height) / 2.0 + 0.5))
        let image = try renderCellGraphics(
            [graphemes], cellWidth: width, cellHeight: height)

        for (column, mask) in masks.enumerated() {
            for y in 0..<height {
                for x in 0..<width {
                    let quadrant = (y < middleY ? 0 : 2)
                        + (x < middleX ? 0 : 1)
                    let expected = mask & (1 << UInt32(quadrant)) != 0
                    XCTAssertEqual(
                        image.alpha(column * width + x, y) > 0,
                        expected, graphemes[column])
                }
            }
        }
    }

    func testBlockElementShadesFillSpacedCell() throws {
        let width = 13
        let height = 27
        let image = try renderCellGraphics(
            [["░", "▒", "▓"]], cellWidth: width, cellHeight: height)
        let shades = (0..<3).map { image.red($0 * width, 0) }

        XCTAssertLessThan(shades[0], shades[1])
        XCTAssertLessThan(shades[1], shades[2])

        for column in 0..<3 {
            for y in 0..<height {
                for x in 0..<width {
                    XCTAssertEqual(image.red(column * width + x, y),
                                   shades[column])
                }
            }
        }
    }

    func testCellGraphicShaderPreservesDoubleLineGap() throws {
        let image = try renderCellGraphics([["║", "╬"]])
        let centerX = 6
        let centerY = 9

        XCTAssertGreaterThan(image.alpha(centerX - 2, centerY), 0)
        XCTAssertEqual(image.alpha(centerX, centerY), 0)
        XCTAssertGreaterThan(image.alpha(centerX + 2, centerY), 0)

        let crossCenter = centerX + 12
        XCTAssertEqual(image.alpha(crossCenter, centerY), 0)
        XCTAssertGreaterThan(image.alpha(crossCenter - 2, centerY - 3), 0)
        XCTAssertGreaterThan(image.alpha(crossCenter + 2, centerY - 3), 0)
        XCTAssertGreaterThan(image.alpha(crossCenter - 4, centerY - 2), 0)
        XCTAssertGreaterThan(image.alpha(crossCenter + 4, centerY + 2), 0)
    }

    /// Rounded corners open toward the two sides they join, curve without
    /// straight bridges into the cell centre, and weigh no more than the
    /// square corner they replace.
    func testCellGraphicShaderDrawsRoundedCorners() throws {
        let image = try renderCellGraphics([["╭", "╮", "╯", "╰"]])
        let centerY = 9
        let lastY = 17

        XCTAssertGreaterThan(image.alpha(6, lastY), 0)
        XCTAssertGreaterThan(image.alpha(11, centerY), 0)
        XCTAssertEqual(image.alpha(6, 0), 0)
        XCTAssertEqual(image.alpha(0, centerY), 0)

        XCTAssertGreaterThan(image.alpha(18, lastY), 0)
        XCTAssertGreaterThan(image.alpha(12, centerY), 0)
        XCTAssertEqual(image.alpha(18, 0), 0)
        XCTAssertEqual(image.alpha(23, centerY), 0)

        XCTAssertGreaterThan(image.alpha(30, 0), 0)
        XCTAssertGreaterThan(image.alpha(24, centerY), 0)
        XCTAssertEqual(image.alpha(30, lastY), 0)
        XCTAssertEqual(image.alpha(35, centerY), 0)

        XCTAssertGreaterThan(image.alpha(42, 0), 0)
        XCTAssertGreaterThan(image.alpha(47, centerY), 0)
        XCTAssertEqual(image.alpha(42, lastY), 0)
        XCTAssertEqual(image.alpha(36, centerY), 0)

        // The curve of ╭, with no straight segment into the centre.
        XCTAssertGreaterThan(image.alpha(6, 16), 0)
        XCTAssertGreaterThan(image.alpha(6, 14), 0)
        XCTAssertGreaterThan(image.alpha(8, 11), 0)
        XCTAssertGreaterThan(image.alpha(10, 9), 0)
        XCTAssertEqual(image.alpha(9, 14), 0)
        XCTAssertEqual(image.alpha(6, 9), 0)

        let weights = try renderCellGraphics([["╭", "┌"]])
        func coverage(column: Int) -> Int {
            let xRange = (column * 12)..<((column + 1) * 12)
            return (0..<18).reduce(into: 0) { total, y in
                for x in xRange {
                    total += Int(weights.alpha(x, y))
                }
            }
        }
        let rounded = coverage(column: 0)
        let square = coverage(column: 1)
        XCTAssertGreaterThan(rounded, square * 3 / 4)
        XCTAssertLessThanOrEqual(rounded, square)
    }

    func testFrameBufferRetriesAfterAllocationFailure() throws {
        try requireDevice()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var attempts = 0
        var requestedLengths: [Int] = []
        let makeBuffer: MetalFrameBuffer.BufferFactory = {
            device, length, options in
            attempts += 1
            requestedLengths.append(length)
            guard attempts > 1 else { return nil }
            return device.makeBuffer(length: length, options: options)
        }
        let frame = MetalFrameBuffer()

        XCTAssertFalse(frame.create(
            device: device, size: 4_096, makeBuffer: makeBuffer))
        XCTAssertNil(frame.metalBuffer)
        XCTAssertTrue(frame.create(
            device: device, size: 4_096, makeBuffer: makeBuffer))
        XCTAssertNotNil(frame.metalBuffer)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(requestedLengths, [1_048_576, 1_048_576])

        let region = frame.allocate(32)
        region.ptr.storeBytes(of: UInt32(42), as: UInt32.self)
        XCTAssertTrue(frame.create(
            device: device, size: 4_096, makeBuffer: makeBuffer))
        XCTAssertEqual(attempts, 2)
    }

    func testFrameBufferKeepsUsableBufferWhenGrowthFails() throws {
        try requireDevice()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var attempts = 0
        let makeBuffer: MetalFrameBuffer.BufferFactory = {
            device, length, options in
            attempts += 1
            guard attempts != 2 else { return nil }
            return device.makeBuffer(length: length, options: options)
        }
        let frame = MetalFrameBuffer()

        XCTAssertTrue(frame.create(
            device: device, size: 4_096, makeBuffer: makeBuffer))
        let original = try XCTUnwrap(frame.metalBuffer)
        XCTAssertFalse(frame.create(
            device: device, size: 2_097_152, makeBuffer: makeBuffer))
        XCTAssertTrue(frame.metalBuffer === original)

        XCTAssertTrue(frame.create(
            device: device, size: 2_097_152, makeBuffer: makeBuffer))
        XCTAssertFalse(frame.metalBuffer === original)
        XCTAssertEqual(attempts, 3)
    }

    func testResizedFontFamilyPreservesFacesAndChangesSize() throws {
        let manager = FontManager()
        let wideDescriptor = try XCTUnwrap(
            FontManager.makeDescriptor("Helvetica"))
        let family = manager.family(
            descriptor: FontManager.defaultDescriptor(), size: 15,
            scaleFactor: 1, wideDescriptor: wideDescriptor, wideSize: 14)
        let resized = manager.resized(family, size: 16, scaleFactor: 2)
        let faces: [FontAttributes] = [.none, .bold, .italic, .boldItalic]

        XCTAssertEqual(family.unscaledSize, 15)
        XCTAssertEqual(family.size, 15, accuracy: 0.001)
        XCTAssertEqual(resized.unscaledSize, 16)
        XCTAssertEqual(resized.scaleFactor, 2)
        XCTAssertEqual(resized.size, 32, accuracy: 0.001)
        XCTAssertGreaterThan(resized.ascent, 0)
        XCTAssertGreaterThan(resized.descent, 0)
        XCTAssertGreaterThan(resized.width, 0)
        for face in faces {
            XCTAssertEqual(CTFontCopyPostScriptName(resized.font(face)),
                           CTFontCopyPostScriptName(family.font(face)))
            XCTAssertEqual(
                CTFontCopyPostScriptName(resized.font(face, wide: true)),
                CTFontCopyPostScriptName(family.font(face, wide: true)))
        }
        XCTAssertNotEqual(CTFontCopyPostScriptName(family.font(.none)),
                          CTFontCopyPostScriptName(
                            family.font(.none, wide: true)))
        XCTAssertEqual(CTFontGetSize(resized.font(.none, wide: true)), 30)
    }

    func testBoxLineThicknessComesFromTheFontsOwnBoxGlyph() throws {
        let manager = FontManager()
        let menlo = manager.family(
            descriptor: try XCTUnwrap(FontManager.makeDescriptor("Menlo")),
            size: 14, scaleFactor: 2)
        // Menlo draws its light box line about 0.084 em thick: 2.35 pixels
        // at a 28-pixel size, well above its 1.23-pixel underline.
        let thickness = try XCTUnwrap(menlo.boxLineThickness)
        XCTAssertGreaterThan(thickness, 2)
        XCTAssertLessThan(thickness, 3)
        XCTAssertGreaterThan(thickness, menlo.underlineThickness)

        // Courier has no box-drawing glyphs.
        let courier = manager.family(
            descriptor: try XCTUnwrap(FontManager.makeDescriptor("Courier")),
            size: 14, scaleFactor: 2)
        XCTAssertNil(courier.boxLineThickness)
    }

    func testLineSpaceChangesAndClampsCellHeight() {
        let manager = FontManager()
        let family = manager.family(
            descriptor: FontManager.defaultDescriptor(), size: 15,
            scaleFactor: 2)
        XCTAssertEqual(
            CTFontCopyPostScriptName(family.font(.none, wide: true)),
            CTFontCopyPostScriptName(family.font(.none)))
        let view = GridView(frame: .zero)

        view.setFont(family)
        let naturalHeight = view.convertToBacking(view.cellSize).height
        let naturalBaseline = view.fontBaseline
        let naturalCursorHeight = view.cursorHeight
        view.setFont(family, lineSpace: 4)
        XCTAssertEqual(view.convertToBacking(view.cellSize).height,
                       naturalHeight + 4)
        XCTAssertEqual(view.fontBaseline, naturalBaseline + 2)
        XCTAssertEqual(view.cursorHeight, naturalCursorHeight)
        view.setFont(family, lineSpace: -10_000)
        XCTAssertEqual(view.convertToBacking(view.cellSize).height, 2)
        XCTAssertEqual(view.cursorHeight, 2)
    }

    func testGlyphManagerRasterizesAndCaches() throws {
        try requireDevice()
        let manager = RenderContextManager()
        let context = try manager.defaultRenderContext()
        let family = manager.fontManager.family(
            descriptor: FontManager.defaultDescriptor(), size: 15, scaleFactor: 2)

        let foreground = RGBColor(neovim: 0xFFFFFF)
        let glyph = context.glyphManager.glyph(
            font: family.regular, text: "M", foreground: foreground)

        // A visible glyph has a non-empty bounding rect.
        XCTAssertEqual(glyph.format, .mask)
        XCTAssertGreaterThan(glyph.rect.size.x, 0)
        XCTAssertGreaterThan(glyph.rect.size.y, 0)

        // Text colors do not change the cached coverage-mask rectangle.
        let cached = context.glyphManager.glyph(
            font: family.regular, text: "M",
            foreground: RGBColor(neovim: 0xFF0000))
        XCTAssertEqual(cached.rect.size.x, glyph.rect.size.x)
        XCTAssertEqual(cached.rect.size.y, glyph.rect.size.y)
        XCTAssertEqual(cached.rect.texture_origin,
                       glyph.rect.texture_origin)
    }

    func testGlyphPipelineBoundsOverhangToAdjacentCells() throws {
        try requireDevice()
        let context = try RenderContextManager().defaultRenderContext()
        let atlases = try coveredAtlases(context.device, side: 32)
        let uniforms = uniform_data(
            pixel_size: SIMD2<Float>(2.0 / 32, -2.0 / 32),
            cell_pixel_size: SIMD2<Float>(8, 8), box_line_width: 2,
            baseline: .zero,
            cursor_position: .zero, cursor_color: 0,
            cursor_line_width: 0, cursor_height: 8, cursor_top: 0,
            cursor_cell_width: 1, grid_width: 4)

        func render(_ glyph: glyph_data) throws -> Pixels {
            try self.render(
                context, context.glyphPipeline, width: 32, height: 32,
                uniforms: uniforms,
                instances: makeBuffer(context.device, [glyph]), count: 1,
                fragmentTextures: atlases)
        }

        let rightAndVertical = try render(glyph_data(
            grid_position: SIMD2<Int16>(0, 2), cell_width: 1,
            foreground_color: UInt32.max, atlas: 0,
            rect: glyph_rect(
                size: SIMD2<Int16>(24, 32),
                position: SIMD2<Int16>(0, -12), texture_origin: .zero)))
        XCTAssertGreaterThan(rightAndVertical.alpha(14, 10), 0)
        XCTAssertEqual(rightAndVertical.alpha(18, 10), 0)
        XCTAssertGreaterThan(rightAndVertical.alpha(4, 10), 0)
        XCTAssertEqual(rightAndVertical.alpha(4, 6), 0)
        XCTAssertGreaterThan(rightAndVertical.alpha(4, 30), 0)

        let left = try render(glyph_data(
            grid_position: SIMD2<Int16>(2, 0), cell_width: 1,
            foreground_color: UInt32.max, atlas: 0,
            rect: glyph_rect(
                size: SIMD2<Int16>(24, 8),
                position: SIMD2<Int16>(-12, 0), texture_origin: .zero)))
        XCTAssertGreaterThan(left.alpha(10, 4), 0)
        XCTAssertEqual(left.alpha(6, 4), 0)
    }

    func testRasterizerSeparatesTextAndColorGlyphs() {
        let family = FontManager().family(
            descriptor: FontManager.defaultDescriptor(), size: 15,
            scaleFactor: 2)
        let rasterizer = GlyphRasterizer(width: 64, height: 64)
        let foreground = RGBColor(neovim: 0xFFFFFF)

        let text = rasterizer.rasterize(
            font: family.regular, foreground: foreground, text: "M",
            options: rasterOptions)
        let emoji = rasterizer.rasterize(
            font: family.regular, foreground: foreground, text: "😀",
            options: rasterOptions)

        XCTAssertEqual(text.format, .mask)
        XCTAssertEqual(emoji.format, .color)
    }

    func testFontThickeningAndStrengthIncreaseMaskCoverage() {
        let family = FontManager().family(
            descriptor: FontManager.defaultDescriptor(), size: 15,
            scaleFactor: 2)
        let rasterizer = GlyphRasterizer(width: 64, height: 64)
        let foreground = RGBColor(neovim: 0xFFFFFF)
        func coverage(_ options: GlyphRasterizationOptions) -> Int {
            self.coverage(rasterizer.rasterize(
                font: family.regular, foreground: foreground, text: "M",
                options: options))
        }

        let plain = coverage(GlyphRasterizationOptions(
            thicken: false, strength: 50))
        let thickened = coverage(GlyphRasterizationOptions(
            thicken: true, strength: 50))
        let strongest = coverage(GlyphRasterizationOptions(
            thicken: true, strength: 255))
        XCTAssertGreaterThan(thickened, plain)
        XCTAssertGreaterThan(strongest, thickened)

        // Strength means nothing without thickening, so it is normalized
        // away rather than splitting the glyph cache.
        XCTAssertEqual(
            GlyphRasterizationOptions(thicken: false, strength: 255),
            GlyphRasterizationOptions(thicken: false, strength: 0))
        XCTAssertNotEqual(
            GlyphRasterizationOptions(thicken: true, strength: 50),
            GlyphRasterizationOptions(thicken: true, strength: 51))
    }

    // MARK: - Ligatures

    /// A font whose programming ligatures the shaper can exercise. Skips when
    /// none of the candidates is installed.
    private func requireLigatureFamily() throws -> FontFamily {
        let names = ["FiraCodeNF-Reg", "FiraCode-Regular",
                     "JetBrainsMono-Regular", "IosevkaNFM", "CascadiaCode-Regular"]
        for name in names {
            guard let descriptor = FontManager.makeDescriptor(name) else {
                continue
            }
            return FontManager().family(descriptor: descriptor, size: 15,
                                        scaleFactor: 2)
        }
        throw XCTSkip("No font with programming ligatures installed")
    }

    /// A row of single-width cells, one per character; a space becomes blank.
    private func makeRow(_ text: String,
                         flags: CellFlags = []) -> ArraySlice<Cell> {
        var attrs = CellAttributes()
        attrs.flags = flags
        return ArraySlice(text.map { Cell(text: String($0), attrs: attrs) })
    }

    /// A row where each wide character takes a double-width cell followed by
    /// the blank right half Neovim sends after it.
    private func makeWideRow(_ text: String) -> ArraySlice<Cell> {
        var cells: [Cell] = []
        for character in text {
            var cell = Cell(text: String(character), attrs: CellAttributes())
            guard let scalar = character.unicodeScalars.first,
                  scalar.value > 0x2E80 else {
                cells.append(cell)
                continue
            }
            cell.addDoubleWidth()
            cells.append(cell)
            cells.append(Cell())
        }
        return ArraySlice(cells)
    }

    private func shape(_ text: String, family: FontFamily,
                       shaper: LigatureShaper = LigatureShaper()) -> [CGGlyph] {
        placements(text, family: family, shaper: shaper).map(\.glyph)
    }

    private func placements(
        _ text: String, family: FontFamily,
        shaper: LigatureShaper = LigatureShaper()
    ) -> [LigaturePlacement] {
        var glyphs: [LigaturePlacement] = []
        shaper.shape(row: makeRow(text), family: family, into: &glyphs)
        return glyphs
    }

    func testShaperSubstitutesGlyphsForPunctuationRuns() throws {
        let family = try requireLigatureFamily()

        // Every cell of a ligature keeps a glyph, and each differs from the
        // glyph the same character shapes to on its own.
        let arrow = shape("->", family: family)
        XCTAssertEqual(arrow.count, 2)
        XCTAssertFalse(arrow.contains(0))

        var plain = [CGGlyph](repeating: 0, count: 2)
        var characters = Array("->".utf16)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(
            family.regular, &characters, &plain, 2))
        XCTAssertNotEqual(arrow, plain)
    }

    /// A ligature's ink can live in one glyph that reaches back over the whole
    /// run — Fira Code draws `===` as two empty cells and a single mark. Every
    /// cell must therefore report the run, so the renderer can anchor it at the
    /// first cell and let that ink cover all of it.
    func testShaperReportsTheWholeRunForEachCell() throws {
        let family = try requireLigatureFamily()
        let runs = placements("===", family: family)
        XCTAssertEqual(runs.count, 3)
        for run in runs {
            XCTAssertNotEqual(run.glyph, 0)
            XCTAssertEqual(run.start, 0)
            XCTAssertEqual(run.length, 3)
        }

        // A run bounded by cells that cannot join it starts where it starts.
        let offset = placements("a->b", family: family)
        XCTAssertEqual(offset[0], LigaturePlacement())
        XCTAssertEqual(offset[3], LigaturePlacement())
        XCTAssertEqual(offset[1].start, 1)
        XCTAssertEqual(offset[1].length, 2)
        XCTAssertEqual(offset[2].start, 1)
        XCTAssertEqual(offset[2].length, 2)
    }

    func testShaperLeavesNonLigatureCellsAlone() throws {
        let family = try requireLigatureFamily()

        // Letters never join a run, a lone punctuation cell is too short to be
        // one, and a blank cell ends the run before the run can form.
        XCTAssertEqual(shape("ab", family: family), [0, 0])
        XCTAssertEqual(shape("-x", family: family), [0, 0])
        XCTAssertEqual(shape("- >", family: family), [0, 0, 0])
    }

    /// A ligature's ink can belong to one cell and cover its neighbor, so it
    /// shows one cell's color. Runs break where the drawn text color changes
    /// (a new foreground, or dim) and where the face changes, but not on
    /// background, which the ink lands on either way.
    func testShaperBreaksRunsOnFaceAndTextColor() throws {
        let family = try requireLigatureFamily()
        let shaper = LigatureShaper()
        var glyphs: [LigaturePlacement] = []
        func shapeArrow(second: (Cell) -> Cell) -> [CGGlyph] {
            var row = Array(makeRow("->"))
            row[1] = second(row[1])
            shaper.shape(row: ArraySlice(row), family: family, into: &glyphs)
            return glyphs.map(\.glyph)
        }

        let background = shapeArrow {
            $0.recolored(foreground: $0.foreground,
                         background: RGBColor(neovim: 0x203040),
                         special: $0.special)
        }
        XCTAssertEqual(background, shape("->", family: family))

        let foreground = shapeArrow {
            $0.recolored(foreground: RGBColor(neovim: 0xFF0000),
                         background: $0.background, special: $0.special)
        }
        XCTAssertEqual(foreground, [0, 0])

        var dim = CellAttributes()
        dim.flags = [.dim]
        XCTAssertEqual(shapeArrow { _ in Cell(text: ">", attrs: dim) }, [0, 0])

        // Dim text is drawn blended with its background, so dim cells on
        // different backgrounds draw different colors; on the same, they
        // still ligate.
        var dimRow = Array(makeRow("->", flags: [.dim]))
        shaper.shape(row: ArraySlice(dimRow), family: family, into: &glyphs)
        XCTAssertEqual(glyphs.map(\.glyph), shape("->", family: family))
        dimRow[1] = dimRow[1].recolored(
            foreground: dimRow[1].foreground,
            background: RGBColor(neovim: 0x203040),
            special: dimRow[1].special)
        shaper.shape(row: ArraySlice(dimRow), family: family, into: &glyphs)
        XCTAssertEqual(glyphs.map(\.glyph), [0, 0])

        var bold = CellAttributes()
        bold.flags = [.bold]
        XCTAssertEqual(shapeArrow { _ in Cell(text: ">", attrs: bold) }, [0, 0])
    }

    /// A break column, such as the cursor's, is shaped alone and splits the
    /// run through it; the cells on either side still ligate.
    func testShaperBreaksRunsAtGivenColumns() throws {
        let family = try requireLigatureFamily()
        let shaper = LigatureShaper()
        var glyphs: [LigaturePlacement] = []

        shaper.shape(row: makeRow("->->"), family: family, breakingAt: [2],
                     into: &glyphs)
        XCTAssertEqual(Array(glyphs.map(\.glyph).prefix(2)),
                       shape("->", family: family))
        XCTAssertEqual(glyphs[0].start, 0)
        XCTAssertEqual(glyphs[0].length, 2)
        XCTAssertEqual(glyphs[2].glyph, 0)
        XCTAssertEqual(glyphs[3].glyph, 0)

        shaper.shape(row: makeRow("->"), family: family, breakingAt: [0],
                     into: &glyphs)
        XCTAssertEqual(glyphs.map(\.glyph), [0, 0])

        // No breaks: the same as before.
        shaper.shape(row: makeRow("->->"), family: family, into: &glyphs)
        XCTAssertEqual(glyphs.map(\.glyph), shape("->->", family: family))
    }

    /// The same glyph must rasterize identically whether it is named by text or
    /// by identifier. Coverage is what matters: the two paths agreed on metrics
    /// even when the glyph path was drawing nothing at all, because CTLineDraw
    /// leaves a text matrix behind that CTFontDrawGlyphs would otherwise
    /// inherit. Drawing the text first is what reproduces that.
    func testRasterizingByGlyphMatchesRasterizingByText() throws {
        let family = FontManager().family(
            descriptor: FontManager.defaultDescriptor(), size: 15,
            scaleFactor: 2)
        let rasterizer = GlyphRasterizer(width: 64, height: 64)

        var character = Array("M".utf16)
        var glyph = CGGlyph(0)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(
            family.regular, &character, &glyph, 1))

        // Text first: the glyph path must survive the matrix CTLineDraw leaves.
        let byText = rasterizer.rasterize(
            font: family.regular, foreground: RGBColor(neovim: 0xFFFFFF),
            text: "M", options: rasterOptions)
        let textCoverage = coverage(byText)
        let byGlyph = rasterizer.rasterize(
            font: family.regular, glyph: glyph, options: rasterOptions)
        let glyphCoverage = coverage(byGlyph)

        XCTAssertEqual(byGlyph.format, .mask)
        XCTAssertEqual(byGlyph.width, byText.width)
        XCTAssertEqual(byGlyph.height, byText.height)
        XCTAssertEqual(byGlyph.leftBearing, byText.leftBearing)
        XCTAssertEqual(byGlyph.ascent, byText.ascent)
        XCTAssertGreaterThan(textCoverage, 0)
        XCTAssertEqual(glyphCoverage, textCoverage)
    }

    /// A glyph with no outline — the spacer a ligature font parks in the cells
    /// its ink covers from elsewhere — must report no pixels, so the renderer
    /// can skip it instead of caching and drawing a blank.
    func testOutlinelessGlyphReportsNoPixels() throws {
        try requireDevice()
        let context = try RenderContextManager().defaultRenderContext()
        let family = FontManager().family(
            descriptor: FontManager.defaultDescriptor(), size: 15,
            scaleFactor: 2)
        let rasterizer = GlyphRasterizer(width: 64, height: 64)

        // A space has an advance but no outline.
        var character = Array(" ".utf16)
        var glyph = CGGlyph(0)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(
            family.regular, &character, &glyph, 1))

        let bitmap = rasterizer.rasterize(font: family.regular, glyph: glyph,
                                          options: rasterOptions)
        XCTAssertEqual(bitmap.width, 0)
        XCTAssertEqual(bitmap.height, 0)

        let before = context.glyphManager.maskTexture
        let cached = context.glyphManager.glyph(font: family.regular,
                                                glyphID: glyph)
        XCTAssertEqual(cached.rect.size, .zero)
        XCTAssertEqual(cached.rect.texture_origin, .zero)
        // Nothing was packed, so the atlas is untouched.
        XCTAssertTrue(context.glyphManager.maskTexture === before)
    }

    /// Total ink in a rasterized bitmap.
    private func coverage(_ bitmap: GlyphBitmap) -> Int {
        var total = 0
        for y in 0..<Int(bitmap.height) {
            for x in 0..<Int(bitmap.width) {
                total += Int(bitmap.buffer[y * bitmap.stride + x])
            }
        }
        return total
    }

    /// A wide character owns two columns — itself and a blank right half — and
    /// neither may join a run. A ligature between two of them must still be
    /// found, at its own columns, reporting its own length.
    func testShaperExcludesDoubleWidthCells() throws {
        let family = try requireLigatureFamily()
        let shaper = LigatureShaper()

        var runs: [LigaturePlacement] = []
        shaper.shape(row: makeWideRow("你->好"), family: family, into: &runs)
        XCTAssertEqual(runs.count, 6)
        XCTAssertEqual(runs[0], LigaturePlacement())
        XCTAssertEqual(runs[1], LigaturePlacement())
        XCTAssertNotEqual(runs[2].glyph, 0)
        XCTAssertEqual(runs[2].start, 2)
        XCTAssertEqual(runs[2].length, 2)
        XCTAssertNotEqual(runs[3].glyph, 0)
        XCTAssertEqual(runs[3].start, 2)
        XCTAssertEqual(runs[3].length, 2)
        XCTAssertEqual(runs[4], LigaturePlacement())
        XCTAssertEqual(runs[5], LigaturePlacement())

        // The exclusion is on the cell's width, not on its grapheme: an ASCII
        // cell Neovim marked double-width cannot be absorbed either.
        var cells = Array(makeRow("->"))
        cells[0].addDoubleWidth()
        shaper.shape(row: ArraySlice(cells), family: family, into: &runs)
        XCTAssertEqual(runs, [LigaturePlacement(), LigaturePlacement()])
    }

    /// Cached runs are keyed by face, so changing or resizing the font can
    /// never serve glyphs shaped for the previous one.
    func testShaperCacheIsKeyedByFont() throws {
        let ligatures = try requireLigatureFamily()
        let manager = FontManager()
        let plain = manager.family(descriptor: FontManager.defaultDescriptor(),
                                   size: 15, scaleFactor: 2)
        let shaper = LigatureShaper()

        // One shaper, two faces: neither may answer for the other.
        let arrow = shape("->", family: ligatures, shaper: shaper)
        XCTAssertFalse(arrow.contains(0))
        XCTAssertEqual(shape("->", family: plain, shaper: shaper), [0, 0])
        XCTAssertEqual(shape("->", family: ligatures, shaper: shaper), arrow)

        // A zoom builds new faces, which must shape rather than hit a stale
        // entry, and must not evict the original's answer.
        let zoomed = manager.resized(ligatures, size: 22, scaleFactor: 2)
        XCTAssertFalse(shape("->", family: zoomed, shaper: shaper).contains(0))
        XCTAssertEqual(shape("->", family: ligatures, shaper: shaper), arrow)

        // Discarding the cache changes nothing about what shaping returns.
        shaper.reset()
        XCTAssertEqual(shape("->", family: ligatures, shaper: shaper), arrow)
    }

    // MARK: - Atlas page accounting

    /// A synthetic bitmap of an exact size, so page packing can be reasoned
    /// about without depending on a font's glyph metrics.
    private func makeBitmap(width: Int, height: Int) -> GlyphBitmap {
        let storage = UnsafeMutablePointer<UInt8>.allocate(
            capacity: width * height)
        storage.initialize(repeating: 0, count: width * height)
        addTeardownBlock { storage.deallocate() }
        return GlyphBitmap(buffer: storage, stride: width, leftBearing: 0,
                           ascent: Int16(height), width: Int16(width),
                           height: Int16(height), format: .mask)
    }

    private func makeCache(
        width: Int, height: Int, initialCapacity: Int = 1,
        maximumPages: Int = 64,
        makeTexture: GlyphTextureCache.TextureFactory? = nil
    ) throws -> GlyphTextureCache? {
        try requireDevice()
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal command queue")
        }
        guard let makeTexture else {
            return GlyphTextureCache(
                queue: queue, pixelFormat: .r8Unorm,
                pageWidth: width, pageHeight: height,
                initialCapacity: initialCapacity, growthFactor: 2,
                maximumPages: maximumPages)
        }
        return GlyphTextureCache(
            queue: queue, pixelFormat: .r8Unorm,
            pageWidth: width, pageHeight: height,
            initialCapacity: initialCapacity, growthFactor: 2,
            maximumPages: maximumPages, makeTexture: makeTexture)
    }

    // A 5x4 page holds one 4x4 bitmap: a second never fits beside or below
    // the first, so every add after the first needs a new page.

    /// `preserve` counts the pages to keep. Preserving more than are in use
    /// keeps them all; preserving as many as the current page index still
    /// drops one, because the index is zero-based. Either way the current
    /// page stays within the texture's slice count.
    func testEvictKeepsOnlyThePreservedPages() throws {
        let cache = try XCTUnwrap(makeCache(width: 5, height: 4))
        let bitmap = makeBitmap(width: 4, height: 4)

        for _ in 0..<2 { XCTAssertNotNil(cache.add(bitmap)) }
        XCTAssertEqual(cache.pagesUsed, 2)
        XCTAssertEqual(cache.evict(preserve: 3), 0)
        XCTAssertEqual(cache.pagesUsed, 2)
        var origin = try XCTUnwrap(cache.add(bitmap))
        XCTAssertLessThan(Int(origin.z), cache.pagesCapacity)

        XCTAssertEqual(cache.pagesUsed, 3)
        XCTAssertEqual(cache.evict(preserve: 2), 1)
        XCTAssertEqual(cache.pagesUsed, 2)
        XCTAssertLessThanOrEqual(cache.pagesUsed, cache.pagesCapacity)
        origin = try XCTUnwrap(cache.add(bitmap))
        XCTAssertLessThan(Int(origin.z), cache.pagesCapacity)
    }

    func testTextureCacheRefusesToExceedHardPageLimit() throws {
        let cache = try XCTUnwrap(makeCache(
            width: 5, height: 4, maximumPages: 1))
        let bitmap = makeBitmap(width: 4, height: 4)

        XCTAssertNotNil(cache.add(bitmap))
        XCTAssertNil(cache.add(bitmap))
        XCTAssertEqual(cache.pagesCapacity, 1)
    }

    func testTextureCacheReportsInitialAllocationFailure() throws {
        XCTAssertNil(try makeCache(width: 8, height: 8,
                                   makeTexture: { _, _ in nil }))
    }

    /// A growth that fails leaves the cache as it was, and the next add
    /// tries again.
    func testTextureCacheRetriesFailedGrowth() throws {
        var attempts = 0
        let cache = try XCTUnwrap(makeCache(
            width: 5, height: 4,
            makeTexture: { device, descriptor in
                attempts += 1
                guard attempts != 2 else { return nil }
                return device.makeTexture(descriptor: descriptor)
            }))
        let bitmap = makeBitmap(width: 4, height: 4)
        let original = cache.texture

        XCTAssertNotNil(cache.add(bitmap))
        XCTAssertNil(cache.add(bitmap))
        XCTAssertTrue(cache.texture === original)
        XCTAssertEqual(cache.pagesCapacity, 1)
        XCTAssertEqual(cache.pagesUsed, 1)
        XCTAssertEqual(cache.evict(preserve: 2), 0)
        XCTAssertEqual(attempts, 2)
        XCTAssertNotNil(cache.add(bitmap))
        XCTAssertFalse(cache.texture === original)
        XCTAssertEqual(cache.pagesUsed, 2)
        XCTAssertEqual(attempts, 3)
    }

    func testTextureCacheResetReplacesAndEmptiesTexture() throws {
        let cache = try XCTUnwrap(makeCache(
            width: 32, height: 32, initialCapacity: 2))
        let bitmap = makeBitmap(width: 4, height: 4)

        XCTAssertNotNil(cache.add(bitmap))
        let original = cache.texture
        XCTAssertTrue(cache.reset())
        XCTAssertFalse(cache.texture === original)
        XCTAssertEqual(cache.pagesCapacity, 1)
        XCTAssertEqual(cache.pagesUsed, 1)
        XCTAssertNotNil(cache.add(bitmap))
    }

    /// A reset must forget the previous atlas's row height, or the first row of
    /// the fresh page reserves space the glyphs in it do not need.
    func testResetForgetsTheRowHeightOfTheOldAtlas() throws {
        // 10 + 1 + 4 exceeds the page height; 4 + 1 + 4 does not. So a stale
        // row height of 10 forces a new page where 4 would wrap in place.
        let cache = try XCTUnwrap(makeCache(width: 9, height: 12))
        let tall = makeBitmap(width: 4, height: 10)
        let short = makeBitmap(width: 4, height: 4)

        XCTAssertNotNil(cache.add(tall))
        XCTAssertTrue(cache.reset())

        XCTAssertNotNil(cache.add(short))
        XCTAssertNotNil(cache.add(short))
        let wrapped = try XCTUnwrap(cache.add(short))
        XCTAssertEqual(wrapped.z, 0)
        XCTAssertEqual(cache.pagesUsed, 1)
    }

    /// An undercurl must honor the opacity packed into its color. The wave's
    /// centre travels in its own varying, so nothing needs to be smuggled
    /// through the alpha channel.
    func testUndercurlHonorsPackedOpacity() throws {
        try requireDevice()
        let context = try RenderContextManager().defaultRenderContext()
        let uniforms = uniform_data(
            pixel_size: SIMD2<Float>(2.0 / 32, -2.0 / 32),
            cell_pixel_size: SIMD2<Float>(16, 16), box_line_width: 2,
            baseline: SIMD2<Float>(0, 8),
            cursor_position: .zero, cursor_color: 0,
            cursor_line_width: 0, cursor_height: 16, cursor_top: 0,
            cursor_cell_width: 1, grid_width: 2)

        // period 0xFFFF is the undercurl sentinel; the high byte is opacity.
        func render(opacity: UInt32) throws -> Pixels {
            let line = line_data(
                grid_position: .zero, color: (opacity << 24) | 0xFF,
                ytranslate: 0, period: 0xFFFF, thickness: 8, count: 0, style: 0)
            return try self.render(
                context, context.linePipeline, width: 32, height: 32,
                uniforms: uniforms,
                instances: makeBuffer(context.device, [line]), count: 1)
        }

        // The wave crosses its centre at the left edge of the cell, so (0, 12)
        // sits on it and (4, 15) is far enough below to be discarded.
        let opaque = try render(opacity: 255)
        XCTAssertGreaterThan(opaque.alpha(0, 12), 200)
        XCTAssertEqual(opaque.alpha(4, 15), 0)

        let faded = try render(opacity: 128)
        XCTAssertGreaterThan(faded.alpha(0, 12), 0)
        XCTAssertLessThan(faded.alpha(0, 12), opaque.alpha(0, 12) / 2)

        // The wave itself must not move when only the opacity changes.
        XCTAssertEqual(faded.alpha(4, 15), 0)
    }

    /// Backgrounds must land on exact cell boundaries. Nothing else covers the
    /// background pass, and it is the one vertex function that does not work
    /// in pixels.
    func testBackgroundPipelinePaintsWholeCells() throws {
        try requireDevice()
        let context = try RenderContextManager().defaultRenderContext()

        // A 4x2 grid of 8x16 cells exactly fills the target.
        let uniforms = uniform_data(
            pixel_size: SIMD2<Float>(2.0 / 32, -2.0 / 32),
            cell_pixel_size: SIMD2<Float>(8, 16),
            box_line_width: 2,
            baseline: .zero, cursor_position: .zero, cursor_color: 0,
            cursor_line_width: 0, cursor_height: 8, cursor_top: 0,
            cursor_cell_width: 1, grid_width: 4)

        // Cell 5 is row 1, column 1: pixels x 8..<16, y 16..<32.
        var colors = [UInt32](repeating: 0, count: 8)
        colors[5] = 0xFF00_00FF
        let image = try render(
            context, context.backgroundPipeline, width: 32, height: 32,
            uniforms: uniforms,
            instances: makeBuffer(context.device, colors), count: 8)

        // Every corner inside the cell is painted; every neighbour is not.
        for (x, y) in [(8, 16), (15, 16), (8, 31), (15, 31)] {
            XCTAssertGreaterThan(image.red(x, y), 200, "inside (\(x), \(y))")
        }
        for (x, y) in [(7, 16), (16, 16), (8, 15), (15, 32 - 1 - 16)] {
            XCTAssertEqual(image.red(x, y), 0, "outside (\(x), \(y))")
        }
    }
}
