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

    func testDefaultFontFamilyHasUsableMetrics() throws {
        try requireDevice()
        let manager = RenderContextManager()
        let descriptor = FontManager.defaultDescriptor()
        let family = manager.fontManager.family(
            descriptor: descriptor, size: 15, scaleFactor: 2)

        XCTAssertEqual(family.unscaledSize, 15)
        XCTAssertEqual(family.scaleFactor, 2)
        XCTAssertEqual(family.size, 30, accuracy: 0.001)
        XCTAssertGreaterThan(family.ascent, 0)
        XCTAssertGreaterThan(family.descent, 0)
        XCTAssertGreaterThan(family.width, 0)
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

        XCTAssertEqual(resized.unscaledSize, 16)
        XCTAssertEqual(resized.scaleFactor, 2)
        XCTAssertEqual(resized.size, 32, accuracy: 0.001)
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
        view.setFont(family, lineSpace: 4)
        XCTAssertEqual(view.convertToBacking(view.cellSize).height,
                       naturalHeight + 4)
        view.setFont(family, lineSpace: -10_000)
        XCTAssertEqual(view.convertToBacking(view.cellSize).height, 2)
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
        let device = context.device
        let width = 32
        let height = 32

        func atlas(_ format: MTLPixelFormat) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type2DArray
            descriptor.pixelFormat = format
            descriptor.width = 32
            descriptor.height = 32
            descriptor.arrayLength = 1
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        }

        let mask = try atlas(.r8Unorm)
        let color = try atlas(.rgba8Unorm)
        let coverage = [UInt8](repeating: 255, count: 32 * 32)
        mask.replace(
            region: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0,
            slice: 0, withBytes: coverage, bytesPerRow: 32,
            bytesPerImage: 0)

        var uniforms = uniform_data(
            pixel_size: SIMD2<Float>(2.0 / Float(width),
                                     -2.0 / Float(height)),
            cell_pixel_size: SIMD2<Float>(8, 8),
            cell_size: SIMD2<Float>(1, -1), baseline: .zero,
            cursor_position: .zero, cursor_color: 0,
            cursor_line_width: 0, cursor_cell_width: 1, grid_width: 4,
            cursor_xray: 0)
        let uniformBuffer = try XCTUnwrap(withUnsafeBytes(of: &uniforms) {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
        })

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height,
            mipmapped: false)
        outputDescriptor.usage = [.renderTarget]
        outputDescriptor.storageMode = .shared
        let output = try XCTUnwrap(device.makeTexture(
            descriptor: outputDescriptor))
        // The pass clears on load, so both draws can share one target.
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        func render(_ source: glyph_data) throws -> [UInt8] {
            var glyph = source
            let glyphBuffer = try XCTUnwrap(withUnsafeBytes(of: &glyph) {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
            })
            let command = try XCTUnwrap(
                context.commandQueue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(
                descriptor: pass))
            encoder.setRenderPipelineState(context.glyphPipeline)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(glyphBuffer, offset: 0, index: 1)
            encoder.setFragmentTexture(mask, index: 0)
            encoder.setFragmentTexture(color, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: 4, instanceCount: 1)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)

            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            output.getBytes(&pixels, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0)
            return pixels
        }
        func alpha(_ pixels: [UInt8], _ x: Int, _ y: Int) -> UInt8 {
            pixels[(y * width + x) * 4 + 3]
        }

        let rightAndVertical = try render(glyph_data(
            grid_position: SIMD2<Int16>(0, 2), cell_width: 1,
            foreground_color: UInt32.max, atlas: 0,
            rect: glyph_rect(
                size: SIMD2<Int16>(24, 32),
                position: SIMD2<Int16>(0, -12), texture_origin: .zero),
            flags: 0))
        XCTAssertGreaterThan(alpha(rightAndVertical, 14, 10), 0)
        XCTAssertEqual(alpha(rightAndVertical, 18, 10), 0)
        XCTAssertGreaterThan(alpha(rightAndVertical, 4, 10), 0)
        XCTAssertEqual(alpha(rightAndVertical, 4, 6), 0)
        XCTAssertGreaterThan(alpha(rightAndVertical, 4, 30), 0)

        let left = try render(glyph_data(
            grid_position: SIMD2<Int16>(2, 0), cell_width: 1,
            foreground_color: UInt32.max, atlas: 0,
            rect: glyph_rect(
                size: SIMD2<Int16>(24, 8),
                position: SIMD2<Int16>(-12, 0), texture_origin: .zero),
            flags: 0))
        XCTAssertGreaterThan(alpha(left, 10, 4), 0)
        XCTAssertEqual(alpha(left, 6, 4), 0)
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
            let bitmap = rasterizer.rasterize(
                font: family.regular, foreground: foreground, text: "M",
                options: options)
            var total = 0
            for y in 0..<Int(bitmap.height) {
                for x in 0..<Int(bitmap.width) {
                    total += Int(bitmap.buffer[y * bitmap.stride + x])
                }
            }
            return total
        }

        let plain = coverage(GlyphRasterizationOptions(
            thicken: false, strength: 50))
        let thickened = coverage(GlyphRasterizationOptions(
            thicken: true, strength: 50))
        let strongest = coverage(GlyphRasterizationOptions(
            thicken: true, strength: 255))
        XCTAssertGreaterThan(thickened, plain)
        XCTAssertGreaterThan(strongest, thickened)
    }

    func testDisabledThickeningNormalizesStrength() {
        XCTAssertEqual(
            GlyphRasterizationOptions(thicken: false, strength: 255),
            GlyphRasterizationOptions(thicken: false, strength: 0))
        XCTAssertNotEqual(
            GlyphRasterizationOptions(thicken: true, strength: 50),
            GlyphRasterizationOptions(thicken: true, strength: 51))
    }

    func testTextureCacheGrowsOntoNewPages() throws {
        try requireDevice()
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal command queue")
        }

        // A tiny page forces each added bitmap onto a fresh page.
        let cache = try XCTUnwrap(GlyphTextureCache(
            queue: queue, pixelFormat: .r8Unorm,
            pageWidth: 8, pageHeight: 8,
            initialCapacity: 1, growthFactor: 2))
        let rasterizer = GlyphRasterizer(width: 64, height: 64)
        let family = FontManager().family(
            descriptor: FontManager.defaultDescriptor(), size: 15, scaleFactor: 1)

        let bitmap = rasterizer.rasterize(
            font: family.regular, foreground: RGBColor(neovim: 0xFFFFFF),
            text: "W", options: rasterOptions)

        let first = try XCTUnwrap(cache.add(bitmap))
        let second = try XCTUnwrap(cache.add(bitmap))
        XCTAssertGreaterThan(second.z, first.z)
        XCTAssertEqual(cache.pagesUsed, Int(second.z) + 1)
    }

    func testTextureCacheRefusesToExceedHardPageLimit() throws {
        try requireDevice()
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal command queue")
        }
        let rasterizer = GlyphRasterizer(width: 64, height: 64)
        let family = FontManager().family(
            descriptor: FontManager.defaultDescriptor(), size: 15,
            scaleFactor: 1)
        let bitmap = rasterizer.rasterize(
            font: family.regular, foreground: RGBColor(neovim: 0xFFFFFF),
            text: "W", options: rasterOptions)
        let cache = try XCTUnwrap(GlyphTextureCache(
            queue: queue, pixelFormat: .r8Unorm,
            pageWidth: Int(bitmap.width) + 1,
            pageHeight: Int(bitmap.height), initialCapacity: 1,
            growthFactor: 2, maximumPages: 1))

        XCTAssertNotNil(cache.add(bitmap))
        XCTAssertNil(cache.add(bitmap))
        XCTAssertEqual(cache.pagesCapacity, 1)
    }

    func testTextureCacheReportsInitialAllocationFailure() throws {
        try requireDevice()
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal command queue")
        }
        let cache = GlyphTextureCache(
            queue: queue, pixelFormat: .r8Unorm,
            pageWidth: 8, pageHeight: 8,
            initialCapacity: 1, growthFactor: 2,
            makeTexture: { _, _ in nil })

        XCTAssertNil(cache)
    }

    func testTextureCacheResetReplacesAndEmptiesTexture() throws {
        try requireDevice()
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal command queue")
        }
        let rasterizer = GlyphRasterizer(width: 64, height: 64)
        let family = FontManager().family(
            descriptor: FontManager.defaultDescriptor(), size: 15,
            scaleFactor: 1)
        let bitmap = rasterizer.rasterize(
            font: family.regular, foreground: RGBColor(neovim: 0xFFFFFF),
            text: "M", options: rasterOptions)
        let cache = try XCTUnwrap(GlyphTextureCache(
            queue: queue, pixelFormat: .r8Unorm,
            pageWidth: 32, pageHeight: 32,
            initialCapacity: 2, growthFactor: 2))

        XCTAssertNotNil(cache.add(bitmap))
        let original = cache.texture
        XCTAssertTrue(cache.reset())
        XCTAssertFalse(cache.texture === original)
        XCTAssertEqual(cache.pagesCapacity, 1)
        XCTAssertEqual(cache.pagesUsed, 1)
        XCTAssertNotNil(cache.add(bitmap))
    }

    func testTextureCacheRetriesFailedGrowth() throws {
        try requireDevice()
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal command queue")
        }
        let rasterizer = GlyphRasterizer(width: 64, height: 64)
        let family = FontManager().family(
            descriptor: FontManager.defaultDescriptor(), size: 15,
            scaleFactor: 1)
        let bitmap = rasterizer.rasterize(
            font: family.regular, foreground: RGBColor(neovim: 0xFFFFFF),
            text: "W", options: rasterOptions)
        var attempts = 0
        let cache = try XCTUnwrap(GlyphTextureCache(
            queue: queue, pixelFormat: .r8Unorm,
            pageWidth: Int(bitmap.width) + 1,
            pageHeight: Int(bitmap.height), initialCapacity: 1,
            growthFactor: 2,
            makeTexture: { device, descriptor in
                attempts += 1
                guard attempts != 2 else { return nil }
                return device.makeTexture(descriptor: descriptor)
            }))
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

    func testShaperIgnoresColorsButBreaksRunsOnFace() throws {
        let family = try requireLigatureFamily()
        let shaper = LigatureShaper()

        // Each cell draws its own glyph in its own color, so a highlight
        // boundary inside a run is harmless.
        var recolored = makeRow("->")
        recolored[recolored.startIndex + 1] = recolored[recolored.startIndex + 1]
            .recolored(foreground: RGBColor(neovim: 0xFF0000),
                       background: RGBColor(neovim: 0x000000),
                       special: RGBColor(neovim: 0x000000))
        var glyphs: [LigaturePlacement] = []
        shaper.shape(row: recolored, family: family, into: &glyphs)
        XCTAssertEqual(glyphs.map(\.glyph), shape("->", family: family))

        // A face boundary does break it: the two halves are shaped apart, and
        // neither is long enough to be a run.
        var mixed = Array(makeRow("->"))
        var bold = CellAttributes()
        bold.flags = [.bold]
        mixed[1] = Cell(text: ">", attrs: bold)
        shaper.shape(row: ArraySlice(mixed), family: family, into: &glyphs)
        XCTAssertEqual(glyphs.map(\.glyph), [0, 0])
    }

    func testShaperFindsNoLigaturesInAPlainFont() throws {
        // The system monospaced font carries no programming ligatures, so every
        // run must fall through to ordinary per-cell rendering.
        let family = FontManager().family(
            descriptor: FontManager.defaultDescriptor(), size: 15,
            scaleFactor: 2)
        XCTAssertEqual(shape("->", family: family), [0, 0])
        XCTAssertEqual(shape("===", family: family), [0, 0, 0])
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

    /// The cursor rect must hide an ordinary glyph and reveal only the x-ray
    /// one, so a ligature whose ink comes from a neighboring cell still shows
    /// the character the cursor sits on.
    func testGlyphPipelineCarvesCursorXray() throws {
        try requireDevice()
        let context = try RenderContextManager().defaultRenderContext()
        let device = context.device
        let side = 32

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
        let color = try atlas(.rgba8Unorm)
        mask.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0,
                     slice: 0, withBytes: [UInt8](repeating: 255,
                                                  count: side * side),
                     bytesPerRow: side, bytesPerImage: 0)

        // A block cursor on column 1, fully opaque, with the x-ray active.
        var uniforms = uniform_data(
            pixel_size: SIMD2<Float>(2.0 / Float(side), -2.0 / Float(side)),
            cell_pixel_size: SIMD2<Float>(8, 8),
            cell_size: SIMD2<Float>(0.5, -0.5), baseline: .zero,
            cursor_position: SIMD2<Int16>(1, 0), cursor_color: 0xFF00_0000,
            cursor_line_width: 0, cursor_cell_width: 1, grid_width: 4,
            cursor_xray: 1)
        let uniformBuffer = try XCTUnwrap(withUnsafeBytes(of: &uniforms) {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
        })

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: side, height: side,
            mipmapped: false)
        outputDescriptor.usage = [.renderTarget]
        outputDescriptor.storageMode = .shared
        let output = try XCTUnwrap(device.makeTexture(
            descriptor: outputDescriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        // One glyph anchored on column 1 whose ink also covers column 0, the
        // shape a spacer-plus-overhang ligature produces.
        func render(flags: UInt32) throws -> [UInt8] {
            var glyph = glyph_data(
                grid_position: SIMD2<Int16>(1, 0), cell_width: 1,
                foreground_color: UInt32.max, atlas: 0,
                rect: glyph_rect(size: SIMD2<Int16>(16, 8),
                                 position: SIMD2<Int16>(-8, 0),
                                 texture_origin: .zero),
                flags: flags)
            let glyphBuffer = try XCTUnwrap(withUnsafeBytes(of: &glyph) {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
            })
            let command = try XCTUnwrap(
                context.commandQueue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(
                descriptor: pass))
            encoder.setRenderPipelineState(context.glyphPipeline)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(glyphBuffer, offset: 0, index: 1)
            encoder.setFragmentTexture(mask, index: 0)
            encoder.setFragmentTexture(color, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: 4, instanceCount: 1)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)

            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            output.getBytes(&pixels, bytesPerRow: side * 4,
                            from: MTLRegionMake2D(0, 0, side, side),
                            mipmapLevel: 0)
            return pixels
        }
        func alpha(_ pixels: [UInt8], _ x: Int, _ y: Int) -> UInt8 {
            pixels[(y * side + x) * 4 + 3]
        }

        // The ordinary glyph keeps its ink outside the cursor cell and loses it
        // inside, so the rest of the ligature survives.
        let ordinary = try render(flags: 0)
        XCTAssertGreaterThan(alpha(ordinary, 4, 4), 0)
        XCTAssertEqual(alpha(ordinary, 12, 4), 0)

        // The x-ray glyph is the exact complement: confined to the cursor cell.
        let xray = try render(flags: GLYPH_FLAG_XRAY)
        XCTAssertEqual(alpha(xray, 4, 4), 0)
        XCTAssertGreaterThan(alpha(xray, 12, 4), 0)

        // Mid-fade the split stays a clean cut: the cursor's opacity lives in
        // the character's own color, so neither draw is partially blended.
        uniforms.cursor_color = 0x8000_0000
        uniformBuffer.contents().copyMemory(
            from: &uniforms, byteCount: MemoryLayout<uniform_data>.size)
        let fadingOrdinary = try render(flags: 0)
        XCTAssertGreaterThan(alpha(fadingOrdinary, 4, 4), 0)
        XCTAssertEqual(alpha(fadingOrdinary, 12, 4), 0)
        let fadingXray = try render(flags: GLYPH_FLAG_XRAY)
        XCTAssertEqual(alpha(fadingXray, 4, 4), 0)
        XCTAssertEqual(alpha(fadingXray, 12, 4), alpha(xray, 12, 4))

        // With the x-ray off, an ordinary glyph is untouched everywhere.
        uniforms.cursor_color = 0xFF00_0000
        uniforms.cursor_xray = 0
        uniformBuffer.contents().copyMemory(
            from: &uniforms, byteCount: MemoryLayout<uniform_data>.size)
        let unmasked = try render(flags: 0)
        XCTAssertGreaterThan(alpha(unmasked, 4, 4), 0)
        XCTAssertGreaterThan(alpha(unmasked, 12, 4), 0)
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
    private func makeBitmap(
        width: Int, height: Int, storage: UnsafeMutablePointer<UInt8>
    ) -> GlyphBitmap {
        GlyphBitmap(buffer: storage, stride: width, leftBearing: 0,
                    ascent: Int16(height), width: Int16(width),
                    height: Int16(height), format: .mask)
    }

    private func makeCache(width: Int,
                           height: Int) throws -> GlyphTextureCache {
        try requireDevice()
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal command queue")
        }
        return try XCTUnwrap(GlyphTextureCache(
            queue: queue, pixelFormat: .r8Unorm,
            pageWidth: width, pageHeight: height,
            initialCapacity: 1, growthFactor: 2))
    }

    /// `preserve` equal to the current page index still leaves one page too
    /// many, because the index is zero-based: the oldest page must go.
    func testEvictDropsTheOldestPageWhenPreserveEqualsPageIndex() throws {
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        storage.initialize(repeating: 0, count: 64)
        defer { storage.deallocate() }
        // One glyph per page: a second never fits beside or below the first.
        let cache = try makeCache(width: 5, height: 4)
        let bitmap = makeBitmap(width: 4, height: 4, storage: storage)

        for _ in 0..<3 { XCTAssertNotNil(cache.add(bitmap)) }
        XCTAssertEqual(cache.pagesUsed, 3)

        XCTAssertEqual(cache.evict(preserve: 2), 1)
        XCTAssertEqual(cache.pagesUsed, 2)
        XCTAssertLessThanOrEqual(cache.pagesUsed, cache.pagesCapacity)

        let origin = try XCTUnwrap(cache.add(bitmap))
        XCTAssertLessThan(Int(origin.z), cache.pagesCapacity)
    }

    /// Preserving more pages than are in use must keep every one of them, and
    /// must never leave the current page beyond the texture's slice count.
    func testEvictKeepsEveryUsedPageWhenPreserveExceedsThem() throws {
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        storage.initialize(repeating: 0, count: 64)
        defer { storage.deallocate() }
        let cache = try makeCache(width: 5, height: 4)
        let bitmap = makeBitmap(width: 4, height: 4, storage: storage)

        for _ in 0..<2 { XCTAssertNotNil(cache.add(bitmap)) }
        XCTAssertEqual(cache.pagesUsed, 2)

        XCTAssertEqual(cache.evict(preserve: 3), 0)
        XCTAssertEqual(cache.pagesUsed, 2)
        XCTAssertLessThanOrEqual(cache.pagesUsed, cache.pagesCapacity)

        let origin = try XCTUnwrap(cache.add(bitmap))
        XCTAssertLessThan(Int(origin.z), cache.pagesCapacity)
    }

    /// A reset must forget the previous atlas's row height, or the first row of
    /// the fresh page reserves space the glyphs in it do not need.
    func testResetForgetsTheRowHeightOfTheOldAtlas() throws {
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
        storage.initialize(repeating: 0, count: 256)
        defer { storage.deallocate() }
        // 10 + 1 + 4 exceeds the page height; 4 + 1 + 4 does not. So a stale
        // row height of 10 forces a new page where 4 would wrap in place.
        let cache = try makeCache(width: 9, height: 12)
        let tall = makeBitmap(width: 4, height: 10, storage: storage)
        let short = makeBitmap(width: 4, height: 4, storage: storage)

        XCTAssertNotNil(cache.add(tall))
        XCTAssertTrue(cache.reset())

        XCTAssertNotNil(cache.add(short))
        XCTAssertNotNil(cache.add(short))
        let wrapped = try XCTUnwrap(cache.add(short))
        XCTAssertEqual(wrapped.z, 0)
        XCTAssertEqual(cache.pagesUsed, 1)
    }
}
