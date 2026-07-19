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
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private(set) var texture: MTLTexture
    private let growthFactor: Double

    private var pageCount: Int
    private var pageIndex: Int
    private let xSize: Int
    private let ySize: Int
    private var xUsed: Int
    private var yUsed: Int
    private var rowHeight: Int

    init(queue: MTLCommandQueue, pageWidth: Int, pageHeight: Int,
         initialCapacity: Int, growthFactor: Double) {
        self.device = queue.device
        self.queue = queue
        self.growthFactor = growthFactor
        xUsed = 0
        yUsed = 0
        xSize = pageWidth
        ySize = pageHeight
        rowHeight = 0
        pageIndex = 0
        pageCount = max(1, initialCapacity)
        texture = Self.allocTexture(device: device, width: pageWidth,
                                    height: pageHeight, length: pageCount)
    }

    /// The number of cache pages currently allocated.
    var pagesCapacity: Int { pageCount }

    /// The number of cache pages in use.
    var pagesSize: Int { pageIndex }

    private static func allocTexture(device: MTLDevice, width: Int, height: Int,
                                     length: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.arrayLength = length
        descriptor.pixelFormat = .rgba8Unorm_srgb
        descriptor.width = width
        descriptor.height = height
        descriptor.mipmapLevelCount = 1
        return device.makeTexture(descriptor: descriptor)!
    }

    /// Copies pages `[begin, begin + count)` into a freshly sized texture.
    private func reallocate(newPageCount: Int, begin: Int, count: Int) {
        let newTexture = Self.allocTexture(device: device, width: xSize,
                                           height: ySize, length: newPageCount)
        let commandBuffer = queue.makeCommandBuffer()!
        let blit = commandBuffer.makeBlitCommandEncoder()!
        blit.copy(from: texture, sourceSlice: begin, sourceLevel: 0,
                  to: newTexture, destinationSlice: 0, destinationLevel: 0,
                  sliceCount: count, levelCount: 1)
        blit.endEncoding()
        commandBuffer.commit()

        texture = newTexture
        pageCount = newPageCount
    }

    private func replace(region: MTLRegion, slice: Int, bitmap: GlyphBitmap) {
        texture.replace(region: region, mipmapLevel: 0, slice: slice,
                        withBytes: bitmap.buffer, bytesPerRow: bitmap.stride,
                        bytesPerImage: 0)
    }

    /// Starts a new page for the bitmap, growing the page array if needed.
    private func addNewPage(_ bitmap: GlyphBitmap) -> simd_short3 {
        pageIndex += 1

        if pageIndex >= pageCount {
            let grown = Int((Double(pageCount) * growthFactor).rounded(.up))
            reallocate(newPageCount: max(pageIndex, grown), begin: 0,
                       count: pageCount)
        }

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
    func add(_ bitmap: GlyphBitmap) -> simd_short3 {
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
    /// glyph manager uses to shift cached page indices), or 0 if none were.
    func evict(preserve: Int) -> Int {
        if preserve == 0 {
            texture = Self.allocTexture(device: device, width: xSize,
                                        height: ySize, length: 1)
            pageCount = 1
            pageIndex = 0
            xUsed = 0
            yUsed = 0
            return 0
        }

        if preserve < pageIndex {
            let begin = pageIndex - preserve + 1
            reallocate(newPageCount: preserve, begin: begin, count: preserve)
            pageIndex = preserve - 1
            return begin
        }

        if preserve > pageIndex {
            reallocate(newPageCount: pageIndex, begin: 0, count: pageIndex)
            return 0
        }

        return 0
    }
}
