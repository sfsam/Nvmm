//
//  Nvmm
//  CursorFade.swift
//
//  The short, stepped opacity transition used by cursor blinking.
//

import Foundation

/// A bounded cursor-opacity transition sampled from absolute time.
nonisolated struct CursorFade: Equatable, Sendable {
    // Keep the effect brief and bounded. Using half the configured phase leaves
    // a stationary interval without changing Neovim's blink timing. Four steps
    // retain a visible transition while bounding redraw work.
    static let maximumDuration: TimeInterval = 0.12
    static let frameInterval: TimeInterval = 0.03
    static let maximumSteps = 4

    let from: Float
    let to: Float
    let start: TimeInterval
    let duration: TimeInterval
    let steps: Int

    init(from: Float, to: Float, start: TimeInterval,
         phaseMilliseconds: UInt16) {
        self.from = min(max(from, 0), 1)
        self.to = min(max(to, 0), 1)
        self.start = start
        duration = min(Self.maximumDuration,
                       Double(phaseMilliseconds) / 2_000)
        steps = max(1, min(Self.maximumSteps,
                           Int(ceil(duration / Self.frameInterval))))
    }

    var timerInterval: TimeInterval { duration / Double(steps) }

    func opacity(at time: TimeInterval) -> Float {
        guard duration > 0 else { return to }
        let elapsed = min(max(time - start, 0), duration)
        // Decimal timer boundaries may land just below their binary value.
        let completed = min(
            steps, Int((elapsed / timerInterval + 1e-9).rounded(.down)))
        let progress = Float(completed) / Float(steps)
        return from + (to - from) * progress
    }

    func isComplete(at time: TimeInterval) -> Bool {
        // Use the same tolerance as opacity(at:) at the final boundary.
        time - start >= duration - 1e-9
    }
}
