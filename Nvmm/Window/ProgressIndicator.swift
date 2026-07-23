//
//  Nvmm
//  ProgressIndicator.swift
//
//  The thin bar across the top of the window that shows Neovim's task progress.
//
//  It is an `NSProgressIndicator` for its determinate value API, but draws
//  itself: the AppKit bar is a rounded, inset capsule sized for a dialog, where
//  what is wanted here is a flush square fill a couple of points tall, sitting
//  against the title bar like a browser's load indicator.
//

import Cocoa

final class ProgressIndicator: NSProgressIndicator {

    /// The bar's height. Thin enough to read as a window edge rather than a
    /// control, which is why it can sit over the grid without taking a row.
    static let thickness: CGFloat = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        style = .bar
        isIndeterminate = false
        minValue = 0
        maxValue = 100
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // The window's other view classes take the same one-liner; it skips the
    // executor hop an isolated deinit would make without changing isolation.
    nonisolated deinit {}

    // The superclass redraws on its own animation timer, which a determinate
    // bar this one drives directly never runs, so a new value has to ask.
    override var doubleValue: Double {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let range = maxValue - minValue
        let fraction = range > 0 ? (doubleValue - minValue) / range : 0
        var fill = bounds
        fill.size.width *= min(max(fraction, 0), 1)
        NSColor.controlAccentColor.setFill()
        fill.fill()
    }
}
