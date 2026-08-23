//
//  Nvmm
//  GlyphTextureCache.swift
//
//  Caches rasterized glyphs in a Metal texture array.
//
//  Each slice of the array is a cache page; glyphs are packed left to right,
//  top to bottom, adding rows and then pages as they fill. Pages are evicted
//  FIFO: the newest pages are kept and copied into a smaller texture, and the
//  old texture is released. Any command buffer still referencing the old
//  texture stays valid because the old texture is never mutated in place.
//

import Metal
import simd

final class GlyphTextureCache {
    typealias TextureFactory = @MainActor
        (MTLDevice, MTLTextureDescriptor) -> MTLTexture?

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let makeTexture: TextureFactory
    private let pixelFormat: MTLPixelFormat
    private(set) var texture: MTLTexture
    private let growthFactor: Double
    private let maximumPages: Int

    private var pageCount: Int
    private var pageIndex: Int
    private let xSize: Int
    private let ySize: Int
    private var xUsed: Int
    private var yUsed: Int
    private var rowHeight: Int

    init?(queue: MTLCommandQueue, pixelFormat: MTLPixelFormat,
          pageWidth: Int, pageHeight: Int,
          initialCapacity: Int, growthFactor: Double,
          maximumPages: Int = 64,
          makeTexture: @escaping TextureFactory = defaultTextureFactory) {
        precondition(maximumPages > 0)
        let device = queue.device
        let pageCount = min(maximumPages, max(1, initialCapacity))
        guard let texture = Self.allocTexture(
            device: device, width: pageWidth, height: pageHeight,
            length: pageCount, pixelFormat: pixelFormat,
            makeTexture: makeTexture) else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.makeTexture = makeTexture
        self.pixelFormat = pixelFormat
        self.growthFactor = growthFactor
        self.maximumPages = maximumPages
        xUsed = 0
        yUsed = 0
        xSize = pageWidth
        ySize = pageHeight
        rowHeight = 0
        pageIndex = 0
        self.pageCount = pageCount
        self.texture = texture
    }

    // Nonisolated so teardown skips the isolated-deinit executor hop that trips
    // a libmalloc double-free under XCTest's post-test memory checker.
    nonisolated deinit {}

    /// The number of cache pages currently allocated.
    var pagesCapacity: Int { pageCount }

    /// The number of cache pages in use. `pageIndex` is the zero-based index of
    /// the page being filled, so one more page is in use than its value.
    var pagesUsed: Int { pageIndex + 1 }

    /// Replaces all pages with a fresh empty page. Existing command buffers
    /// retain the old texture until the GPU has finished reading it.
    func reset() -> Bool {
        evict(preserve: 0) != nil
    }

    private static func allocTexture(
        device: MTLDevice, width: Int, height: Int, length: Int,
        pixelFormat: MTLPixelFormat,
        makeTexture: TextureFactory
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.arrayLength = length
        descriptor.pixelFormat = pixelFormat
        descriptor.width = width
        descriptor.height = height
        descriptor.mipmapLevelCount = 1
        return makeTexture(device, descriptor)
    }

    private static func defaultTextureFactory(
        device: MTLDevice, descriptor: MTLTextureDescriptor
    ) -> MTLTexture? {
        device.makeTexture(descriptor: descriptor)
    }

    /// Copies pages `[begin, begin + count)` into a freshly sized texture.
    private func reallocate(newPageCount: Int, begin: Int,
                            count: Int) -> Bool {
        guard let newTexture = Self.allocTexture(
            device: device, width: xSize, height: ySize,
            length: newPageCount, pixelFormat: pixelFormat,
            makeTexture: makeTexture),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return false
        }
        blit.copy(from: texture, sourceSlice: begin, sourceLevel: 0,
                  to: newTexture, destinationSlice: 0, destinationLevel: 0,
                  sliceCount: count, levelCount: 1)
        blit.endEncoding()
        commandBuffer.commit()
        texture = newTexture
        pageCount = newPageCount
        return true
    }

    private func replace(region: MTLRegion, slice: Int, bitmap: GlyphBitmap) {
        texture.replace(region: region, mipmapLevel: 0, slice: slice,
                        withBytes: bitmap.buffer, bytesPerRow: bitmap.stride,
                        bytesPerImage: 0)
    }

    /// Starts a new page for the bitmap, growing the page array if needed.
    private func addNewPage(_ bitmap: GlyphBitmap) -> simd_short3? {
        let nextPage = pageIndex + 1
        guard nextPage < maximumPages else { return nil }

        if nextPage >= pageCount {
            let grown = Int((Double(pageCount) * growthFactor).rounded(.up))
            let newCount = min(maximumPages, max(nextPage + 1, grown))
            guard reallocate(newPageCount: newCount, begin: 0,
                             count: pageCount) else {
                return nil
            }
        }
        pageIndex = nextPage

        xUsed = min(Int(bitmap.width) + 1, xSize)
        yUsed = min(Int(bitmap.height), ySize)
        rowHeight = yUsed

        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                               size: MTLSize(width: xUsed, height: yUsed, depth: 1))
        replace(region: region, slice: pageIndex, bitmap: bitmap)

        return simd_short3(0, 0, Int16(pageIndex))
    }

    /// Adds a bitmap and returns its origin: x and y pixel coordinates of the
    /// top-left corner and the cache page it landed on.
    func add(_ bitmap: GlyphBitmap) -> simd_short3? {
        let glyphHeight = Int(bitmap.height)
        let glyphWidth = Int(bitmap.width)

        rowHeight = max(glyphHeight, rowHeight)

        while true {
            let newX = glyphWidth + xUsed
            let newY = rowHeight + yUsed

            if newX <= xSize && newY <= ySize {
                let region = MTLRegion(
                    origin: MTLOrigin(x: xUsed, y: yUsed, z: 0),
                    size: MTLSize(width: glyphWidth, height: glyphHeight, depth: 1))
                replace(region: region, slice: pageIndex, bitmap: bitmap)

                let origin = simd_short3(Int16(xUsed), Int16(yUsed), Int16(pageIndex))
                xUsed = newX + 1
                return origin
            }

            yUsed = yUsed + rowHeight + 1
            xUsed = 0
            rowHeight = glyphHeight

            if glyphWidth > xSize || glyphHeight + yUsed > ySize {
                return addNewPage(bitmap)
            }
        }
    }

    /// Evicts all but the newest `preserve` pages by copying them into a
    /// smaller texture. Returns the number of used pages that were evicted (the
    /// glyph manager uses to shift cached page indices), 0 if none were, or nil
    /// when allocation or command encoding fails.
    func evict(preserve: Int) -> Int? {
        if preserve == 0 {
            guard let newTexture = Self.allocTexture(
                device: device, width: xSize, height: ySize, length: 1,
                pixelFormat: pixelFormat,
                makeTexture: makeTexture) else {
                return nil
            }
            texture = newTexture
            pageCount = 1
            pageIndex = 0
            xUsed = 0
            yUsed = 0
            rowHeight = 0
            return 0
        }

        // Every page in use is worth keeping; hand back only spare capacity,
        // and only when there is some, so an equal-sized texture is never
        // allocated and blitted for nothing.
        if preserve >= pagesUsed {
            guard pageCount > pagesUsed else { return 0 }
            guard reallocate(newPageCount: pagesUsed, begin: 0,
                             count: pagesUsed) else {
                return nil
            }
            return 0
        }

        let evicted = pagesUsed - preserve
        guard reallocate(newPageCount: preserve, begin: evicted,
                         count: preserve) else {
            return nil
        }
        pageIndex = preserve - 1
        return evicted
    }
}
