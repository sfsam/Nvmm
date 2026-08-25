//
//  Nvmm
//  ProgressIndicator.swift
//
//  The thin bar across the top of the window that shows Neovim's task progress.
//
//  It uses two square Core Animation layers: a translucent full-width blue
//  track and an opaque blue fill.
//

import Cocoa

final class ProgressIndicator: NSView {

    /// The bar's height. Thin enough to read as a window edge rather than a
    /// control, which is why it can sit over the grid without taking a row.
    static let thickness: CGFloat = 2

    private static let progressAnimationKey = "progress"
    private static let animationDuration = 0.2
    private static let fillColor = NSColor(
        srgbRed: 0, green: 122.0 / 255.0, blue: 1, alpha: 1)
    private static let trackColor = fillColor.withAlphaComponent(0.4)

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private var progress = 0.0
    private var targetVisible = false
    private var visibilityAnimation: UInt64 = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        fillLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(100)
        setAccessibilityValue(progress)
        updateColors()
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // The window's other view classes take the same one-liner; it skips the
    // executor hop an isolated deinit would make without changing isolation.
    nonisolated deinit {}

    override func layout() {
        super.layout()
        setLayerGeometry(fillWidth: targetFillWidth)
    }

    /// Moves the fill to `value`, continuing smoothly from an interrupted move.
    func setProgress(_ value: Double, animated: Bool = true) {
        let value = min(max(value, 0), 100)
        guard value != progress else { return }
        let startingWidth = fillLayer.presentation()?.bounds.width
            ?? fillLayer.bounds.width
        progress = value
        setAccessibilityValue(progress)
        let endingWidth = targetFillWidth
        setLayerGeometry(fillWidth: endingWidth)
        fillLayer.removeAnimation(forKey: Self.progressAnimationKey)

        guard targetVisible,
              shouldAnimate(animated),
              abs(endingWidth - startingWidth) > 0.5 else { return }
        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = startingWidth
        animation.toValue = endingWidth
        animation.duration = Self.animationDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fillLayer.add(animation, forKey: Self.progressAnimationKey)
    }

    /// Fades the complete track and fill in or out.
    func setVisible(_ visible: Bool, animated: Bool = true) {
        guard visible != targetVisible else { return }
        targetVisible = visible
        visibilityAnimation &+= 1
        let generation = visibilityAnimation

        if visible { isHidden = false }
        guard shouldAnimate(animated) else {
            alphaValue = visible ? 1 : 0
            isHidden = !visible
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(
                name: .easeInEaseOut)
            animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      generation == self.visibilityAnimation else { return }
                self.isHidden = !visible
            }
        }
    }

    private var targetFillWidth: CGFloat {
        bounds.width * progress / 100
    }

    private func setLayerGeometry(fillWidth: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        fillLayer.position = CGPoint(x: bounds.minX, y: bounds.midY)
        fillLayer.bounds = CGRect(
            x: 0, y: 0, width: fillWidth, height: bounds.height)
        CATransaction.commit()
    }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.backgroundColor = Self.fillColor.cgColor
        trackLayer.backgroundColor = Self.trackColor.cgColor
        CATransaction.commit()
    }

    private func shouldAnimate(_ requested: Bool) -> Bool {
        requested &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
