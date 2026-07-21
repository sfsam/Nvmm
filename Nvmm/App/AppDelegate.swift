//
//  Nvmm
//  AppDelegate.swift
//

import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let renderManager = RenderContextManager()
    private let terminationCoordinator = TerminationCoordinator()

    // True while a termination check is awaiting Neovim; a second quit request
    // in that window is answered with `.terminateLater` so the in-flight check's
    // reply is the one that decides, rather than starting an overlapping drain.
    private var terminationInFlight = false

    // True while a Close All Windows request is draining, so a repeated
    // invocation does not start an overlapping close.
    private var closeAllInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Startup wiring checks: confirm the two integration points the rest of
        // the app depends on — the utf8proc bridge and the bundled nvim binary.
        logUTF8ProcVersion()
        logBundledNeovim()

        // The coordinator owns the window for its lifetime; it deregisters
        // itself when it closes.
        let controller = WindowController(renderManager: renderManager,
                                          coordinator: terminationCoordinator)
        terminationCoordinator.register(controller)
        // The controller shows its window once Neovim's first grid is ready,
        // so the first paint is the intro screen rather than a blank frame.
        controller.start()
    }

    func applicationShouldTerminate(
        _ sender: NSApplication) -> NSApplication.TerminateReply {
        // A second quit while a check or drain is already running defers to it.
        if terminationInFlight { return .terminateLater }
        // No windows left: terminate at once.
        if terminationCoordinator.isEmpty { return .terminateNow }
        terminationInFlight = true
        Task {
            let exited = await self.drainForQuit()
            self.terminationInFlight = false
            sender.reply(toApplicationShouldTerminate: exited)
        }
        return .terminateLater
    }

    /// Quits every window, prompting first (app-modal) if any have unsaved
    /// buffers. Returns whether they all exited: a clean quit drains
    /// non-forced; unsaved buffers ask the user, and a confirmation drains
    /// forced (discarding) while Cancel returns false so the app stays running.
    private func drainForQuit() async -> Bool {
        if await terminationCoordinator.anyUnsavedBuffers() {
            guard confirmDiscard(
                message: "Quit without saving?",
                informative: "There are modified buffers. "
                    + "If you quit now all changes will be lost.",
                confirmTitle: "Quit") else { return false }
            return await terminationCoordinator.requestQuitAll(force: true)
        }
        return await terminationCoordinator.requestQuitAll(force: false)
    }

    /// Closes every window, prompting first (app-modal) if any have unsaved
    /// buffers. Unlike Quit, the app keeps running once the windows close.
    @IBAction func closeAllWindows(_ sender: Any?) {
        if closeAllInFlight { return }
        closeAllInFlight = true
        Task {
            defer { self.closeAllInFlight = false }
            if await terminationCoordinator.anyUnsavedBuffers() {
                guard confirmDiscard(
                    message: "Close all windows without saving?",
                    informative: "There are modified buffers. If you close "
                        + "all windows now all changes will be lost.",
                    confirmTitle: "Close All Windows") else { return }
                _ = await terminationCoordinator.requestQuitAll(force: true)
            } else {
                _ = await terminationCoordinator.requestQuitAll(force: false)
            }
        }
    }

    /// Shows an app-modal warning alert with a destructive confirm button and
    /// a Cancel button. Returns true if the user chose to proceed.
    private func confirmDiscard(message: String, informative: String,
                               confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func logUTF8ProcVersion() {
        // Calls into the vendored C library through the bridging header.
        let version = String(cString: utf8proc_version())
        NSLog("Nvmm: utf8proc \(version)")
    }

    private func logBundledNeovim() {
        if let path = NeovimBundle.executableURL?.path {
            NSLog("Nvmm: bundled nvim at \(path)")
        } else {
            NSLog("Nvmm: bundled nvim NOT found (run Scripts/download_nvim.sh)")
        }
    }
}
