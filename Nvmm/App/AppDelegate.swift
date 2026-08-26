//
//  Nvmm
//  AppDelegate.swift
//

import Cocoa
import os

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let renderManager = RenderContextManager()
    private let terminationCoordinator = TerminationCoordinator()
    private var controlServer: ControlServer?
    private lazy var helpSearchController = HelpSearchController(
        tagsURL: NeovimBundle.helpTagsURL
    ) { [weak self] topic in
        self?.openHelp(topic)
    }

    // True when the process is a test host rather than the interactive app.
    // A test host must not take the interactive launch path: it holds no
    // windows of its own, and the test runner ends it without a quit, so
    // anything it starts outlives it.
    private static let isTestHost = ProcessInfo.processInfo
        .environment["XCTestConfigurationFilePath"] != nil
    // Set when the helper's launch marker is present, and cleared by the first
    // control request. AppKit's untitled window is suppressed while it is true
    // so the request's own window is the only one.
    private var awaitingInitialCLIRequest =
        ProcessInfo.processInfo.arguments.contains("--nvmm-client")

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
        NSApp.registerUserInterfaceItemSearchHandler(helpSearchController)
        // A test host must not serve the CLI endpoint. It shares the endpoint
        // path with an interactive build, so whichever binds second runs
        // without a control channel; and the socket would outlive the host.
        guard !Self.isTestHost else { return }
        do {
            controlServer = try ControlServer { [weak self] request, channel in
                self?.handleCLIRequest(request, channel: channel)
            }
        } catch let error as CLIError {
            Log.control.error("Control server unavailable: \(error.message)")
        } catch {
            Log.control.error("Control server unavailable: \(error)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Startup wiring checks: confirm the two integration points the rest of
        // the app depends on — the utf8proc bridge and the bundled nvim binary.
        logUTF8ProcVersion()
        logBundledNeovim()
        if awaitingInitialCLIRequest {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.recoverAbandonedCLILaunch()
            }
        }
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
                            directory: String? = nil,
                            arguments: [String] = []) -> WindowController {
        let controller = makeRegisteredController()
        controller.start(files: files, directory: directory,
                         arguments: arguments)
        return controller
    }

    /// Creates a window, cascaded from the frontmost one, and registers it
    /// with the coordinator, but does not start it. The caller chooses how it
    /// reaches Neovim — `start(files:directory:)` to spawn,
    /// `start(connectingTo:)` to connect to a running server.
    private func makeRegisteredController(
        cascadingFrom source: WindowController? = nil
    ) -> WindowController {
        let controller = WindowController(
            renderManager: renderManager,
            coordinator: terminationCoordinator,
            cascadingFrom: source ?? frontmostWindow)
        terminationCoordinator.register(controller)
        return controller
    }

    // MARK: - File menu (no editor window in the responder chain)

    /// New, with no window in the responder chain. A miniaturized window is
    /// still a window to make a document in, so the oldest one that has shown
    /// itself is restored and used. Only with no window at all is a new
    /// window the answer.
    @IBAction func newDocument(_ sender: Any?) {
        guard let controller = windows.first(where: { !$0.isAwaitingFirstShow })
        else {
            // A window still waiting for its first grid is one on its way,
            // so it is left to show itself rather than forced on screen.
            if windows.isEmpty { openWindow() }
            return
        }
        controller.window?.deminiaturize(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.newDocument(sender)
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
        alert.messageText = String(localized: "Connect to Running Neovim")
        alert.informativeText = String(localized:
            "Enter a Neovim server address: a Unix socket path or host:port.")
        alert.addButton(withTitle: String(localized: "Connect"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        // The field is 3 lines tall to accommodate a long socket path.
        let field = PasteTrimmingTextField(
            frame: NSRect(x: 0, y: 0, width: 320, height: 0))
        let font = field.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        field.frame.size.height = ceil(field.fittingSize.height + 2 * lineHeight)
        field.maximumNumberOfLines = 3
        field.placeholderString = "/tmp/nvim.sock or localhost:6666"
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

    /// The CLI's socket request is authoritative when its private launch marker
    /// is present, so AppKit must not race it with an empty window.
    ///
    /// A test host declines outright. Its window would run a Neovim under the
    /// configuration of whoever is running the tests, and the test runner ends
    /// the host without a quit, leaving that Neovim behind.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !awaitingInitialCLIRequest && !Self.isTestHost
    }

    /// Recovers from a launch whose control request never arrived — the helper
    /// was interrupted between launching the app and connecting. Without this
    /// the app keeps running with no window, and nothing asks it for one until
    /// the next reopen.
    private func recoverAbandonedCLILaunch() {
        guard awaitingInitialCLIRequest else { return }
        awaitingInitialCLIRequest = false
        if windows.isEmpty { openWindow() }
    }

    /// Opens an empty window when AppKit asks for one and none is already live.
    ///
    /// A debug launch can deliver its activation/reopen and normal launch
    /// requests in either order. Both may ask for an untitled window, so this
    /// callback must be idempotent. Explicit New and New Window actions bypass
    /// it and always create another window.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if windows.isEmpty { openWindow() }
        return true
    }

    /// Whether a reopen — a Dock click, or an activation arriving from another
    /// app — should get AppKit's default handling.
    ///
    /// A window waits for Neovim's first grid before showing itself, so the app
    /// holds no visible window while one is starting. AppKit answers a reopen in
    /// that state by opening an untitled file, which would make the window
    /// already on its way a second one. Declining leaves it to show itself.
    /// Every other case takes the default: with no window at all a reopen should
    /// open one, and windows that are merely minimized should be restored.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        !windows.contains(where: \.isAwaitingFirstShow)
    }

    /// Opens files handed over by the Finder, the `open` tool, or a service.
    ///
    /// With no window running, the files are passed to a new Neovim as
    /// arguments. Otherwise they are opened over RPC into whichever existing
    /// window suits them best.
    func application(_ application: NSApplication, open urls: [URL]) {
        openApplicationPaths(urls.map(\.path))
    }

    /// Handles a standard Open Recent selection in this non-NSDocument app.
    func application(_ sender: NSApplication,
                     openFile filename: String) -> Bool {
        guard !filename.isEmpty else { return false }
        openApplicationPaths([filename])
        return true
    }

    /// Applies one policy to Open Recent, Finder, `open`, and services.
    private func openApplicationPaths(_ paths: [String]) {
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

    // MARK: - Command-line helper

    private func handleCLIRequest(_ request: CLIRequest,
                                  channel: CLIResponseChannel) {
        // The request is now synchronously registering any window it needs, so
        // the cold-start guard must not suppress a later Dock reopen.
        awaitingInitialCLIRequest = false
        // A warm helper request bypasses LaunchServices. The cooperative
        // `activate()` API does not guarantee activation when the terminal is
        // active, so explicitly take activation for this user-initiated open.
        NSApp.activate(ignoringOtherApps: true)
        let candidates = windows
        if candidates.isEmpty || request.needsNewWindow {
            openCLIWindow(request, channel: channel,
                          cascadingFrom: candidates.last)
            return
        }
        guard !request.files.isEmpty else {
            channel.accepted(wait: false)
            return
        }

        let paths = request.absoluteFiles
        Task { @MainActor in
            if let controller = await self.bestWindow(for: paths,
                                                      among: candidates),
               !controller.hasExited {
                controller.open(paths: paths)
                channel.accepted(wait: false)
            } else {
                self.openCLIWindow(
                    request, channel: channel,
                    cascadingFrom: candidates.last { !$0.hasExited })
            }
        }
    }

    private func openCLIWindow(_ request: CLIRequest,
                               channel: CLIResponseChannel,
                               cascadingFrom source: WindowController?) {
        let controller = makeRegisteredController(cascadingFrom: source)
        if request.wait { controller.setCLIResponseChannel(channel) }
        controller.start(files: request.files,
                         directory: request.workingDirectory,
                         arguments: request.arguments)
        Task {
            switch await controller.waitForStartup() {
            case .started:
                channel.accepted(wait: request.wait)
            case .failed(let message):
                channel.error(message)
            }
        }
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

    func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
    }

    /// Quits every window, confirming discarded changes first and confirming
    /// process termination separately if an orderly quit times out.
    private func drainForQuit() async -> Bool {
        await terminationCoordinator.requestApplicationQuit {
            confirmDiscard(
                message: String(localized: "Quit without saving?"),
                informative: String(localized:
                    "There are modified buffers. If you quit now all changes will be lost."),
                confirmTitle: String(localized: "Quit"))
        } confirmForceTermination: {
            confirmForceTermination()
        }
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
                    message: String(localized: "Close all windows without saving?"),
                    informative: String(localized:
                        "There are modified buffers. If you close all windows now all changes will be lost."),
                    confirmTitle: String(localized:
                        "Close All Windows")) else { return }
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
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Warns before terminating Neovim processes that did not quit normally.
    private func confirmForceTermination() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Neovim Is Not Responding")
        alert.informativeText = String(
            localized:"Force Quit will end the remaining editor sessions. Any unsaved changes will be lost.")
        alert.addButton(withTitle: String(localized: "Force Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Nvmm does not participate in AppKit state restoration, so it does not
    /// claim that restored application state is securely decoded.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    private func logUTF8ProcVersion() {
        // Calls into the vendored C library through the bridging header.
        let version = String(cString: utf8proc_version())
        Log.app.info("utf8proc \(version, privacy: .public)")
    }

    private func logBundledNeovim() {
        if let path = NeovimBundle.executableURL?.path {
            Log.app.info("Bundled Neovim at \(path)")
        } else {
            Log.app.error("Bundled Neovim not found; run Scripts/download_nvim.sh")
        }
    }

    // MARK: - Help menu

    /// Opens a bundled Help-menu result in the frontmost compatible Neovim, or
    /// starts a bundled Neovim when the frontmost session cannot accept it.
    private func openHelp(_ topic: String) {
        guard let controller = frontmostWindow,
              controller.canOpenBundledHelp else {
            openWindow(arguments: ["-c", "help \(topic)"])
            return
        }
        controller.openHelp(topic: topic)
    }

    @IBAction func showHomepage(_ sender: Any?) {
        let url = URL(string: "https://www.mowglii.com/nvmm")!
        NSWorkspace.shared.open(url)
    }
}
