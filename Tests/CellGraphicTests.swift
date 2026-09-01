//
//  NvmmTests
//
//  Verifies the host-side cell-graphic wire encoding.
//

import XCTest
@testable import Nvmm

final class CellGraphicTests: XCTestCase {
    private func kind(_ grapheme: String) throws -> UInt32 {
        try XCTUnwrap(CellGraphicKind(
            grapheme: grapheme, nativePowerlineSymbols: true)).rawValue
    }

    private func box(_ up: UInt32, _ right: UInt32,
                     _ down: UInt32, _ left: UInt32) -> UInt32 {
        CELL_GRAPHIC_BOX_SEGMENTS
        | (up << CELL_GRAPHIC_BOX_UP_SHIFT)
        | (right << CELL_GRAPHIC_BOX_RIGHT_SHIFT)
        | (down << CELL_GRAPHIC_BOX_DOWN_SHIFT)
        | (left << CELL_GRAPHIC_BOX_LEFT_SHIFT)
    }

    private func block(_ left: UInt32, _ top: UInt32,
                       _ right: UInt32, _ bottom: UInt32) -> UInt32 {
        CELL_GRAPHIC_BLOCK_RECT
        | (left << CELL_GRAPHIC_BLOCK_LEFT_SHIFT)
        | (top << CELL_GRAPHIC_BLOCK_TOP_SHIFT)
        | (right << CELL_GRAPHIC_BLOCK_RIGHT_SHIFT)
        | (bottom << CELL_GRAPHIC_BLOCK_BOTTOM_SHIFT)
    }

    private func powerline(_ shape: UInt32,
                           mirror: Bool = false) -> UInt32 {
        CELL_GRAPHIC_POWERLINE | shape
        | (mirror ? CELL_GRAPHIC_POWERLINE_MIRROR : 0)
    }

    func testCompleteBoxDrawingBlockUsesNativeGraphics() throws {
        var families: [UInt32: Int] = [:]
        for value in 0x2500...0x257F {
            let grapheme = String(UnicodeScalar(value)!)
            let graphic = try XCTUnwrap(CellGraphicKind(
                grapheme: grapheme, nativePowerlineSymbols: true),
                "U+\(String(value, radix: 16))")
            families[graphic.rawValue & CELL_GRAPHIC_FAMILY_MASK,
                     default: 0] += 1
        }

        XCTAssertEqual(families[CELL_GRAPHIC_BOX_SEGMENTS], 109)
        XCTAssertEqual(families[CELL_GRAPHIC_BOX_DASHED], 12)
        XCTAssertEqual(families[CELL_GRAPHIC_BOX_ARC], 4)
        XCTAssertEqual(families[0], 3)
    }

    func testCompleteBlockElementsRangeUsesNativeGraphics() throws {
        var families: [UInt32: Int] = [:]
        for value in 0x2580...0x259F {
            let grapheme = String(UnicodeScalar(value)!)
            let graphic = try XCTUnwrap(CellGraphicKind(
                grapheme: grapheme, nativePowerlineSymbols: true),
                "U+\(String(value, radix: 16))")
            families[graphic.rawValue & CELL_GRAPHIC_FAMILY_MASK,
                     default: 0] += 1
        }

        XCTAssertEqual(families[CELL_GRAPHIC_BLOCK_RECT], 18)
        XCTAssertEqual(families[CELL_GRAPHIC_BLOCK_QUADRANTS], 10)
        XCTAssertEqual(families[0], 4)
    }

    func testRepresentativeBlockElementEncodings() throws {
        XCTAssertEqual(try kind("▀"), block(0, 0, 8, 4))
        XCTAssertEqual(try kind("▁"), block(0, 7, 8, 8))
        XCTAssertEqual(try kind("▇"), block(0, 1, 8, 8))
        XCTAssertEqual(try kind("▋"), block(0, 0, 5, 8))
        XCTAssertEqual(try kind("▏"), block(0, 0, 1, 8))
        XCTAssertEqual(try kind("▐"), block(4, 0, 8, 8))
        XCTAssertEqual(try kind("▔"), block(0, 0, 8, 1))
        XCTAssertEqual(try kind("▕"), block(7, 0, 8, 8))

        XCTAssertEqual(try kind("█"), CELL_GRAPHIC_FULL_BLOCK)
        XCTAssertEqual(try kind("░"), CELL_GRAPHIC_LIGHT_SHADE)
        XCTAssertEqual(try kind("▒"), CELL_GRAPHIC_MEDIUM_SHADE)
        XCTAssertEqual(try kind("▓"), CELL_GRAPHIC_DARK_SHADE)

        XCTAssertEqual(try kind("▖"), CELL_GRAPHIC_BLOCK_QUADRANTS
                       | CELL_GRAPHIC_QUADRANT_BOTTOM_LEFT)
        XCTAssertEqual(try kind("▚"), CELL_GRAPHIC_BLOCK_QUADRANTS
                       | CELL_GRAPHIC_QUADRANT_TOP_LEFT
                       | CELL_GRAPHIC_QUADRANT_BOTTOM_RIGHT)
        XCTAssertEqual(try kind("▟"), CELL_GRAPHIC_BLOCK_QUADRANTS
                       | CELL_GRAPHIC_QUADRANT_TOP_RIGHT
                       | CELL_GRAPHIC_QUADRANT_BOTTOM_LEFT
                       | CELL_GRAPHIC_QUADRANT_BOTTOM_RIGHT)
    }

    func testCompletePowerlineSetUsesNativeGraphics() throws {
        let values = Array(0xE0B0...0xE0BF)
            + [0xE0D2, 0xE0D4, 0xE0D6, 0xE0D7]
        var families: [UInt32: Int] = [:]
        for value in values {
            let grapheme = String(UnicodeScalar(value)!)
            let graphic = try XCTUnwrap(CellGraphicKind(
                grapheme: grapheme, nativePowerlineSymbols: true),
                "U+\(String(value, radix: 16))")
            families[graphic.rawValue & CELL_GRAPHIC_FAMILY_MASK,
                     default: 0] += 1
            XCTAssertNil(CellGraphicKind(
                grapheme: grapheme, nativePowerlineSymbols: false))
        }

        XCTAssertEqual(families[CELL_GRAPHIC_POWERLINE], 16)
        XCTAssertEqual(families[0], 4)

        let supported = Set(values)
        for value in 0xE0B0...0xE0D7 {
            let grapheme = String(UnicodeScalar(value)!)
            XCTAssertEqual(CellGraphicKind(
                grapheme: grapheme,
                nativePowerlineSymbols: true) != nil,
                           supported.contains(value),
                           "U+\(String(value, radix: 16))")
        }
    }

    func testRepresentativePowerlineEncodings() throws {
        XCTAssertEqual(try kind(""),
                       powerline(CELL_GRAPHIC_POWERLINE_WEDGE))
        XCTAssertEqual(try kind(""),
                       powerline(CELL_GRAPHIC_POWERLINE_CHEVRON,
                                 mirror: true))
        XCTAssertEqual(try kind(""),
                       powerline(CELL_GRAPHIC_POWERLINE_ROUNDED_OUTLINE))
        XCTAssertEqual(try kind(""),
                       powerline(CELL_GRAPHIC_POWERLINE_CORNER_BOTTOM,
                                 mirror: true))
        XCTAssertEqual(try kind(""), CELL_GRAPHIC_DIAGONAL_DOWN_RIGHT)
        XCTAssertEqual(try kind(""), CELL_GRAPHIC_DIAGONAL_DOWN_LEFT)
        XCTAssertEqual(try kind(""),
                       powerline(CELL_GRAPHIC_POWERLINE_TRAPEZOID,
                                 mirror: true))
        XCTAssertEqual(try kind(""),
                       powerline(CELL_GRAPHIC_POWERLINE_TRIANGLES))
    }

    func testRepresentativeDirectionalEncodings() throws {
        let none = CELL_GRAPHIC_STROKE_NONE
        let light = CELL_GRAPHIC_STROKE_LIGHT
        let heavy = CELL_GRAPHIC_STROKE_HEAVY
        let double = CELL_GRAPHIC_STROKE_DOUBLE

        XCTAssertEqual(try kind("─"), box(none, light, none, light))
        XCTAssertEqual(try kind("│"), box(light, none, light, none))
        XCTAssertEqual(try kind("┌"), box(none, light, light, none))
        XCTAssertEqual(try kind("┼"), box(light, light, light, light))
        XCTAssertEqual(try kind("╋"), box(heavy, heavy, heavy, heavy))
        XCTAssertEqual(try kind("═"), box(none, double, none, double))
        XCTAssertEqual(try kind("║"), box(double, none, double, none))
        XCTAssertEqual(try kind("╔"), box(none, double, double, none))
        XCTAssertEqual(try kind("╬"), box(double, double, double, double))
        XCTAssertEqual(try kind("╪"), box(light, double, light, double))
        XCTAssertEqual(try kind("╫"), box(double, light, double, light))
        XCTAssertEqual(try kind("╽"), box(light, none, heavy, none))
        XCTAssertEqual(try kind("╾"), box(none, light, none, heavy))
    }

    func testSpecializedBoxDrawingFamilies() throws {
        XCTAssertEqual(try kind("╭"),
                       CELL_GRAPHIC_BOX_ARC | CELL_GRAPHIC_ARC_DOWN_RIGHT)
        XCTAssertEqual(try kind("╮"),
                       CELL_GRAPHIC_BOX_ARC | CELL_GRAPHIC_ARC_DOWN_LEFT)
        XCTAssertEqual(try kind("╯"),
                       CELL_GRAPHIC_BOX_ARC | CELL_GRAPHIC_ARC_UP_LEFT)
        XCTAssertEqual(try kind("╰"),
                       CELL_GRAPHIC_BOX_ARC | CELL_GRAPHIC_ARC_UP_RIGHT)
        XCTAssertEqual(try kind("╱"), CELL_GRAPHIC_DIAGONAL_DOWN_LEFT)
        XCTAssertEqual(try kind("╲"), CELL_GRAPHIC_DIAGONAL_DOWN_RIGHT)
        XCTAssertEqual(try kind("╳"), CELL_GRAPHIC_DIAGONAL_CROSS)

        XCTAssertEqual(try kind("╌"), CELL_GRAPHIC_BOX_DASHED)
        XCTAssertEqual(try kind("╏"), CELL_GRAPHIC_BOX_DASHED
                       | CELL_GRAPHIC_DASH_VERTICAL
                       | CELL_GRAPHIC_DASH_HEAVY)
    }

    func testUnrelatedGraphemesRemainFontRendered() {
        XCTAssertNil(CellGraphicKind(
            grapheme: "A", nativePowerlineSymbols: true))
        XCTAssertNil(CellGraphicKind(
            grapheme: "🙂", nativePowerlineSymbols: true))
        XCTAssertNil(CellGraphicKind(
            grapheme: "ab", nativePowerlineSymbols: true))
    }
}
