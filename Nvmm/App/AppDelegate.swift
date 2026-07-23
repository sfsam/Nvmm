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

    // The settings window, created the first time it is asked for and kept so
    // it reopens where it was.
    private var settingsWindow: SettingsWindowController?

    // Defaults are registered before launching, so the first window to read a
    // setting sees the registered value rather than a bare `false`.
    func applicationWillFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Startup wiring checks: confirm the two integration points the rest of
        // the app depends on — the utf8proc bridge and the bundled nvim binary.
        logUTF8ProcVersion()
        logBundledNeovim()
    }

    // MARK: - Windows

    /// The live editor windows, oldest first.
    private var windows: [WindowController] {
        terminationCoordinator.liveSessions.compactMap { $0 as? WindowController }
    }

    /// The frontmost editor window, if one is in the responder chain. New
    /// windows cascade from it so they do not land on top of it.
    private var frontmostWindow: WindowController? {
        NSApp.keyWindow?.windowController as? WindowController
            ?? NSApp.mainWindow?.windowController as? WindowController
    }

    /// Creates a window, registers it, and starts its Neovim on `files`.
    ///
    /// The coordinator owns the window for its lifetime; it deregisters itself
    /// when it closes. The window shows itself once Neovim's first grid is
    /// ready, so its first paint is the intro screen rather than a blank frame.
    @discardableResult
    private func openWindow(files: [String] = [],
                            directory: String? = nil) -> WindowController {
        let controller = makeRegisteredController()
        controller.start(files: files, directory: directory)
        return controller
    }

    /// Creates a window, cascaded from the frontmost one, and registers it
    /// with the coordinator, but does not start it. The caller chooses how it
    /// reaches Neovim — `start(files:directory:)` to spawn,
    /// `start(connectingTo:)` to connect to a running server.
    private func makeRegisteredController() -> WindowController {
        let controller = WindowController(renderManager: renderManager,
                                          coordinator: terminationCoordinator,
                                          cascadingFrom: frontmostWindow)
        terminationCoordinator.register(controller)
        return controller
    }

    // MARK: - File menu (no editor window in the responder chain)

    /// New, with no window to make a document in: a new window is one.
    @IBAction func newDocument(_ sender: Any?) {
        openWindow()
    }

    /// New Window. Always a new window, so it is only implemented here.
    @IBAction func newWindow(_ sender: Any?) {
        openWindow()
    }

    /// Connect to Running Neovim…: prompts for the address of a Neovim server
    /// and opens a window attached to it, rather than spawning a new Neovim.
    @IBAction func connectToRunningNvim(_ sender: Any?) {
        guard let address = promptForServerAddress() else { return }
        makeRegisteredController().start(connectingTo: address)
    }

    /// Asks for a Neovim server address, returning it trimmed, or nil if the
    /// user cancelled or left it empty.
    private func promptForServerAddress() -> String? {
        let alert = NSAlert()
        alert.messageText = "Connect to Running Neovim"
        alert.informativeText = "Enter the Unix socket path of a running Neovim "
            + "server.\nStart one with:  nvim --listen /tmp/nvim.sock --headless"
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "/tmp/nvim.sock"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let address = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty ? nil : address
    }

    /// Open…, with no window to open into: the files open in a new window,
    /// where nvim's own arguments place them in tabs or buffers.
    @IBAction func openDocument(_ sender: Any?) {
        let paths = WindowController.runOpenPanel()
        guard !paths.isEmpty else { return }
        openWindow(files: paths)
    }

    // MARK: - Opening files from outside the app

    /// Whether launching should open an empty window. Always yes: the app has
    /// no other way to be told what to open at launch.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    /// Opens the empty window AppKit asks for at launch, and when the app is
    /// activated with no windows open.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        openWindow()
        return true
    }

    /// Opens files handed over by the Finder, the `open` tool, or a service.
    ///
    /// With no window running, the files are passed to a new Neovim as
    /// arguments. Otherwise they are opened over RPC into whichever existing
    /// window suits them best.
    func application(_ application: NSApplication, open urls: [URL]) {
        let paths = urls.map(\.path)
        guard !paths.isEmpty else { return }
        let candidates = windows
        if candidates.isEmpty {
            openWindow(files: paths)
            return
        }
        Task {
            await self.bestWindow(for: paths, among: candidates)?.open(paths: paths)
        }
    }

    /// The window best suited to opening `paths`: the one with the most of them
    /// already open, since that is where the user has been working with these
    /// files. Windows are asked in parallel and slow answers are simply missing
    /// from the tally rather than holding the open up.
    ///
    /// With no window ahead on that count, the frontmost window takes them, and
    /// failing that the oldest.
    private func bestWindow(for paths: [String],
                            among candidates: [WindowController]) async -> WindowController? {
        guard !candidates.isEmpty else { return nil }

        // The processes are actors, so the queries can be handed to a task
        // group and run concurrently; the windows that own them cannot.
        let processes = candidates.map(\.process)
        let counts = await withTaskGroup(of: (Int, Int?).self) { group in
            for (index, process) in processes.enumerated() {
                group.addTask { (index, await process?.openCount(paths)) }
            }
            var counts: [Int: Int] = [:]
            for await (index, count) in group { counts[index] = count }
            return counts
        }

        var best: WindowController?
        var mostOpen = 0
        for (index, controller) in candidates.enumerated() {
            guard let count = counts[index], count > mostOpen else { continue }
            mostOpen = count
            best = controller
        }
        return best ?? frontmostWindow ?? candidates.first
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

    /// Whether closing the last window quits the app. Read on each close, so
    /// changing the setting takes effect from the next one.
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication) -> Bool {
        Settings.terminateAfterLastWindow
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

    // MARK: - Settings

    /// Shows the settings window, which edits the defaults in place.
    @IBAction func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.showWindow(sender)
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
