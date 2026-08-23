//
//  Nvmm
//  RenderContext.swift
//
//  Per-device Metal render state.
//
//  A render context owns the Metal objects tied to one GPU: the command queue,
//  the six render pipelines, and a glyph manager (glyphs live in that GPU's
//  textures, so they are device-specific). The font manager, rasterizer, and
//  ligature shaper are shared across devices and owned by the manager. Create
//  contexts through a `RenderContextManager`, which maps each Metal device to
//  one context.
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
    var cacheMaximumPages = 8
    var cacheEvictionPreserve = 2
}

/// The Metal device state and glyph cache used to render a grid.
final class RenderContext {
    static let outputPixelFormat: MTLPixelFormat = .bgra8Unorm

    static var outputColorSpace: CGColorSpace {
        CGColorSpace(name: CGColorSpace.displayP3)!
    }

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let backgroundPipeline: MTLRenderPipelineState
    let glyphPipeline: MTLRenderPipelineState
    let cellGraphicPipeline: MTLRenderPipelineState
    let cursorPipeline: MTLRenderPipelineState
    let cursorSmearPipeline: MTLRenderPipelineState
    let linePipeline: MTLRenderPipelineState
    let fontManager: FontManager
    let ligatureShaper: LigatureShaper
    let glyphManager: GlyphManager

    init(device: MTLDevice, fontManager: FontManager,
         rasterizer: GlyphRasterizer, ligatureShaper: LigatureShaper,
         options: RenderContextOptions,
         glyphOptions: GlyphRasterizationOptions) throws {
        self.device = device
        self.fontManager = fontManager
        self.ligatureShaper = ligatureShaper
        guard let queue = device.makeCommandQueue() else {
            throw RenderContextError.commandQueueUnavailable
        }
        commandQueue = queue

        let library = try device.makeDefaultLibrary(bundle: .main)

        backgroundPipeline = try Self.pipeline(
            device: device, library: library, blend: .none,
            vertex: "background_render", fragment: "background_fill",
            label: "Grid background render pipeline")
        glyphPipeline = try Self.pipeline(
            device: device, library: library, blend: .premultiplied,
            vertex: "glyph_render", fragment: "glyph_fill",
            label: "Glyph render pipeline")
        cellGraphicPipeline = try Self.pipeline(
            device: device, library: library, blend: .straight,
            vertex: "cell_graphic_render", fragment: "cell_graphic_fill",
            label: "Cell graphic render pipeline")
        cursorPipeline = try Self.pipeline(
            device: device, library: library, blend: .straight,
            vertex: "cursor_render", fragment: "background_fill",
            label: "Cursor render pipeline")
        cursorSmearPipeline = try Self.pipeline(
            device: device, library: library, blend: .straight,
            vertex: "cursor_smear_render", fragment: "cursor_smear_fill",
            label: "Cursor smear render pipeline")
        linePipeline = try Self.pipeline(
            device: device, library: library, blend: .straight,
            vertex: "line_render", fragment: "line_fill",
            label: "Line render pipeline")

        guard let maskCache = GlyphTextureCache(
            queue: queue,
            pixelFormat: .r8Unorm,
            pageWidth: options.cachePageWidth,
            pageHeight: options.cachePageHeight,
            initialCapacity: options.cacheInitialCapacity,
            growthFactor: options.cacheGrowthFactor,
            maximumPages: options.cacheMaximumPages) else {
            throw RenderContextError.glyphTextureUnavailable
        }
        guard let colorCache = GlyphTextureCache(
            queue: queue,
            pixelFormat: .rgba8Unorm,
            pageWidth: options.cachePageWidth,
            pageHeight: options.cachePageHeight,
            initialCapacity: options.cacheInitialCapacity,
            growthFactor: options.cacheGrowthFactor,
            maximumPages: options.cacheMaximumPages) else {
            throw RenderContextError.glyphTextureUnavailable
        }

        glyphManager = GlyphManager(
            rasterizer: rasterizer, maskCache: maskCache,
            colorCache: colorCache,
            evictPreserve: options.cacheEvictionPreserve,
            options: glyphOptions)
    }

    // Nonisolated so teardown skips the isolated-deinit executor hop that trips
    // a libmalloc double-free under XCTest's post-test memory checker.
    nonisolated deinit {}

    private enum BlendMode: Equatable { case none, straight, premultiplied }

    private static func pipeline(device: MTLDevice, library: MTLLibrary,
                                 blend: BlendMode, vertex: String, fragment: String,
                                 label: String) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.colorAttachments[0].pixelFormat = outputPixelFormat
        descriptor.vertexBuffers[0].mutability = .immutable
        descriptor.fragmentBuffers[0].mutability = .immutable
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)

        if blend != .none {
            let attachment = descriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            let source: MTLBlendFactor =
                blend == .premultiplied ? .one : .sourceAlpha
            attachment.sourceRGBBlendFactor = source
            attachment.sourceAlphaBlendFactor = source
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}

enum RenderContextError: Error {
    case commandQueueUnavailable
    case glyphTextureUnavailable
    case metalUnavailable
}

/// Creates and caches one render context per Metal device.
///
/// All contexts share a font manager, glyph rasterizer, and ligature shaper so
/// that fonts, rasterization, and shaping work are reused across GPUs. Contexts
/// are created lazily and kept for the manager's lifetime.
final class RenderContextManager {
    let fontManager = FontManager()
    let ligatureShaper = LigatureShaper()
    private let rasterizer: GlyphRasterizer
    private let options: RenderContextOptions
    private var contexts: [ObjectIdentifier: RenderContext] = [:]
    private var glyphOptions: GlyphRasterizationOptions?

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
        let options = currentGlyphOptions()
        _ = applyGlyphOptions(options)
        let key = ObjectIdentifier(device)
        if let existing = contexts[key] { return existing }
        let context = try RenderContext(device: device, fontManager: fontManager,
                                        rasterizer: rasterizer,
                                        ligatureShaper: ligatureShaper,
                                        options: self.options,
                                        glyphOptions: options)
        contexts[key] = context
        return context
    }

    /// Applies the app-wide text-rasterization settings to every GPU cache.
    @discardableResult
    func applyFontRasterizationSettings() -> Bool {
        applyGlyphOptions(currentGlyphOptions())
    }

    private func currentGlyphOptions() -> GlyphRasterizationOptions {
        let thickness = Settings.fontThickness
        return GlyphRasterizationOptions(
            thicken: thickness > 0,
            strength: thickness)
    }

    private func applyGlyphOptions(_ options: GlyphRasterizationOptions) -> Bool {
        guard options != glyphOptions else { return false }
        glyphOptions = options
        for context in contexts.values { context.glyphManager.update(options: options) }
        return true
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
