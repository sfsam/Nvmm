//
//  Nvmm
//  Scroller.swift
//
//  The window's vertical scrollbar, and the pure math behind it.
//
//  Neovim reports its viewport as a line range (`win_viewport`), not as a pixel
//  offset, so the scrollbar is derived from lines: the knob's size is the share
//  of the buffer that is on screen and its position is how far down the buffer
//  the top line sits. Dragging it asks Neovim to put a line at the top of the
//  window. The measure is buffer lines, not visual lines, so wraps and folds
//  make it approximate — hence the note beside its settings checkbox.
//
//  `ScrollerModel` holds that math with no AppKit dependency so it can be
//  tested directly; `ScrollerController` connects it to an unmodified system
//  `NSScroller`, which lets AppKit supply the native appearance on each macOS
//  release.
//

import Cocoa

/// The part of the scrollbar a click landed on, as far as the math cares.
nonisolated enum ScrollerPart: Sendable {
    /// The knob or the track: the position is already where the user wants it.
    case absolute
    /// The track above the knob: scroll back one screen.
    case pageUp
    /// The track below the knob: scroll forward one screen.
    case pageDown
    /// Anything else (the legacy arrows); stay where we are.
    case other
}

/// Where the knob sits and how big it is, in `NSScroller` terms.
nonisolated struct ScrollerKnob: Sendable, Equatable {
    /// The knob's length as a fraction of the track. Zero draws no knob.
    var proportion: Double
    /// The knob's position, 0 at the top of the buffer, 1 at the bottom.
    var position: Double
    /// False when the whole buffer fits on screen, so there is nothing to drag.
    var enabled: Bool

    static let empty = ScrollerKnob(proportion: 0, position: 0, enabled: false)
}

/// Turns Neovim's viewport into a knob, and a click into a target line.
nonisolated struct ScrollerModel: Sendable, Equatable {
    /// The buffer's length in lines. Never zero, so it is safe to divide by.
    private(set) var lineCount = 1

    /// How many lines the window holds. Remembered rather than recomputed from
    /// every update, because the last screenful of a buffer reports fewer lines
    /// than the window fits (see `update`).
    private(set) var visibleLines = 1

    /// The smallest knob we draw, as a fraction of the track. A long buffer
    /// would otherwise give a knob too small to grab.
    private static let minimumProportion = 0.01

    /// Folds one `win_viewport` report into the model and returns the knob it
    /// implies. `topline` and `botline` are zero-based, `botline` exclusive.
    mutating func update(topline: Int, botline: Int, lineCount newLineCount: Int)
        -> ScrollerKnob {
        // Nothing has been reported yet, or the report is degenerate.
        guard newLineCount > 0, botline > topline else {
            lineCount = 1
            visibleLines = 1
            return .empty
        }

        lineCount = newLineCount
        let reportedVisible = botline - topline

        // At the end of the buffer there may not be enough lines left to fill
        // the window, so the report understates its height. Take the report as
        // the true height only when it cannot be short — when there is more
        // buffer below, or when the first line is on screen — or when it is
        // larger than what we had, which means the window itself grew.
        if botline < newLineCount {
            visibleLines = reportedVisible
        } else if topline == 0 || reportedVisible > visibleLines {
            visibleLines = reportedVisible
        }

        // The whole buffer is on screen: an empty track, nothing to drag.
        guard visibleLines < newLineCount else { return .empty }

        // Neovim scrolls until the last line is at the top of the window, so
        // the travel is the whole buffer less that one line.
        let scrollableLines = Double(newLineCount - 1)
        var position = 0.0
        if scrollableLines > 0 {
            position = min(1, max(0, Double(topline) / scrollableLines))
        }

        let proportion = Double(visibleLines) / Double(newLineCount)
        return ScrollerKnob(
            proportion: min(1, max(Self.minimumProportion, proportion)),
            position: position,
            enabled: true)
    }

    /// The one-based line to put at the top of the window for a click on `part`
    /// with the knob at `position`.
    func targetLine(part: ScrollerPart, position: Double) -> Int {
        let scrollableLines = Double(lineCount - 1)
        // The top line the knob's position stands for, zero-based.
        let currentTopline = Int(position * scrollableLines)

        let target: Int
        switch part {
        case .absolute:
            // Dragging the knob or jumping into the track: the position is
            // already the answer.
            target = currentTopline + 1
        case .pageUp:
            target = currentTopline > visibleLines
                ? currentTopline - visibleLines + 1 : 1
        case .pageDown:
            target = currentTopline + visibleLines + 1
        case .other:
            target = currentTopline + 1
        }
        return min(max(1, target), lineCount)
    }
}

/// Connects Neovim's line-based scrolling to a native vertical scrollbar.
///
/// The scroller is bare rather than a scroll view's: the grid is drawn by Metal
/// at whole-cell positions and Neovim owns what is on screen, so there is no
/// scrollable document for AppKit to move. It remains an exact `NSScroller`,
/// rather than a subclass, so AppKit can use the native rendering for the
/// current macOS release. The legacy style keeps the enabled scrollbar present.
final class ScrollerController: NSObject {

    /// Called with the one-based line to bring to the top of the window.
    var onScroll: ((Int) -> Void)?

    let view: NSScroller

    private var model = ScrollerModel()

    /// The width the layout reserves for the bar.
    static var width: CGFloat {
        NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    override init() {
        view = NSScroller(frame: .zero)
        super.init()

        view.controlSize = .regular
        view.scrollerStyle = .legacy
        view.target = self
        view.action = #selector(scrollerAction)
        view.isEnabled = true
        view.knobProportion = 1
        view.doubleValue = 0
    }

    /// Applies one viewport report from Neovim.
    func update(topline: Int, botline: Int, lineCount: Int) {
        let knob = model.update(topline: topline, botline: botline,
                                lineCount: lineCount)
        view.knobProportion = CGFloat(knob.proportion)
        view.doubleValue = knob.position
        view.isEnabled = knob.enabled
    }

    @objc private func scrollerAction() {
        let line = model.targetLine(part: Self.part(view.hitPart),
                                    position: view.doubleValue)
        onScroll?(line)
    }

    private static func part(_ hitPart: NSScroller.Part) -> ScrollerPart {
        switch hitPart {
        case .knob, .knobSlot: .absolute
        case .decrementPage: .pageUp
        case .incrementPage: .pageDown
        default: .other
        }
    }
}
