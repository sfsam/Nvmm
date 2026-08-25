//
//  NvmmTests
//
//  Verifies the host-side cell-graphic wire encoding.
//

import XCTest
@testable import Nvmm

final class CellGraphicTests: XCTestCase {
    private func kind(_ grapheme: String) throws -> UInt32 {
        try XCTUnwrap(CellGraphicKind(grapheme: grapheme)).rawValue
    }

    private func box(_ up: UInt32, _ right: UInt32,
                     _ down: UInt32, _ left: UInt32) -> UInt32 {
        CELL_GRAPHIC_BOX_SEGMENTS
        | (up << CELL_GRAPHIC_BOX_UP_SHIFT)
        | (right << CELL_GRAPHIC_BOX_RIGHT_SHIFT)
        | (down << CELL_GRAPHIC_BOX_DOWN_SHIFT)
        | (left << CELL_GRAPHIC_BOX_LEFT_SHIFT)
    }

    func testCompleteBoxDrawingBlockUsesNativeGraphics() throws {
        var families: [UInt32: Int] = [:]
        for value in 0x2500...0x257F {
            let grapheme = String(UnicodeScalar(value)!)
            let graphic = try XCTUnwrap(CellGraphicKind(grapheme: grapheme),
                                        "U+\(String(value, radix: 16))")
            families[graphic.rawValue & CELL_GRAPHIC_FAMILY_MASK,
                     default: 0] += 1
        }

        XCTAssertEqual(families[CELL_GRAPHIC_BOX_SEGMENTS], 109)
        XCTAssertEqual(families[CELL_GRAPHIC_BOX_DASHED], 12)
        XCTAssertEqual(families[CELL_GRAPHIC_BOX_ARC], 4)
        XCTAssertEqual(families[0], 3)
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
        XCTAssertNil(CellGraphicKind(grapheme: "A"))
        XCTAssertNil(CellGraphicKind(grapheme: "🙂"))
        XCTAssertNil(CellGraphicKind(grapheme: "ab"))
    }
}
