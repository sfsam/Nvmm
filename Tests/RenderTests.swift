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
    private func requireDevice() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available")
        }
    }

    func testRenderContextBuildsPipelinesAndTexture() throws {
        try requireDevice()
        let manager = RenderContextManager()
        let context = try manager.defaultRenderContext()

        // A built context exposes a live glyph texture as a 2D array.
        XCTAssertEqual(context.glyphManager.texture.textureType, .type2DArray)
        XCTAssertEqual(context.glyphManager.texture.pixelFormat, .rgba8Unorm_srgb)

        // The same device returns the same cached context.
        let again = try manager.renderContext(for: context.device)
        XCTAssertTrue(again === context)
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

    func testResizedFontFamilyPreservesFacesAndChangesSize() {
        let manager = FontManager()
        let family = manager.family(
            descriptor: FontManager.defaultDescriptor(), size: 15,
            scaleFactor: 1)
        let resized = manager.resized(family, size: 16, scaleFactor: 2)
        let faces: [FontAttributes] = [.none, .bold, .italic, .boldItalic]

        XCTAssertEqual(resized.unscaledSize, 16)
        XCTAssertEqual(resized.scaleFactor, 2)
        XCTAssertEqual(resized.size, 32, accuracy: 0.001)
        for face in faces {
            XCTAssertEqual(CTFontCopyPostScriptName(resized.font(face)),
                           CTFontCopyPostScriptName(family.font(face)))
        }
    }

    func testGlyphManagerRasterizesAndCaches() throws {
        try requireDevice()
        let manager = RenderContextManager()
        let context = try manager.defaultRenderContext()
        let family = manager.fontManager.family(
            descriptor: FontManager.defaultDescriptor(), size: 15, scaleFactor: 2)

        let background = RGBColor(neovim: 0x000000)
        let foreground = RGBColor(neovim: 0xFFFFFF)
        let glyph = context.glyphManager.glyph(
            font: family.regular, text: "M",
            background: background, foreground: foreground)

        // A visible glyph has a non-empty bounding rect.
        XCTAssertGreaterThan(glyph.size.x, 0)
        XCTAssertGreaterThan(glyph.size.y, 0)

        // The same request is served from the cache with an identical rect.
        let cached = context.glyphManager.glyph(
            font: family.regular, text: "M",
            background: background, foreground: foreground)
        XCTAssertEqual(cached.size.x, glyph.size.x)
        XCTAssertEqual(cached.size.y, glyph.size.y)
        XCTAssertEqual(cached.texture_origin.z, glyph.texture_origin.z)
    }

    func testTextureCacheGrowsOntoNewPages() throws {
        try requireDevice()
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal command queue")
        }

        // A tiny page forces each added bitmap onto a fresh page.
        let cache = GlyphTextureCache(queue: queue, pageWidth: 8, pageHeight: 8,
                                      initialCapacity: 1, growthFactor: 2)
        let rasterizer = GlyphRasterizer(width: 64, height: 64)
        let family = FontManager().family(
            descriptor: FontManager.defaultDescriptor(), size: 15, scaleFactor: 1)

        let bitmap = rasterizer.rasterize(
            font: family.regular, background: RGBColor(neovim: 0),
            foreground: RGBColor(neovim: 0xFFFFFF), text: "W")

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
            font: family.regular, background: RGBColor(neovim: 0),
            foreground: RGBColor(neovim: 0xFFFFFF), text: "W")
        let cache = GlyphTextureCache(
            queue: queue, pageWidth: Int(bitmap.width) + 1,
            pageHeight: Int(bitmap.height), initialCapacity: 1,
            growthFactor: 2, maximumPages: 1)

        XCTAssertNotNil(cache.add(bitmap))
        XCTAssertNil(cache.add(bitmap))
        XCTAssertEqual(cache.pagesCapacity, 1)
    }
}
