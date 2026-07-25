//
//  Nvmm
//  Settings.swift
//
//  The user defaults the app reads, and the window that edits them.
//
//  Settings take effect as they are changed: there is no OK or Apply. Two
//  mechanisms give that, matching how each setting is used. A setting consulted
//  at the moment it matters — where to open a file, whether to keep running
//  after the last window — is simply read then, so a change is picked up by the
//  next thing that asks. A setting that is part of a window's state has to be
//  reapplied when it changes, so windows observe the defaults; see
//  `WindowController.observeSettings`.
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

    /// Registers the defaults that are on unless the user turns them off. Every
    /// other setting is off unless set, which is what `bool(forKey:)` already
    /// returns for a key that was never written.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [contextSensitiveCursorKey: true,
                                                  progressBarKey: true])
    }
}

/// The settings window: a panel of checkboxes bound straight to the defaults.
///
/// The bindings are continuous, so a click writes the default immediately
/// rather than at some later commit. That write is the only thing this window
/// does — everything that acts on a setting reads it from `UserDefaults`, so
/// nothing here needs to know who is listening.
final class SettingsWindowController: NSWindowController {

    convenience init() {
        let behavior = NSTextField(labelWithString:
            NSLocalizedString("Behavior:", comment: "Settings section"))
        let appearance = NSTextField(labelWithString:
            NSLocalizedString("Appearance:", comment: "Settings section"))

        let buffers = Self.checkbox(
            NSLocalizedString("Open files in buffers instead of tabs",
                              comment: "Settings checkbox"),
            key: Settings.openFilesInBuffersKey)
        let buffersNote = Self.note(NSLocalizedString(
            "Applies to New, Open…, files opened from the Finder, "
                + "and files dropped on a window with Option held.",
            comment: "Settings note under the buffers checkbox"))
        let terminate = Self.checkbox(
            NSLocalizedString("Terminate after last window closed",
                              comment: "Settings checkbox"),
            key: Settings.terminateAfterLastWindowKey)
        let titlebar = Self.checkbox(
            NSLocalizedString("Transparent title bar", comment: "Settings checkbox"),
            key: Settings.titlebarAppearsTransparentKey)
        let scrollbar = Self.checkbox(
            NSLocalizedString("Vertical scrollbar", comment: "Settings checkbox"),
            key: Settings.verticalScrollbarKey)
        let scrollbarNote = Self.note(NSLocalizedString(
            "The scrollbar scrolls by buffer lines, not visual lines, so it "
                + "may not behave as expected if your text has wrapped lines "
                + "or lines hidden by folds.",
            comment: "Settings note under the scrollbar checkbox"))

        let empty = NSGridCell.emptyContentView
        let grid = NSGridView(views: [[behavior, buffers],
                                      [empty, buffersNote],
                                      [empty, terminate],
                                      [appearance, titlebar],
                                      [empty, scrollbar],
                                      [empty, scrollbarNote]])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.row(at: 2).bottomPadding = 12

        // Each note belongs to the checkbox above it, so it lines up with that
        // checkbox's title rather than with the column.
        let noteCell = grid.cell(for: buffersNote)
        noteCell?.xPlacement = .none
        noteCell?.customPlacementConstraints = [
            buffersNote.leadingAnchor.constraint(
                equalTo: buffers.leadingAnchor, constant: 21)
        ]
        let scrollbarNoteCell = grid.cell(for: scrollbarNote)
        scrollbarNoteCell?.xPlacement = .none
        scrollbarNoteCell?.customPlacementConstraints = [
            scrollbarNote.leadingAnchor.constraint(
                equalTo: buffersNote.leadingAnchor)
        ]

        let contentView = NSView()
        contentView.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(
                equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            grid.trailingAnchor.constraint(
                equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            grid.topAnchor.constraint(
                equalTo: contentView.layoutMarginsGuide.topAnchor),
            grid.bottomAnchor.constraint(
                equalTo: contentView.layoutMarginsGuide.bottomAnchor)
        ])

        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: false)
        panel.title = NSLocalizedString("Settings", comment: "Settings window title")
        panel.contentView = contentView
        self.init(window: panel)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
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
