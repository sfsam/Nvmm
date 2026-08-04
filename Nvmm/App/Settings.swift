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

    /// Zero disables the cursor trail; larger values select stronger profiles.
    static let cursorTrailStrengthKey = "NVCursorTrailStrength"

    /// Zero disables thickening; positive values are CoreText strengths.
    static let fontThicknessKey = "NVFontThickness"

    nonisolated static let cursorTrailStrengthMinimum = 0
    nonisolated static let cursorTrailStrengthMaximum = 3
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

    static var cursorTrailStrength: Int {
        min(max(UserDefaults.standard.integer(forKey: cursorTrailStrengthKey),
                cursorTrailStrengthMinimum), cursorTrailStrengthMaximum)
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

    /// Registers settings whose resting value is not supplied by the relevant
    /// typed `UserDefaults` accessor.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            contextSensitiveCursorKey: true,
            progressBarKey: true,
            fontThicknessKey: 50,
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
        let behaviorLabel = NSTextField(labelWithString:
            String(localized: "Behavior:"))
        let windowLabel = NSTextField(labelWithString:
            String(localized: "Window:"))
        let thicknessLabel = NSTextField(labelWithString:
            String(localized: "Text thickness:"))
        let cursorTrailLabel = NSTextField(labelWithString:
            String(localized: "Cursor trail:"))

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

        let thickness = NSSlider(value: 0, minValue: 0, maxValue: 3,
                                 target: nil, action: nil)
        thickness.numberOfTickMarks = 4
        thickness.allowsTickMarkValuesOnly = true
        thickness.tickMarkPosition = .below
        thickness.isContinuous = true
        thickness.identifier = .init("fontThickness")
        thickness.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let cursorTrail = NSSlider(
            value: 0,
            minValue: Double(Settings.cursorTrailStrengthMinimum),
            maxValue: Double(Settings.cursorTrailStrengthMaximum),
            target: nil, action: nil)
        cursorTrail.numberOfTickMarks = 4
        cursorTrail.allowsTickMarkValuesOnly = true
        cursorTrail.tickMarkPosition = .below
        cursorTrail.isContinuous = true
        cursorTrail.identifier = .init("cursorTrailStrength")
        cursorTrail.widthAnchor.constraint(equalToConstant: 180).isActive = true
        cursorTrail.bind(
            .value, to: NSUserDefaultsController.shared,
            withKeyPath: "values.\(Settings.cursorTrailStrengthKey)",
            options: [.continuouslyUpdatesValue: true])

        let empty = NSGridCell.emptyContentView
        let grid = NSGridView(views: [[behaviorLabel, buffers],
                                      [empty, buffersNote],
                                      [empty, terminate],
                                      [windowLabel, titlebar],
                                      [empty, scrollbar],
                                      [empty, scrollbarNote],
                                      [thicknessLabel, thickness],
                                      [cursorTrailLabel, cursorTrail]])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.row(at: 2).bottomPadding = 12
        grid.row(at: 5).bottomPadding = 12
        grid.row(at: 6).bottomPadding = 12

        // Indent secondary controls to the checkbox-title column.
        for item in [buffersNote, scrollbarNote, thickness, cursorTrail] {
            let cell = grid.cell(for: item)
            cell?.xPlacement = .none
            cell?.customPlacementConstraints = [
                item.leadingAnchor.constraint(
                    equalTo: buffers.leadingAnchor, constant: 21)
            ]
        }

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

}
