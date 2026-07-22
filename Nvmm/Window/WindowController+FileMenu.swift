//
//  Nvmm
//  WindowController+FileMenu.swift
//
//  The File menu, as it applies to one window's Neovim.
//
//  Each of these actions is also implemented by `AppDelegate`, which the
//  responder chain reaches when no editor window is in it — a new window is
//  then the answer to every one of them. So "no window" needs no test here:
//  this file only ever runs with a window to act on.
//
//  Every action first asks Neovim what mode it is in and refuses if a command
//  would be swallowed (see `NeovimProcess.prepareForCommand`), which makes them
//  all asynchronous. Panels and alerts are therefore put up after an await;
//  window-modal sheets keep the rest of the app usable meanwhile.
//

import Cocoa

extension WindowController {

    // MARK: - New

    /// Opens an empty document: a new buffer in the current tab page, or a new
    /// tab page, following the buffers-instead-of-tabs preference. Neovim
    /// reports its own error (a modified buffer with `'hidden'` off refuses
    /// `:enew`), so nothing is second-guessed here.
    @IBAction func newDocument(_ sender: Any?) {
        guard let process else { return }
        Task {
            let command = Settings.openFilesInBuffers ? "enew" : "tabnew"
            if await !process.normalCommand(command) { NSSound.beep() }
        }
    }

    // MARK: - Open

    /// Opens files chosen in an open panel into this window.
    @IBAction func openDocument(_ sender: Any?) {
        guard let process else { return }
        Task {
            guard await process.prepareForCommand() else { return NSSound.beep() }
            let paths = Self.runOpenPanel()
            guard !paths.isEmpty else { return }
            await process.open(paths, inBuffers: Settings.openFilesInBuffers)
        }
    }

    /// Runs the shared open panel and returns the chosen paths, empty if the
    /// panel was cancelled. Files and directories are both selectable, as
    /// Neovim opens a directory as a file browser.
    static func runOpenPanel() -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map(\.path)
    }

    /// Opens paths in this window, following the buffers-instead-of-tabs
    /// preference, and brings the window forward. Used by the Finder and
    /// drag-and-drop open paths, which choose a window before opening.
    func open(paths: [String]) {
        guard let process, !paths.isEmpty else { return }
        Task {
            await process.open(paths, inBuffers: Settings.openFilesInBuffers)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Save

    /// Writes the current buffer, asking for a filename if it has none.
    @IBAction func saveDocument(_ sender: Any?) {
        guard let process else { return }
        Task {
            guard await process.canSave() else { return NSSound.beep() }
            switch await process.writeCurrentBuffer() {
            case .written: break
            case .needsFilename: _ = await showSavePanelAndWrite()
            case .failed: NSSound.beep()
            }
        }
    }

    /// Writes the current buffer to a filename chosen in a save panel.
    @IBAction func saveDocumentAs(_ sender: Any?) {
        guard let process else { return }
        Task {
            guard await process.canSave() else { return NSSound.beep() }
            _ = await showSavePanelAndWrite()
        }
    }

    /// Runs the save panel as a sheet and writes the current buffer to the
    /// chosen path. The mode is rechecked after the sheet, since the user had
    /// the whole time it was up to leave the buffer somewhere unwritable.
    func showSavePanelAndWrite() async -> SaveResult {
        guard let window, let process else { return .failed }
        let panel = NSSavePanel()
        let response = await panel.beginSheetModal(for: window)
        guard response == .OK, let path = panel.url?.path else { return .cancelled }
        guard await process.canSave() else {
            NSSound.beep()
            return .failed
        }
        return await process.writeAs(path) ? .saved : .failed
    }
}

/// The outcome of a save panel and the write that follows it. Cancelling is
/// distinct from failing: it stops a sequence of prompts without an error.
enum SaveResult: Sendable, Equatable {
    case saved, cancelled, failed
}

// MARK: - Dragging files onto the window

extension WindowController: NSDraggingDestination {

    public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    /// Accepts dropped files. Holding Option opens them; otherwise their paths
    /// are inserted, which is what dropping a file usually does on macOS.
    ///
    /// Option-dragging is what narrows the source's operation mask to exactly
    /// Copy — a plain drag from the Finder offers Copy and Link together — so
    /// that is what distinguishes the two.
    ///
    /// The drop is accepted before Neovim has been asked what mode it is in,
    /// since that answer cannot be awaited here. A drop arriving while Neovim
    /// is blocked is therefore accepted and then quietly dropped, rather than
    /// animating back to where it came from.
    public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let classes = [NSURL.self]
        let urls = sender.draggingPasteboard.readObjects(forClasses: classes) as? [URL]
        guard let urls, !urls.isEmpty, let process else { return false }

        let mask = sender.draggingSourceOperationMask.intersection([.copy, .link])
        let opensFiles = mask == .copy
        let paths = urls.map(\.path)
        let inBuffers = Settings.openFilesInBuffers

        Task {
            await process.drop(paths: paths, opensFiles: opensFiles,
                               inBuffers: inBuffers)
        }
        return true
    }
}

// MARK: - Closing

/// What the user chose when asked about one modified buffer.
private enum SavePrompt: Sendable, Equatable {
    case saved, discarded, cancelled, failed
}

extension WindowController {

    /// Close Window: quits this window's Neovim, asking about each modified
    /// buffer first. The red close button routes here too, so both ways of
    /// closing a window prompt identically.
    @IBAction func closeWindow(_ sender: Any?) {
        Task { await closeAfterSavingBuffers() }
    }

    /// Close: closes the current buffer, or the window when it is the last one.
    ///
    /// A window other than this one can be key — a panel, say — in which case
    /// the keyboard shortcut belongs to it, not to a buffer in here.
    @IBAction func closeWindowOrDeleteBuffer(_ sender: Any?) {
        if let key = NSApp.keyWindow, key !== window {
            key.performClose(sender)
            return
        }
        Task { await deleteCurrentBuffer() }
    }

    /// Asks about every modified buffer, then quits Neovim discarding whatever
    /// the user chose not to save.
    ///
    /// The prompts are sheets, so the user can keep working in this window
    /// while they are up, and buffers can be modified after they were asked
    /// about. Before discarding anything, the modified set is therefore read
    /// again and matched against what was explicitly discarded — by
    /// `changedtick`, so a buffer that was discarded and then edited again does
    /// not match, and is asked about afresh. Only once nothing unexpected is
    /// modified is the forced quit issued.
    private func closeAfterSavingBuffers() async {
        guard let process else { return }
        guard var pending = await process.modifiedBuffers() else { return NSSound.beep() }
        var discarded: [ModifiedBuffer] = []

        while true {
            for buffer in pending {
                switch await promptToSave(buffer) {
                case .saved: continue
                case .discarded: discarded.append(buffer)
                case .cancelled: return
                case .failed: return NSSound.beep()
                }
            }

            guard let modified = await process.modifiedBuffers() else {
                return NSSound.beep()
            }
            let unexpected = modified.filter { !discarded.contains($0) }
            if unexpected.isEmpty { break }
            pending = unexpected
        }

        beginQuit(force: true)
    }

    /// Closes the current buffer. The last buffer means closing the window,
    /// which prompts for every modified buffer; otherwise only this buffer is
    /// at stake, so only it is asked about.
    private func deleteCurrentBuffer() async {
        guard let process else { return }
        guard let info = await process.currentBufferInfo() else { return NSSound.beep() }

        if info.isOnlyBuffer {
            await closeAfterSavingBuffers()
        } else if info.isModified {
            await promptToSaveThenDelete(info)
        } else {
            await process.deleteBuffer(info.bufnr, force: false)
        }
    }

    /// Asks about one modified buffer and carries out the answer, writing it
    /// where the user chose to save.
    private func promptToSave(_ buffer: ModifiedBuffer) async -> SavePrompt {
        guard let process, let window else { return .failed }

        switch await Self.runSavePrompt(for: buffer.name, in: window) {
        case .alertThirdButtonReturn: return .cancelled
        case .alertSecondButtonReturn: return .discarded
        default: break
        }

        switch await process.writeBuffer(buffer.bufnr) {
        case .written: return .saved
        case .failed: return .failed
        case .needsFilename:
            // An unnamed buffer needs a filename before it can be written, and
            // it is the current buffer now that it has been switched to.
            switch await showSavePanelAndWrite() {
            case .saved: return .saved
            case .cancelled: return .cancelled
            case .failed: return .failed
            }
        }
    }

    /// Asks about the current buffer and deletes it, discarding its changes
    /// only if that is what the user chose.
    private func promptToSaveThenDelete(_ info: CurrentBufferInfo) async {
        guard let process, let window else { return }

        switch await Self.runSavePrompt(for: info.name, in: window) {
        case .alertThirdButtonReturn:
            return
        case .alertSecondButtonReturn:
            await process.deleteBuffer(info.bufnr, force: true)
            return
        default:
            break
        }

        if info.name.isEmpty {
            // Switch to the buffer first, so the save panel names the buffer
            // the user was asked about rather than whichever is current.
            guard await process.switchToBuffer(info.bufnr) else { return NSSound.beep() }
            guard await showSavePanelAndWrite() == .saved else { return }
        } else {
            guard await process.writeBuffer(info.bufnr) == .written else {
                return NSSound.beep()
            }
        }
        await process.deleteBuffer(info.bufnr, force: false)
    }

    /// Runs the standard unsaved-changes sheet for a buffer. An unnamed buffer
    /// offers "Save…", since saving it has to ask for a filename first.
    private static func runSavePrompt(
        for name: String, in window: NSWindow) async -> NSApplication.ModalResponse {
        let displayName = name.isEmpty
            ? NSLocalizedString("Untitled", comment: "An unnamed buffer")
            : (name as NSString).lastPathComponent

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: NSLocalizedString(
                "Do you want to save changes you made in the document “%@”?",
                comment: "Unsaved changes sheet title, given a document name"),
            displayName)
        alert.informativeText = NSLocalizedString(
            "Your changes will be lost if you don’t save them.",
            comment: "Unsaved changes sheet message")
        alert.addButton(withTitle: name.isEmpty
            ? NSLocalizedString("Save…", comment: "Save, asking for a filename")
            : NSLocalizedString("Save", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Don’t Save", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        return await alert.beginSheetModal(for: window)
    }
}
