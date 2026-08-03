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
        XCTAssertGreaterThan(cache.pagesSize, 0)
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
        XCTAssertEqual(cache.pagesSize, 0)
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
        XCTAssertEqual(cache.pagesSize, 0)
        XCTAssertEqual(cache.evict(preserve: 2), 0)
        XCTAssertEqual(attempts, 2)
        XCTAssertNotNil(cache.add(bitmap))
        XCTAssertFalse(cache.texture === original)
        XCTAssertEqual(cache.pagesSize, 1)
        XCTAssertEqual(attempts, 3)
    }
}
