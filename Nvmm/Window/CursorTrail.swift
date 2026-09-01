//
//  Nvmm
//  CursorTrail.swift
//
//  Cursor-smear profiles and renderer-independent cursor geometry.
//

import CoreGraphics
import Foundation

/// One detent of the cursor-trail strength setting.
nonisolated struct CursorTrailProfile: Equatable {
    let lengthFraction: Float
    let opacity: Float
    let duration: TimeInterval
    let cornerSpeed: Float

    /// Returns nil for off. Each higher profile jointly increases the smear's
    /// coverage, visibility, lifetime, and trailing-corner lag.
    static func profile(for strength: Int) -> CursorTrailProfile? {
        switch min(max(strength, 0), 3) {
        case 1: CursorTrailProfile(lengthFraction: 0.35, opacity: 0.35,
                                   duration: 0.035, cornerSpeed: 1.5)
        case 2: CursorTrailProfile(lengthFraction: 0.7, opacity: 0.6,
                                   duration: 0.05, cornerSpeed: 2)
        case 3: CursorTrailProfile(lengthFraction: 1, opacity: 0.85,
                                   duration: 0.08, cornerSpeed: 2.75)
        default: nil
        }
    }
}

/// Pure cursor geometry shared by trail state construction and tests.
nonisolated enum CursorTrailGeometry {
    /// True for the grid's exact bottom-left cell.
    static func isBottomLeft(row: Int, column: Int, gridHeight: Int) -> Bool {
        gridHeight > 0 && row == gridHeight - 1 && column == 0
    }

    /// The cursor rectangle in the coordinate space supplied by `cellSize`.
    static func cursorRect(row: Int, column: Int, cellWidth: Int,
                           shape: CursorShape, cellSize: CGSize,
                           lineThickness: CGFloat,
                           cursorHeight: CGFloat? = nil) -> CGRect {
        let origin = CGPoint(x: CGFloat(column) * cellSize.width,
                             y: CGFloat(row) * cellSize.height)
        let width = cellSize.width * CGFloat(max(1, cellWidth))
        let thickness = max(0, lineThickness)
        let height = min(max(0, cursorHeight ?? cellSize.height),
                         cellSize.height)
        let cursorOrigin = CGPoint(x: origin.x,
                                   y: origin.y +
                                      floor((cellSize.height - height) / 2))

        switch shape {
        case .block, .blockOutline:
            return CGRect(origin: cursorOrigin,
                          size: CGSize(width: width, height: height))
        case .vertical:
            return CGRect(origin: cursorOrigin,
                          size: CGSize(width: min(thickness, width),
                                       height: height))
        case .horizontal:
            let barHeight = min(thickness, height)
            return CGRect(x: cursorOrigin.x,
                          y: cursorOrigin.y + height - barHeight,
                          width: width, height: barHeight)
        }
    }
}
