//
//  Nvmm
//  WindowController+FileMenu.swift
//
//  The File menu, as it applies to one window's Neovim.
//
//  Each of these actions is also implemented by `AppDelegate`, which the
//  responder chain reaches when no editor window is in it. New restores a
//  miniaturized window and works in that one; the rest answer with a new
//  window. Either way, "no window" needs no test here: this file only ever
//  runs with a window to act on.
//
//  Every action first asks Neovim what mode it is in and refuses if a command
//  would be swallowed (see `NeovimProcess.prepareForCommand`), which makes them
//  all asynchronous. Panels and alerts are therefore put up after an await;
//  window-modal sheets keep the rest of the app usable meanwhile.
//

import Cocoa
import os

extension WindowController {

    // MARK: - New

    /// Opens an empty document in a buffer or tab page according to the app
    /// preference. Buffer mode uses `:hide enew`, preserving a modified buffer
    /// even when `'hidden'` is off without changing the option permanently.
    @IBAction func newDocument(_ sender: Any?) {
        guard let process else { return }
        Task {
            await process.newDocument(inBuffers: Settings.openFilesInBuffers)
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

    /// Adds a successfully opened file to AppKit's application-wide history.
    func noteRecentDocument(path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
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
            let outcome = await process.writeCurrentBuffer()
            switch outcome {
            case .written: break
            case .needsFilename: _ = await showSavePanelAndWrite()
            case .failed(let detail): await presentSaveError(detail)
            case .awaitingInput:
                await presentSaveAwaitingInput()
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
        let outcome = await process.writeAs(path)
        switch outcome {
        case .written:
            return .saved
        case .needsFilename:
            await presentSaveError(String(localized:
                "Neovim did not complete the save."))
            return .failed
        case .failed(let detail):
            await presentSaveError(detail)
            return .failed
        case .awaitingInput:
            await presentSaveAwaitingInput()
            return .failed
        }
    }

    /// Reports a failed write as a sheet on the document that remains unsaved.
    private func presentSaveError(_ detail: String) async {
        await presentSaveAlert(
            message: String(localized: "Could Not Save Document"),
            detail: detail)
    }

    /// Reports a save that was never sent, because Neovim is waiting for
    /// input. Nothing failed and nothing is queued: the save is made again
    /// once the editor is free.
    private func presentSaveAwaitingInput() async {
        await presentSaveAlert(
            message: String(localized: "Neovim Is Waiting for Input"),
            detail: String(localized:
                "Finish or cancel the pending input, then save again."),
            style: .informational)
    }

    /// Sheets a save report on the document it concerns.
    private func presentSaveAlert(
        message: String, detail: String,
        style: NSAlert.Style = .warning
    ) async {
        Log.app.error("Save reported: \(message): \(detail)")
        guard let window else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "OK"))
        await alert.beginSheetModal(for: window)
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
        // A window onto a borrowed Neovim is a detached view: close it (which
        // drops this UI and leaves that session's Neovim running) without
        // prompting about or quitting buffers that belong to that session.
        if !ownsServer { window?.close(); return }
        guard let process else { return }
        // Neovim blocked awaiting input answers no requests, so the
        // modified-buffer query would time out and the close would do nothing.
        // Terminal Neovim refuses to quit in this state too: report the block,
        // and let the user cancel the pending input first.
        guard await !refuseIfBlocked(process) else { return }
        guard var pending = await process.modifiedBuffers() else { return NSSound.beep() }
        var discarded: [ModifiedBuffer] = []

        while true {
            for buffer in pending {
                switch await promptToSave(buffer) {
                case .saved: continue
                case .discarded: discarded.append(buffer)
                case .cancelled: return
                case .failed: return
                }
            }

            guard let modified = await process.modifiedBuffers() else {
                return NSSound.beep()
            }
            let unexpected = modified.filter { !discarded.contains($0) }
            if unexpected.isEmpty { break }
            pending = unexpected
        }

        // The sheets let the user keep typing, so Neovim can have entered a
        // blocked input state since the entry check — a quit issued now would
        // queue until the user cancels it, leaving the window open for no
        // visible reason. Re-check and report instead.
        guard await !refuseIfBlocked(process) else { return }
        beginQuit(force: true)
    }

    /// Reports the awaiting-input alert and returns true when Neovim is
    /// blocked awaiting input, so close and delete paths refuse to act rather
    /// than send commands that would queue behind the block.
    private func refuseIfBlocked(_ process: NeovimProcess) async -> Bool {
        guard await process.isBlockedAwaitingInput() else { return false }
        await presentAwaitingInputAlert()
        return true
    }

    /// Closes the current buffer. The last buffer means closing the window,
    /// which prompts for every modified buffer; otherwise only this buffer is
    /// at stake, so only it is asked about.
    private func deleteCurrentBuffer() async {
        guard let process else { return }
        // Neovim blocked awaiting input answers no requests, so the buffer
        // query would time out into an unexplained beep. Report instead, as
        // Close Window does for the same state.
        guard await !refuseIfBlocked(process) else { return }
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

        let outcome = await process.writeBuffer(buffer.bufnr)
        switch outcome {
        case .written: return .saved
        case .failed(let detail):
            await presentSaveError(detail)
            return .failed
        case .awaitingInput:
            await presentSaveAwaitingInput()
            return .failed
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
            // the user was asked about rather than whichever is current. The
            // switch reports false only once it is known not to have landed,
            // so proceeding would name the save panel wrong: stop with an
            // explanation instead of a bare beep.
            guard await process.switchToBuffer(info.bufnr) else {
                await presentSaveError(String(localized:
                    "Neovim could not switch to the buffer, so it was not deleted. Check which buffer is current, then try again."))
                return
            }
            guard await showSavePanelAndWrite() == .saved else { return }
        } else {
            let outcome = await process.writeBuffer(info.bufnr)
            switch outcome {
            case .written:
                break
            case .needsFilename:
                guard await showSavePanelAndWrite() == .saved else { return }
            case .failed(let detail):
                await presentSaveError(detail)
                return
            case .awaitingInput:
                await presentSaveAwaitingInput()
                return
            }
        }
        await process.deleteBuffer(info.bufnr, force: false)
    }

    /// Reports that this window's Neovim is blocked awaiting input, as part
    /// of a deferred app quit or close-all. Brings the window to the front —
    /// a miniaturized window would otherwise stay in the Dock while the
    /// report tells the user to act in a window they cannot see — and sheets
    /// the report on it, so it is frontmost and keyed relative to the window
    /// the input is pending in.
    func presentAwaitingInputReport() async {
        NSApp.activate(ignoringOtherApps: true)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        await presentAwaitingInputAlert()
    }

    /// Reports that a close was abandoned because this window's Neovim is
    /// blocked awaiting input — for example the register name after `q`.
    private func presentAwaitingInputAlert() async {
        guard let window else { return NSSound.beep() }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Neovim Is Waiting for Input")
        alert.informativeText = String(localized:
            "Complete or cancel the pending input and try again.")
        alert.addButton(withTitle: String(localized: "OK"))
        _ = await alert.beginSheetModal(for: window)
    }

    /// Runs the standard unsaved-changes sheet for a buffer. An unnamed buffer
    /// offers "Save…", since saving it has to ask for a filename first.
    private static func runSavePrompt(
        for name: String, in window: NSWindow
    ) async -> NSApplication.ModalResponse {
        let displayName = name.isEmpty
        ? String(localized: "Untitled", comment: "An unnamed buffer")
        : (name as NSString).lastPathComponent

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Do you want to save changes you made in the document “\(displayName)”?"
        )
        alert.informativeText = String(
            localized: "Your changes will be lost if you don’t save them.")
        alert.addButton(withTitle: name.isEmpty
                        ? String(localized: "Save…")
                        : String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Don’t Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return await alert.beginSheetModal(for: window)
    }
}
