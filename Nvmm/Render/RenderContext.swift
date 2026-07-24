//
//  Nvmm
//  RenderContext.swift
//
//  Per-device Metal render state.
//
//  A render context owns the Metal objects tied to one GPU: the command queue,
//  the five render pipelines, and a glyph manager (glyphs live in that GPU's
//  textures, so they are device-specific). The font manager and rasterizer are
//  shared across devices and owned by the manager. Create contexts through a
//  `RenderContextManager`, which maps each Metal device to one context.
//

import AppKit
import Metal

/// Tuning parameters for a render context and the caches it creates.
struct RenderContextOptions {
    var rasterizerWidth = 512
    var rasterizerHeight = 512
    var cachePageWidth = 1024
    var cachePageHeight = 1024
    var cacheInitialCapacity = 1
    var cacheGrowthFactor = 1.5
    var cacheEvictionThreshold = 8
    var cacheEvictionPreserve = 2
}

/// The Metal device state and glyph cache used to render a grid.
final class RenderContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let backgroundPipeline: MTLRenderPipelineState
    let glyphPipeline: MTLRenderPipelineState
    let cellGraphicPipeline: MTLRenderPipelineState
    let cursorPipeline: MTLRenderPipelineState
    let linePipeline: MTLRenderPipelineState
    let fontManager: FontManager
    let glyphManager: GlyphManager

    init(device: MTLDevice, fontManager: FontManager,
         rasterizer: GlyphRasterizer, options: RenderContextOptions) throws {
        self.device = device
        self.fontManager = fontManager
        guard let queue = device.makeCommandQueue() else {
            throw RenderContextError.commandQueueUnavailable
        }
        commandQueue = queue

        let library = try device.makeDefaultLibrary(bundle: .main)

        backgroundPipeline = try Self.pipeline(
            device: device, library: library, blended: false,
            vertex: "background_render", fragment: "background_fill",
            label: "Grid background render pipeline")
        glyphPipeline = try Self.pipeline(
            device: device, library: library, blended: false,
            vertex: "glyph_render", fragment: "glyph_fill",
            label: "Glyph render pipeline")
        cellGraphicPipeline = try Self.pipeline(
            device: device, library: library, blended: true,
            vertex: "cell_graphic_render", fragment: "cell_graphic_fill",
            label: "Cell graphic render pipeline")
        cursorPipeline = try Self.pipeline(
            device: device, library: library, blended: false,
            vertex: "cursor_render", fragment: "background_fill",
            label: "Cursor render pipeline")
        linePipeline = try Self.pipeline(
            device: device, library: library, blended: true,
            vertex: "line_render", fragment: "line_fill",
            label: "Line render pipeline")

        let textureCache = GlyphTextureCache(
            queue: queue,
            pageWidth: options.cachePageWidth,
            pageHeight: options.cachePageHeight,
            initialCapacity: options.cacheInitialCapacity,
            growthFactor: options.cacheGrowthFactor)

        glyphManager = GlyphManager(
            rasterizer: rasterizer, textureCache: textureCache,
            evictThreshold: options.cacheEvictionThreshold,
            evictPreserve: options.cacheEvictionPreserve)
    }

    // Nonisolated so teardown skips the isolated-deinit executor hop that trips
    // a libmalloc double-free under XCTest's post-test memory checker.
    nonisolated deinit {}

    private static func pipeline(device: MTLDevice, library: MTLLibrary,
                                 blended: Bool, vertex: String, fragment: String,
                                 label: String) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        descriptor.vertexBuffers[0].mutability = .immutable
        descriptor.fragmentBuffers[0].mutability = .immutable
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)

        if blended {
            let attachment = descriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.sourceAlphaBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}

enum RenderContextError: Error {
    case commandQueueUnavailable
    case metalUnavailable
}

/// Creates and caches one render context per Metal device.
///
/// All contexts share a font manager and glyph rasterizer so that fonts and
/// rasterization work are reused across GPUs. Contexts are created lazily and
/// kept for the manager's lifetime.
final class RenderContextManager {
    let fontManager = FontManager()
    private let rasterizer: GlyphRasterizer
    private let options: RenderContextOptions
    private var contexts: [ObjectIdentifier: RenderContext] = [:]

    init(options: RenderContextOptions = RenderContextOptions()) {
        self.options = options
        rasterizer = GlyphRasterizer(width: options.rasterizerWidth,
                                     height: options.rasterizerHeight)
    }

    // Nonisolated so teardown skips the isolated-deinit executor hop that trips
    // a libmalloc double-free under XCTest's post-test memory checker.
    nonisolated deinit {}

    /// The render context for a device, creating one on first use.
    func renderContext(for device: MTLDevice) throws -> RenderContext {
        let key = ObjectIdentifier(device)
        if let existing = contexts[key] { return existing }
        let context = try RenderContext(device: device, fontManager: fontManager,
                                        rasterizer: rasterizer, options: options)
        contexts[key] = context
        return context
    }

    /// The best render context for a screen: the device currently driving it.
    func renderContext(for screen: NSScreen) throws -> RenderContext {
        if let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber {
            let displayID = CGDirectDisplayID(number.uint32Value)
            if let device = CGDirectDisplayCopyCurrentMetalDevice(displayID) {
                return try renderContext(for: device)
            }
        }
        return try defaultRenderContext()
    }

    /// A render context for the system default Metal device.
    func defaultRenderContext() throws -> RenderContext {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RenderContextError.metalUnavailable
        }
        return try renderContext(for: device)
    }
}
