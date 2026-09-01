//
//  Nvmm
//  CellGraphic.swift
//
//  Maps graphemes to the compact wire values consumed by the cell-graphics
//  shader.
//

import Foundation

/// One procedural cell graphic encoded for the Metal shader.
nonisolated struct CellGraphicKind: Equatable {
    let rawValue: UInt32

    private init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    static let fullBlock = Self(rawValue: CELL_GRAPHIC_FULL_BLOCK)

    private struct Stroke {
        let rawValue: UInt32

        static let none = Self(rawValue: CELL_GRAPHIC_STROKE_NONE)
        static let light = Self(rawValue: CELL_GRAPHIC_STROKE_LIGHT)
        static let heavy = Self(rawValue: CELL_GRAPHIC_STROKE_HEAVY)
        static let double = Self(rawValue: CELL_GRAPHIC_STROKE_DOUBLE)
    }

    private static func box(_ up: Stroke, _ right: Stroke,
                            _ down: Stroke, _ left: Stroke) -> Self {
        Self(rawValue: CELL_GRAPHIC_BOX_SEGMENTS
             | (up.rawValue << CELL_GRAPHIC_BOX_UP_SHIFT)
             | (right.rawValue << CELL_GRAPHIC_BOX_RIGHT_SHIFT)
             | (down.rawValue << CELL_GRAPHIC_BOX_DOWN_SHIFT)
             | (left.rawValue << CELL_GRAPHIC_BOX_LEFT_SHIFT))
    }

    private static func dashed(vertical: Bool, heavy: Bool,
                               count: UInt32) -> Self {
        let orientation = vertical ? CELL_GRAPHIC_DASH_VERTICAL : 0
        let weight = heavy ? CELL_GRAPHIC_DASH_HEAVY : 0
        return Self(rawValue: CELL_GRAPHIC_BOX_DASHED | orientation | weight
                    | ((count - 2) << CELL_GRAPHIC_DASH_COUNT_SHIFT))
    }

    private static func arc(_ corner: UInt32) -> Self {
        Self(rawValue: CELL_GRAPHIC_BOX_ARC | corner)
    }

    private static func block(_ left: UInt32, _ top: UInt32,
                              _ right: UInt32, _ bottom: UInt32) -> Self {
        Self(rawValue: CELL_GRAPHIC_BLOCK_RECT
             | (left << CELL_GRAPHIC_BLOCK_LEFT_SHIFT)
             | (top << CELL_GRAPHIC_BLOCK_TOP_SHIFT)
             | (right << CELL_GRAPHIC_BLOCK_RIGHT_SHIFT)
             | (bottom << CELL_GRAPHIC_BLOCK_BOTTOM_SHIFT))
    }

    private static func quadrants(_ mask: UInt32) -> Self {
        Self(rawValue: CELL_GRAPHIC_BLOCK_QUADRANTS | mask)
    }

    private static func blockElement(_ codepoint: UInt32) -> Self? {
        switch codepoint {
        case 0x2580: return Self.block(0, 0, 8, 4)
        case 0x2581...0x2587:
            return Self.block(0, 8 - (codepoint - 0x2580), 8, 8)
        // Full block also serves internal full-cell fills. Shades blend the
        // foreground and background instead of describing solid geometry.
        case 0x2588: return Self(rawValue: CELL_GRAPHIC_FULL_BLOCK)
        case 0x2589...0x258F:
            return Self.block(0, 0, 0x2590 - codepoint, 8)
        case 0x2590: return Self.block(4, 0, 8, 8)
        case 0x2591: return Self(rawValue: CELL_GRAPHIC_LIGHT_SHADE)
        case 0x2592: return Self(rawValue: CELL_GRAPHIC_MEDIUM_SHADE)
        case 0x2593: return Self(rawValue: CELL_GRAPHIC_DARK_SHADE)
        case 0x2594: return Self.block(0, 0, 8, 1)
        case 0x2595: return Self.block(7, 0, 8, 8)
        case 0x2596:
            return Self.quadrants(CELL_GRAPHIC_QUADRANT_BOTTOM_LEFT)
        case 0x2597:
            return Self.quadrants(CELL_GRAPHIC_QUADRANT_BOTTOM_RIGHT)
        case 0x2598:
            return Self.quadrants(CELL_GRAPHIC_QUADRANT_TOP_LEFT)
        case 0x2599:
            return Self.quadrants(CELL_GRAPHIC_QUADRANT_TOP_LEFT
                                  | CELL_GRAPHIC_QUADRANT_BOTTOM_LEFT
                                  | CELL_GRAPHIC_QUADRANT_BOTTOM_RIGHT)
        case 0x259A:
            return Self.quadrants(CELL_GRAPHIC_QUADRANT_TOP_LEFT
                                  | CELL_GRAPHIC_QUADRANT_BOTTOM_RIGHT)
        case 0x259B:
            return Self.quadrants(CELL_GRAPHIC_QUADRANT_TOP_LEFT
                                  | CELL_GRAPHIC_QUADRANT_TOP_RIGHT
                                  | CELL_GRAPHIC_QUADRANT_BOTTOM_LEFT)
        case 0x259C:
            return Self.quadrants(CELL_GRAPHIC_QUADRANT_TOP_LEFT
                                  | CELL_GRAPHIC_QUADRANT_TOP_RIGHT
                                  | CELL_GRAPHIC_QUADRANT_BOTTOM_RIGHT)
        case 0x259D:
            return Self.quadrants(CELL_GRAPHIC_QUADRANT_TOP_RIGHT)
        case 0x259E:
            return Self.quadrants(CELL_GRAPHIC_QUADRANT_TOP_RIGHT
                                  | CELL_GRAPHIC_QUADRANT_BOTTOM_LEFT)
        case 0x259F:
            return Self.quadrants(CELL_GRAPHIC_QUADRANT_TOP_RIGHT
                                  | CELL_GRAPHIC_QUADRANT_BOTTOM_LEFT
                                  | CELL_GRAPHIC_QUADRANT_BOTTOM_RIGHT)
        default: return nil
        }
    }

    /// The kind a grapheme maps to, or nil if it is not a cell graphic.
    init?(grapheme: String) {
        // This runs for every cell of every frame, so reject the common
        // case in one pass: a lone scalar at or above the first graphic.
        var scalars = grapheme.unicodeScalars.makeIterator()
        guard let scalar = scalars.next(), scalars.next() == nil,
              scalar.value >= 0x2500 else {
            return nil
        }
        let codepoint = scalar.value

        if let block = Self.blockElement(codepoint) {
            self = block
            return
        }

        switch codepoint {
        case 0x2500: self = Self.box(.none, .light, .none, .light)
        case 0x2501: self = Self.box(.none, .heavy, .none, .heavy)
        case 0x2502: self = Self.box(.light, .none, .light, .none)
        case 0x2503: self = Self.box(.heavy, .none, .heavy, .none)
        case 0x2504: self = Self.dashed(vertical: false, heavy: false, count: 3)
        case 0x2505: self = Self.dashed(vertical: false, heavy: true, count: 3)
        case 0x2506: self = Self.dashed(vertical: true, heavy: false, count: 3)
        case 0x2507: self = Self.dashed(vertical: true, heavy: true, count: 3)
        case 0x2508: self = Self.dashed(vertical: false, heavy: false, count: 4)
        case 0x2509: self = Self.dashed(vertical: false, heavy: true, count: 4)
        case 0x250A: self = Self.dashed(vertical: true, heavy: false, count: 4)
        case 0x250B: self = Self.dashed(vertical: true, heavy: true, count: 4)
        case 0x250C: self = Self.box(.none, .light, .light, .none)
        case 0x250D: self = Self.box(.none, .heavy, .light, .none)
        case 0x250E: self = Self.box(.none, .light, .heavy, .none)
        case 0x250F: self = Self.box(.none, .heavy, .heavy, .none)
        case 0x2510: self = Self.box(.none, .none, .light, .light)
        case 0x2511: self = Self.box(.none, .none, .light, .heavy)
        case 0x2512: self = Self.box(.none, .none, .heavy, .light)
        case 0x2513: self = Self.box(.none, .none, .heavy, .heavy)
        case 0x2514: self = Self.box(.light, .light, .none, .none)
        case 0x2515: self = Self.box(.light, .heavy, .none, .none)
        case 0x2516: self = Self.box(.heavy, .light, .none, .none)
        case 0x2517: self = Self.box(.heavy, .heavy, .none, .none)
        case 0x2518: self = Self.box(.light, .none, .none, .light)
        case 0x2519: self = Self.box(.light, .none, .none, .heavy)
        case 0x251A: self = Self.box(.heavy, .none, .none, .light)
        case 0x251B: self = Self.box(.heavy, .none, .none, .heavy)
        case 0x251C: self = Self.box(.light, .light, .light, .none)
        case 0x251D: self = Self.box(.light, .heavy, .light, .none)
        case 0x251E: self = Self.box(.heavy, .light, .light, .none)
        case 0x251F: self = Self.box(.light, .light, .heavy, .none)
        case 0x2520: self = Self.box(.heavy, .light, .heavy, .none)
        case 0x2521: self = Self.box(.heavy, .heavy, .light, .none)
        case 0x2522: self = Self.box(.light, .heavy, .heavy, .none)
        case 0x2523: self = Self.box(.heavy, .heavy, .heavy, .none)
        case 0x2524: self = Self.box(.light, .none, .light, .light)
        case 0x2525: self = Self.box(.light, .none, .light, .heavy)
        case 0x2526: self = Self.box(.heavy, .none, .light, .light)
        case 0x2527: self = Self.box(.light, .none, .heavy, .light)
        case 0x2528: self = Self.box(.heavy, .none, .heavy, .light)
        case 0x2529: self = Self.box(.heavy, .none, .light, .heavy)
        case 0x252A: self = Self.box(.light, .none, .heavy, .heavy)
        case 0x252B: self = Self.box(.heavy, .none, .heavy, .heavy)
        case 0x252C: self = Self.box(.none, .light, .light, .light)
        case 0x252D: self = Self.box(.none, .light, .light, .heavy)
        case 0x252E: self = Self.box(.none, .heavy, .light, .light)
        case 0x252F: self = Self.box(.none, .heavy, .light, .heavy)
        case 0x2530: self = Self.box(.none, .light, .heavy, .light)
        case 0x2531: self = Self.box(.none, .light, .heavy, .heavy)
        case 0x2532: self = Self.box(.none, .heavy, .heavy, .light)
        case 0x2533: self = Self.box(.none, .heavy, .heavy, .heavy)
        case 0x2534: self = Self.box(.light, .light, .none, .light)
        case 0x2535: self = Self.box(.light, .light, .none, .heavy)
        case 0x2536: self = Self.box(.light, .heavy, .none, .light)
        case 0x2537: self = Self.box(.light, .heavy, .none, .heavy)
        case 0x2538: self = Self.box(.heavy, .light, .none, .light)
        case 0x2539: self = Self.box(.heavy, .light, .none, .heavy)
        case 0x253A: self = Self.box(.heavy, .heavy, .none, .light)
        case 0x253B: self = Self.box(.heavy, .heavy, .none, .heavy)
        case 0x253C: self = Self.box(.light, .light, .light, .light)
        case 0x253D: self = Self.box(.light, .light, .light, .heavy)
        case 0x253E: self = Self.box(.light, .heavy, .light, .light)
        case 0x253F: self = Self.box(.light, .heavy, .light, .heavy)
        case 0x2540: self = Self.box(.heavy, .light, .light, .light)
        case 0x2541: self = Self.box(.light, .light, .heavy, .light)
        case 0x2542: self = Self.box(.heavy, .light, .heavy, .light)
        case 0x2543: self = Self.box(.heavy, .light, .light, .heavy)
        case 0x2544: self = Self.box(.heavy, .heavy, .light, .light)
        case 0x2545: self = Self.box(.light, .light, .heavy, .heavy)
        case 0x2546: self = Self.box(.light, .heavy, .heavy, .light)
        case 0x2547: self = Self.box(.heavy, .heavy, .light, .heavy)
        case 0x2548: self = Self.box(.light, .heavy, .heavy, .heavy)
        case 0x2549: self = Self.box(.heavy, .light, .heavy, .heavy)
        case 0x254A: self = Self.box(.heavy, .heavy, .heavy, .light)
        case 0x254B: self = Self.box(.heavy, .heavy, .heavy, .heavy)
        case 0x254C: self = Self.dashed(vertical: false, heavy: false, count: 2)
        case 0x254D: self = Self.dashed(vertical: false, heavy: true, count: 2)
        case 0x254E: self = Self.dashed(vertical: true, heavy: false, count: 2)
        case 0x254F: self = Self.dashed(vertical: true, heavy: true, count: 2)
        case 0x2550: self = Self.box(.none, .double, .none, .double)
        case 0x2551: self = Self.box(.double, .none, .double, .none)
        case 0x2552: self = Self.box(.none, .double, .light, .none)
        case 0x2553: self = Self.box(.none, .light, .double, .none)
        case 0x2554: self = Self.box(.none, .double, .double, .none)
        case 0x2555: self = Self.box(.none, .none, .light, .double)
        case 0x2556: self = Self.box(.none, .none, .double, .light)
        case 0x2557: self = Self.box(.none, .none, .double, .double)
        case 0x2558: self = Self.box(.light, .double, .none, .none)
        case 0x2559: self = Self.box(.double, .light, .none, .none)
        case 0x255A: self = Self.box(.double, .double, .none, .none)
        case 0x255B: self = Self.box(.light, .none, .none, .double)
        case 0x255C: self = Self.box(.double, .none, .none, .light)
        case 0x255D: self = Self.box(.double, .none, .none, .double)
        case 0x255E: self = Self.box(.light, .double, .light, .none)
        case 0x255F: self = Self.box(.double, .light, .double, .none)
        case 0x2560: self = Self.box(.double, .double, .double, .none)
        case 0x2561: self = Self.box(.light, .none, .light, .double)
        case 0x2562: self = Self.box(.double, .none, .double, .light)
        case 0x2563: self = Self.box(.double, .none, .double, .double)
        case 0x2564: self = Self.box(.none, .double, .light, .double)
        case 0x2565: self = Self.box(.none, .light, .double, .light)
        case 0x2566: self = Self.box(.none, .double, .double, .double)
        case 0x2567: self = Self.box(.light, .double, .none, .double)
        case 0x2568: self = Self.box(.double, .light, .none, .light)
        case 0x2569: self = Self.box(.double, .double, .none, .double)
        case 0x256A: self = Self.box(.light, .double, .light, .double)
        case 0x256B: self = Self.box(.double, .light, .double, .light)
        case 0x256C: self = Self.box(.double, .double, .double, .double)
        case 0x256D: self = Self.arc(CELL_GRAPHIC_ARC_DOWN_RIGHT)
        case 0x256E: self = Self.arc(CELL_GRAPHIC_ARC_DOWN_LEFT)
        case 0x256F: self = Self.arc(CELL_GRAPHIC_ARC_UP_LEFT)
        case 0x2570: self = Self.arc(CELL_GRAPHIC_ARC_UP_RIGHT)
        case 0x2571: self.init(rawValue: CELL_GRAPHIC_DIAGONAL_DOWN_LEFT)
        case 0x2572: self.init(rawValue: CELL_GRAPHIC_DIAGONAL_DOWN_RIGHT)
        case 0x2573: self.init(rawValue: CELL_GRAPHIC_DIAGONAL_CROSS)
        case 0x2574: self = Self.box(.none, .none, .none, .light)
        case 0x2575: self = Self.box(.light, .none, .none, .none)
        case 0x2576: self = Self.box(.none, .light, .none, .none)
        case 0x2577: self = Self.box(.none, .none, .light, .none)
        case 0x2578: self = Self.box(.none, .none, .none, .heavy)
        case 0x2579: self = Self.box(.heavy, .none, .none, .none)
        case 0x257A: self = Self.box(.none, .heavy, .none, .none)
        case 0x257B: self = Self.box(.none, .none, .heavy, .none)
        case 0x257C: self = Self.box(.none, .heavy, .none, .light)
        case 0x257D: self = Self.box(.light, .none, .heavy, .none)
        case 0x257E: self = Self.box(.none, .light, .none, .heavy)
        case 0x257F: self = Self.box(.heavy, .none, .light, .none)
        default: return nil
        }
    }
}
