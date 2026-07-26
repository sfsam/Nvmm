//
//  Nvmm
//  CursorTrail.swift
//
//  Geometry for the transient polygon drawn between cursor positions.
//

import CoreGraphics

/// Pure cursor-trail geometry, kept separate from Core Animation so cell-shape
/// sizing and bridge construction can be tested deterministically.
nonisolated enum CursorTrailGeometry {
    /// True for the grid's exact bottom-left cell.
    static func isBottomLeft(row: Int, column: Int, gridHeight: Int) -> Bool {
        gridHeight > 0 && row == gridHeight - 1 && column == 0
    }

    /// The cursor's rectangle in view coordinates.
    static func cursorRect(row: Int, column: Int, cellWidth: Int,
                           shape: CursorShape, cellSize: CGSize,
                           lineThickness: CGFloat) -> CGRect {
        let origin = CGPoint(x: CGFloat(column) * cellSize.width,
                             y: CGFloat(row) * cellSize.height)
        let width = cellSize.width * CGFloat(max(1, cellWidth))
        let thickness = max(0, lineThickness)

        switch shape {
        case .block, .blockOutline:
            return CGRect(origin: origin,
                          size: CGSize(width: width, height: cellSize.height))
        case .vertical:
            return CGRect(origin: origin,
                          size: CGSize(width: min(thickness, width),
                                       height: cellSize.height))
        case .horizontal:
            let height = min(thickness, cellSize.height)
            return CGRect(x: origin.x, y: origin.y + cellSize.height - height,
                          width: width, height: height)
        }
    }

    /// A quadrilateral spanning the trailing part of two cursor rects.
    ///
    /// The cross-sections are perpendicular to the direction of travel. Their
    /// radii are the projection of each rectangle onto that perpendicular, so
    /// bars, blocks, different cursor shapes, and diagonal moves join without
    /// a shape-specific case. `lengthFraction` is clamped to one and keeps the
    /// requested final fraction of the center-to-center movement.
    static func bridge(from source: CGRect, to destination: CGRect,
                       lengthFraction: CGFloat = 1) -> [CGPoint]? {
        let sourceCenter = CGPoint(x: source.midX, y: source.midY)
        let end = CGPoint(x: destination.midX, y: destination.midY)
        let dx = end.x - sourceCenter.x
        let dy = end.y - sourceCenter.y
        let length = hypot(dx, dy)
        let fraction = min(max(lengthFraction, 0), 1)
        guard length > .ulpOfOne, fraction > 0 else { return nil }

        let perpendicular = CGPoint(x: -dy / length, y: dx / length)

        func radius(_ rect: CGRect) -> CGFloat {
            abs(perpendicular.x) * rect.width * 0.5
                + abs(perpendicular.y) * rect.height * 0.5
        }

        let sourceRadius = radius(source)
        let endRadius = radius(destination)
        let tailProgress = 1 - fraction
        let start = CGPoint(
            x: sourceCenter.x + dx * tailProgress,
            y: sourceCenter.y + dy * tailProgress)
        let startRadius = sourceRadius
            + (endRadius - sourceRadius) * tailProgress

        func offset(_ point: CGPoint, by value: CGFloat) -> CGPoint {
            CGPoint(x: point.x + perpendicular.x * value,
                    y: point.y + perpendicular.y * value)
        }

        return [
            offset(start, by: -startRadius),
            offset(end, by: -endRadius),
            offset(end, by: endRadius),
            offset(start, by: startRadius),
        ]
    }
}
