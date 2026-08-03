//
//  Nvmm
//  GlyphRasterizer.swift
//
//  Rasterizes text into reusable coverage masks or color bitmaps with
//  CoreText.
//
//  Ordinary text is an alpha-only bitmap, independent of its display colors.
//  CoreText runs backed by a color-glyph font use transparent RGBA instead, so
//  emoji retain their intrinsic colors. Text is shaped as a whole string
//  (usually one grapheme cluster) before either representation is selected.
//

import CoreGraphics
import CoreText
import Foundation

/// Settings that affect the pixels CoreText writes for ordinary text.
nonisolated struct GlyphRasterizationOptions: Hashable, Sendable {
    let thicken: Bool
    let strength: UInt8

    init(thicken: Bool, strength: Int) {
        self.thicken = thicken
        self.strength = thicken ? UInt8(clamping: strength) : 0
    }
}

/// The texture representation required by a rasterized glyph.
nonisolated enum GlyphBitmapFormat: UInt32, Sendable {
    case mask = 0
    case color = 1

    var pixelSize: Int { self == .mask ? 1 : 4 }
}

/// A rasterized glyph: a view into the rasterizer's pixel buffer plus metrics.
/// Valid only until the next call using the same bitmap format.
nonisolated struct GlyphBitmap {
    /// The top-left pixel of the glyph within the rasterizer's buffer.
    let buffer: UnsafeMutablePointer<UInt8>
    /// Bytes per row in the buffer.
    let stride: Int
    let leftBearing: Int16
    let ascent: Int16
    let width: Int16
    let height: Int16
    let format: GlyphBitmapFormat

    var descent: Int16 { ascent - height }
}

/// Rasterizes glyphs at the center of fixed-size alpha and color canvases.
///
/// Each canvas spans from `-width` to `width` and `-height` to `height`;
/// glyphs are drawn at the origin, so the largest representable glyph is twice
/// the width and height passed to `init`.
nonisolated final class GlyphRasterizer {
    private let maskContext: CGContext
    private let colorContext: CGContext
    private let maskBuffer: UnsafeMutablePointer<UInt8>
    private let colorBuffer: UnsafeMutablePointer<UInt8>
    private let midx: Int
    private let midy: Int

    init(width: Int, height: Int) {
        midx = min(width, 4096)
        midy = min(height, 4096)

        let canvasWidth = midx * 2
        let canvasHeight = midy * 2
        maskBuffer = UnsafeMutablePointer<UInt8>.allocate(
            capacity: canvasWidth * canvasHeight)
        colorBuffer = UnsafeMutablePointer<UInt8>.allocate(
            capacity: canvasWidth * canvasHeight * 4)

        let maskSpace = CGColorSpace(name: CGColorSpace.linearGray)!
        maskContext = CGContext(
            data: maskBuffer,
            width: canvasWidth, height: canvasHeight,
            bitsPerComponent: 8, bytesPerRow: canvasWidth,
            space: maskSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.alphaOnly.rawValue))!

        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
        colorContext = CGContext(
            data: colorBuffer,
            width: canvasWidth, height: canvasHeight,
            bitsPerComponent: 8, bytesPerRow: canvasWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

        for context in [maskContext, colorContext] {
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setAllowsFontSmoothing(true)
            context.setAllowsFontSubpixelPositioning(true)
            context.setShouldSubpixelPositionFonts(true)
            context.setAllowsFontSubpixelQuantization(false)
            context.setShouldSubpixelQuantizeFonts(false)
        }
    }

    deinit {
        maskBuffer.deallocate()
        colorBuffer.deallocate()
    }

    /// Rasterizes `text`, selecting a reusable mask unless an actual CoreText
    /// run uses a font capable of color glyphs.
    func rasterize(font: CTFont, foreground: RGBColor, text: String,
                   options: GlyphRasterizationOptions) -> GlyphBitmap {
        let line = makeLine(font: font, text: text)
        let format: GlyphBitmapFormat = lineUsesColorGlyphs(line) ? .color : .mask

        // Pad the metrics to absorb antialiasing, smoothing, and rounding. The
        // constants leave at least the one-pixel expansion used by smoothing.
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let descent = bounds.origin.y - 2
        let ascent = bounds.size.height + bounds.origin.y + 2
        let leftx = bounds.origin.x - 2
        let width = bounds.size.width + 5

        let leftBearing = clampAbs(leftx, limit: CGFloat(midx))
        let ascentPixels = clampAbs(ascent, limit: CGFloat(midy))
        let widthPixels = clampAbs(width, limit: CGFloat(midx) - leftBearing)
        let heightPixels = ascentPixels - clampAbs(descent, limit: CGFloat(midy))

        let leftBearingInt = Int(leftBearing)
        let ascentInt = Int(ascentPixels)
        let widthInt = Int(widthPixels)
        let heightInt = Int(heightPixels)
        let stride = midx * 2 * format.pixelSize
        let col = (midy - ascentInt) * midx * 2
        let row = midx + leftBearingInt
        let origin = (col + row) * format.pixelSize
        let buffer = format == .mask ? maskBuffer : colorBuffer

        var bitmap = GlyphBitmap(
            buffer: buffer + origin,
            stride: stride,
            leftBearing: Int16(leftBearingInt),
            ascent: Int16(ascentInt),
            width: Int16(widthInt),
            height: Int16(heightInt),
            format: format)

        clear(&bitmap)
        let context = format == .mask ? maskContext : colorContext
        context.textPosition = CGPoint(x: midx, y: midy)
        context.setShouldSmoothFonts(options.thicken)
        if format == .mask {
            let gray = CGFloat(options.strength) / 255
            context.setFillColor(gray: gray, alpha: 1)
        } else {
            context.setFillColor(CGColor(
                srgbRed: CGFloat(foreground.red) / 255,
                green: CGFloat(foreground.green) / 255,
                blue: CGFloat(foreground.blue) / 255,
                alpha: 1))
        }
        CTLineDraw(line, context)
        return bitmap
    }

    private func makeLine(font: CTFont, text: String) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        return CTLineCreateWithAttributedString(attributed)
    }

    /// Tests the fonts CoreText actually selected, including fallback runs.
    private func lineUsesColorGlyphs(_ line: CTLine) -> Bool {
        let runs = CTLineGetGlyphRuns(line) as NSArray
        for case let run as CTRun in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName] else { continue }
            let font = value as! CTFont
            if CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) {
                return true
            }
        }
        return false
    }

    /// Clears the bitmap's region before drawing a glyph into a reused canvas.
    private func clear(_ bitmap: inout GlyphBitmap) {
        let rowBytes = Int(bitmap.width) * bitmap.format.pixelSize
        for y in 0..<Int(bitmap.height) {
            memset(bitmap.buffer + y * bitmap.stride, 0, rowBytes)
        }
    }
}

/// Clamps `value` to the range `[-limit, limit]`.
private nonisolated func clampAbs(_ value: CGFloat, limit: CGFloat) -> CGFloat {
    if value > limit { return limit }
    if value < -limit { return -limit }
    return value
}
