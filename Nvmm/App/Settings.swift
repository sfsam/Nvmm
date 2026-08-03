//
//  Nvmm
//  Settings.swift
//
//  The user defaults the app reads, and the window that edits them.
//
//  Settings normally take effect as they are changed. Text thickness waits for
//  a short pause in slider movement so dragging does not repeatedly rebuild the
//  app-wide glyph cache. A setting consulted at the moment it matters is simply
//  read then; window state is reapplied by `WindowController.observeSettings`.
//

import Cocoa

/// The app's user defaults.
enum Settings {
    /// Whether a document opens as a buffer in the current tab page rather
    /// than in a new tab page. Applies to Finder and drag-and-drop opens, the
    /// Open panel, and New.
    static let openFilesInBuffersKey = "NVOpenFilesInBuffersInsteadOfTabs"

    /// Whether closing the last window quits the app.
    static let terminateAfterLastWindowKey = "NVShouldTerminateAfterLastWindowClosed"

    /// Whether the title bar is transparent, so the editor's background color
    /// runs behind it.
    static let titlebarAppearsTransparentKey = "NVTitlebarAppearsTransparent"

    /// Whether the window shows a vertical scrollbar down its trailing edge.
    static let verticalScrollbarKey = "NVEnableVerticalScrollbar"

    /// Whether the window shows a progress bar for Neovim's running tasks. On
    /// unless the user turns it off.
    static let progressBarKey = "NVEnableProgressBar"

    /// Whether the mouse cursor reflects what it is over — an I-beam over text,
    /// a resize cursor over a separator. Has no settings-window checkbox; it is
    /// on unless the key is set by hand.
    static let contextSensitiveCursorKey = "NVEnableContextSensitiveMouseCursor"

    /// Whether cursor movement leaves a transient polygon trail.
    static let cursorTrailEnabledKey = "NVEnableCursorTrail"

    /// The final fraction of a cursor move covered by its trail.
    static let cursorTrailLengthFractionKey = "NVCursorTrailLengthFraction"

    /// The maximum opacity of a cursor trail.
    static let cursorTrailOpacityKey = "NVCursorTrailOpacity"

    /// Zero disables thickening; positive values are CoreText strengths.
    static let fontThicknessKey = "NVFontThickness"

    static let cursorTrailMinimumValue = 0.1
    static let cursorTrailMaximumValue = 1.0
    nonisolated static let fontThicknessMinimum = 0
    nonisolated static let fontThicknessMaximum = 255
    nonisolated static let fontThicknessValues = [0, 50, 150, 250]

    static var openFilesInBuffers: Bool {
        UserDefaults.standard.bool(forKey: openFilesInBuffersKey)
    }

    static var terminateAfterLastWindow: Bool {
        UserDefaults.standard.bool(forKey: terminateAfterLastWindowKey)
    }

    static var titlebarAppearsTransparent: Bool {
        UserDefaults.standard.bool(forKey: titlebarAppearsTransparentKey)
    }

    static var verticalScrollbar: Bool {
        UserDefaults.standard.bool(forKey: verticalScrollbarKey)
    }

    static var progressBar: Bool {
        UserDefaults.standard.bool(forKey: progressBarKey)
    }

    static var contextSensitiveCursor: Bool {
        UserDefaults.standard.bool(forKey: contextSensitiveCursorKey)
    }

    static var cursorTrailEnabled: Bool {
        UserDefaults.standard.bool(forKey: cursorTrailEnabledKey)
    }

    static var cursorTrailLengthFraction: Double {
        clampedCursorTrailValue(forKey: cursorTrailLengthFractionKey)
    }

    static var cursorTrailOpacity: Double {
        clampedCursorTrailValue(forKey: cursorTrailOpacityKey)
    }

    static var fontThickness: Int {
        min(max(UserDefaults.standard.integer(forKey: fontThicknessKey),
                fontThicknessMinimum), fontThicknessMaximum)
    }

    /// The slider detent nearest to an existing thickness default.
    nonisolated static func fontThicknessLevel(for value: Int) -> Int {
        let value = min(max(value, fontThicknessMinimum),
                        fontThicknessMaximum)
        var nearest = 0
        var distance = Int.max
        for (index, candidate) in fontThicknessValues.enumerated() {
            let next = abs(candidate - value)
            if next <= distance {
                nearest = index
                distance = next
            }
        }
        return nearest
    }

    /// The canonical thickness for a slider detent.
    nonisolated static func fontThicknessValue(for level: Int) -> Int {
        let index = min(max(level, 0), fontThicknessValues.count - 1)
        return fontThicknessValues[index]
    }

    private static func clampedCursorTrailValue(forKey key: String) -> Double {
        min(max(UserDefaults.standard.double(forKey: key),
                cursorTrailMinimumValue), cursorTrailMaximumValue)
    }

    /// Registers settings whose resting value is not supplied by the relevant
    /// typed `UserDefaults` accessor.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            contextSensitiveCursorKey: true,
            progressBarKey: true,
            fontThicknessKey: 50,
            cursorTrailLengthFractionKey: 0.55,
            cursorTrailOpacityKey: 0.55,
        ])
    }
}

/// The settings window: immediate bindings plus debounced font rasterization.
///
/// Ordinary controls write their defaults continuously. Text thickness waits
/// briefly after slider movement because changing it invalidates a GPU cache.
final class SettingsWindowController: NSWindowController {
    private static let fontThicknessDebounce = Duration.milliseconds(500)

    private var fontThicknessSlider: NSSlider!
    private var appliedFontThicknessLevel = 0
    private var pendingFontThicknessTask: Task<Void, Never>?

    convenience init() {
        let behavior = NSTextField(labelWithString:
            String(localized: "Behavior:"))
        let appearance = NSTextField(labelWithString:
            String(localized: "Appearance:"))

        let buffers = Self.checkbox(
            String(localized: "Open files in buffers instead of tabs"),
            key: Settings.openFilesInBuffersKey)
        let buffersNote = Self.note(String(localized:
            "Applies to New, Open…, files opened from the Finder, and files dropped on a window with Option held."))
        let terminate = Self.checkbox(
            String(localized: "Terminate after last window closed"),
            key: Settings.terminateAfterLastWindowKey)
        let titlebar = Self.checkbox(
            String(localized: "Transparent title bar"),
            key: Settings.titlebarAppearsTransparentKey)
        let scrollbar = Self.checkbox(
            String(localized: "Vertical scrollbar"),
            key: Settings.verticalScrollbarKey)
        let scrollbarNote = Self.note(String(localized:
            "Scrolls by buffer lines, not visual lines. It may not behave as expected if your text has wrapped lines or folds."))
        let thicknessLabel = NSTextField(labelWithString:
            String(localized: "Text thickness:"))
        let thickness = NSSlider(value: 0, minValue: 0, maxValue: 3,
                                 target: nil, action: nil)
        thickness.numberOfTickMarks = 4
        thickness.allowsTickMarkValuesOnly = true
        thickness.tickMarkPosition = .below
        thickness.isContinuous = true
        thickness.identifier = .init("fontThickness")
        thickness.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let thicknessControls = NSStackView(views: [thicknessLabel, thickness])
        thicknessControls.orientation = .horizontal
        thicknessControls.alignment = .centerY
        thicknessControls.spacing = 8
        let cursorTrail = Self.checkbox(String(localized: "Cursor trail"),
                                        key: Settings.cursorTrailEnabledKey)
        let cursorTrailGrid = Self.cursorTrailGrid()

        let empty = NSGridCell.emptyContentView
        let grid = NSGridView(views: [[behavior, buffers],
                                      [empty, buffersNote],
                                      [empty, terminate],
                                      [appearance, titlebar],
                                      [empty, scrollbar],
                                      [empty, scrollbarNote],
                                      [empty, thicknessControls],
                                      [empty, cursorTrail],
                                      [empty, cursorTrailGrid]])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.row(at: 2).bottomPadding = 12

        // Each item belongs to the checkbox above it, so it lines up with that
        // checkbox's title rather than with the column.
        for item in [buffersNote, scrollbarNote, cursorTrailGrid] {
            let cell = grid.cell(for: item)
            cell?.xPlacement = .none
            cell?.customPlacementConstraints = [
                item.leadingAnchor.constraint(
                    equalTo: buffers.leadingAnchor, constant: 21)
            ]
        }
        let thicknessCell = grid.cell(for: thicknessControls)
        thicknessCell?.xPlacement = .none
        thicknessCell?.customPlacementConstraints = [
            thicknessControls.leadingAnchor.constraint(
                equalTo: buffers.leadingAnchor)
        ]

        let contentView = NSView()
        contentView.addSubview(grid)
        contentView.addConstraints(NSLayoutConstraint.constraints(
            withVisualFormat: "H:|-[grid]-|", metrics: nil,
            views: ["grid": grid]))
        contentView.addConstraints(NSLayoutConstraint.constraints(
            withVisualFormat: "V:|-[grid]-|", metrics: nil,
            views: ["grid": grid]))

        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: false)
        panel.title = String(localized: "Settings")
        panel.contentView = contentView
        self.init(window: panel)

        fontThicknessSlider = thickness
        thickness.target = self
        thickness.action = #selector(fontThicknessChanged)
        loadFontThickness()
    }

    override func showWindow(_ sender: Any?) {
        if pendingFontThicknessTask == nil { loadFontThickness() }
        super.showWindow(sender)
        window?.center()
    }

    @objc private func fontThicknessChanged(_ sender: NSSlider) {
        pendingFontThicknessTask?.cancel()
        let level = sender.integerValue
        guard level != appliedFontThicknessLevel else {
            pendingFontThicknessTask = nil
            return
        }
        pendingFontThicknessTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.fontThicknessDebounce)
            } catch {
                return
            }
            self?.applyFontThickness(level: level)
            self?.pendingFontThicknessTask = nil
        }
    }

    private func applyFontThickness(level: Int) {
        UserDefaults.standard.set(Settings.fontThicknessValue(for: level),
                                  forKey: Settings.fontThicknessKey)
        appliedFontThicknessLevel = level
    }

    private func loadFontThickness() {
        appliedFontThicknessLevel = Settings.fontThicknessLevel(
            for: Settings.fontThickness)
        fontThicknessSlider.integerValue = appliedFontThicknessLevel
    }

    /// A checkbox whose value is the named default, written as it is clicked.
    private static func checkbox(_ title: String, key: String) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.bind(.value,
                    to: NSUserDefaultsController.shared,
                    withKeyPath: "values.\(key)",
                    options: [.continuouslyUpdatesValue: true])
        return button
    }

    /// Secondary text explaining the checkbox above it.
    private static func note(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byWordWrapping
        field.font = .systemFont(ofSize: 12)
        field.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(1), for: .horizontal)
        return field
    }

    /// A continuously bound slider for a cursor trail parameter.
    private static func cursorTrailSlider(key: String) -> NSSlider {
        let slider = NSSlider(
            value: 0,
            minValue: Settings.cursorTrailMinimumValue,
            maxValue: Settings.cursorTrailMaximumValue,
            target: nil,
            action: nil)
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let defaults = NSUserDefaultsController.shared
        slider.bind(
            .value, to: defaults, withKeyPath: "values.\(key)",
            options: [.continuouslyUpdatesValue: true])
        return slider
    }

    /// Cursor trail sliders in a grid.
    private static func cursorTrailGrid() -> NSGridView {
        let length = String(localized: "Length:")
        let intens = String(localized: "Intensity:")
        let lengthLabel = NSTextField(labelWithString:length)
        let intensLabel = NSTextField(labelWithString:intens)
        let lengthSlider = cursorTrailSlider(key: Settings.cursorTrailLengthFractionKey)
        let intensSlider = cursorTrailSlider(key: Settings.cursorTrailOpacityKey)

        let defaults = NSUserDefaultsController.shared
        let enabledPath = "values.\(Settings.cursorTrailEnabledKey)"
        for control in [lengthSlider, intensSlider] {
            control.bind(.enabled, to: defaults, withKeyPath: enabledPath)
        }
        // Slider labels get disabled text color when disabled.
        let colorTransformer = EnabledLabelColorTransformer()
        for label in [lengthLabel, intensLabel] {
            label.bind(.textColor, to: defaults, withKeyPath: enabledPath,
                       options: [.valueTransformer: colorTransformer])
        }

        let grid = NSGridView(views: [[intensLabel, intensSlider],
                                      [lengthLabel, lengthSlider]])
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        return grid
    }
}

/// Maps an enabled binding to AppKit's corresponding control-text color.
nonisolated private final class EnabledLabelColorTransformer: ValueTransformer {
    override class func transformedValueClass() -> AnyClass {
        NSColor.self
    }

    override func transformedValue(_ value: Any?) -> Any? {
        let enabled = (value as? NSNumber)?.boolValue ?? false
        return enabled ? NSColor.labelColor : NSColor.disabledControlTextColor
    }
}
