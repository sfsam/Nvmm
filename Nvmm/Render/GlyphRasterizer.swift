//
//  Nvmm
//  GlyphRasterizer.swift
//
//  Rasterizes text into RGBA bitmaps with CoreText.
//
//  Text is rasterized as whole strings (usually one grapheme cluster), so the
//  rasterizer also performs Unicode shaping. Output is premultiplied-alpha RGBA
//  in the sRGB colorspace, drawn over the cell's background color rather than
//  as an alpha mask: CoreText dilates glyphs differently per foreground and
//  background pair, and that dilation is lost in an alpha-only context.
//

import CoreGraphics
import CoreText
import Foundation

/// A rasterized glyph: a view into the rasterizer's pixel buffer plus metrics.
/// Valid only until the next `rasterize` call on the same rasterizer.
nonisolated struct GlyphBitmap {
    /// The top-left pixel of the glyph within the rasterizer's buffer.
    let buffer: UnsafeMutablePointer<UInt8>
    /// Bytes per row in the buffer.
    let stride: Int
    let leftBearing: Int16
    let ascent: Int16
    let width: Int16
    let height: Int16

    var descent: Int16 { ascent - height }
}

/// Rasterizes glyphs at the center of a fixed-size canvas.
///
/// The canvas spans from `-width` to `width` and `-height` to `height`; glyphs
/// are drawn at the origin, so the largest representable glyph is twice the
/// width and height passed to `init`.
nonisolated final class GlyphRasterizer {
    static let pixelSize = 4

    private let context: CGContext
    private let buffer: UnsafeMutablePointer<UInt8>
    private let midx: Int
    private let midy: Int

    init(width: Int, height: Int) {
        midx = min(width, 4096)
        midy = min(height, 4096)

        let canvasWidth = midx * 2
        let canvasHeight = midy * 2
        let bytesPerRow = canvasWidth * Self.pixelSize

        buffer = UnsafeMutablePointer<UInt8>.allocate(
            capacity: bytesPerRow * canvasHeight)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        context = CGContext(
            data: buffer,
            width: canvasWidth, height: canvasHeight,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(true)
        context.setShouldSmoothFonts(true)
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        context.setAllowsFontSubpixelQuantization(true)
        context.setShouldSubpixelQuantizeFonts(true)
    }

    deinit { buffer.deallocate() }

    /// Bytes per row for bitmaps this rasterizer produces.
    var stride: Int { midx * 2 * Self.pixelSize }

    /// Rasterizes `text` in `font`, over `background`, in `foreground`.
    func rasterize(font: CTFont, background: RGBColor, foreground: RGBColor,
                   text: String) -> GlyphBitmap {
        context.textPosition = CGPoint(x: midx, y: midy)
        let line = makeLine(font: font, foreground: foreground, text: text)

        // Pad the metrics to absorb antialiasing and float-to-int rounding. The
        // constants were tuned empirically.
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

        let col = (midy - ascentInt) * midx * 2
        let row = midx + leftBearingInt
        let origin = (col + row) * Self.pixelSize

        var bitmap = GlyphBitmap(
            buffer: buffer + origin,
            stride: stride,
            leftBearing: Int16(leftBearingInt),
            ascent: Int16(ascentInt),
            width: Int16(widthInt),
            height: Int16(heightInt))

        clear(&bitmap, pixel: background.opaque)
        CTLineDraw(line, context)
        return bitmap
    }

    private func makeLine(font: CTFont, foreground: RGBColor,
                          text: String) -> CTLine {
        let color = CGColor(srgbRed: CGFloat(foreground.red) / 255,
                            green: CGFloat(foreground.green) / 255,
                            blue: CGFloat(foreground.blue) / 255, alpha: 1)

        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color,
        ]

        let attributed = NSAttributedString(string: text, attributes: attributes)
        return CTLineCreateWithAttributedString(attributed)
    }

    /// Fills the bitmap's region with a solid pixel before drawing the glyph.
    private func clear(_ bitmap: inout GlyphBitmap, pixel: UInt32) {
        var value = pixel
        let rowBytes = Int(bitmap.width) * Self.pixelSize
        for y in 0..<Int(bitmap.height) {
            let rowStart = bitmap.buffer + y * bitmap.stride
            var x = 0
            while x < rowBytes {
                withUnsafeBytes(of: &value) { src in
                    (rowStart + x).update(from: src.bindMemory(to: UInt8.self).baseAddress!,
                                          count: Self.pixelSize)
                }
                x += Self.pixelSize
            }
        }
    }
}

/// Clamps `value` to the range `[-limit, limit]`.
private nonisolated func clampAbs(_ value: CGFloat, limit: CGFloat) -> CGFloat {
    if value > limit { return limit }
    if value < -limit { return -limit }
    return value
}
