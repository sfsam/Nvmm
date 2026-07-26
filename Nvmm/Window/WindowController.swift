//
//  Nvmm
//  WindowController.swift
//
//  Owns a grid view and the Neovim process that drives it.
//
//  The window uses a full-size content view; the grid view is a subview inset
//  by a margin on the leading and trailing edges (the trailing inset grows to
//  hold the vertical scrollbar when it is shown) and pinned to the content
//  view's safe area at the top and its bottom edge, via Auto Layout. On start
//  the controller sizes the window to a starting grid, spawns an embedded
//  Neovim, and attaches a UI. It then streams flushed grid snapshots into the
//  view and forwards user input — keys, mouse, and window resize — to Neovim
//  through one ordered command channel. The window is authoritative for size:
//  a resize resizes the Neovim grid to fill it, and when a live resize ends
//  the window snaps to the exact grid size so no partial cell is left over.
//  Focus mirrors into `nvim_ui_set_focus` and the view's active state.
//

import Cocoa
import CoreText

/// Whether a window reached its Neovim transport or failed before it could.
///
/// The CLI acknowledges a new-window request at this boundary: the child
/// exists and owns its RPC pipes, but Nvmm does not wait for configuration,
/// UI attachment, or the first rendered grid.
nonisolated enum WindowStartupOutcome: Sendable, Equatable {
    case started
    case failed(String)
}

final class WindowController: NSWindowController, NSWindowDelegate, QuitSession {
    // MARK: - State

    private let gridView = GridView(frame: .zero)
    private let scroller = Scroller(frame: .zero)
    private let progressIndicator = ProgressIndicator(frame: .zero)
    private var renderManager: RenderContextManager!
    // The Neovim this window drives. Readable by the File menu actions, which
    // live in an extension; nil before `start()` and after the window closes.
    private(set) var process: NeovimProcess?

    // The app-wide window registry; held weakly to avoid a retain cycle (the
    // coordinator holds its windows strongly). Used to deregister on close.
    private weak var coordinator: TerminationCoordinator?

    // Quit state for `QuitSession`. `hasExited` becomes true once Neovim has
    // disconnected and the window has closed.
    private(set) var hasExited = false

    private var renderTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var modifiedTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?

    // The ordered channel from main-actor input handlers to the process actor.
    private let commands: AsyncStream<NvimCommand>
    private let commandsContinuation: AsyncStream<NvimCommand>.Continuation

    // True once the UI is attached; gates resize and focus forwarding so events
    // during initial layout do not reach Neovim before it is listening.
    private var isReady = false
    private var lastGridSize = GridSize(width: 0, height: 0)

    // The window is shown only once the first grid is ready, so its first paint
    // is the Neovim intro rather than a blank frame. `shouldCenter` is set when
    // there is no saved frame to place the window at.
    private var hasShownWindow = false
    private var shouldCenter = false

    /// True while the window is on its way but not yet on screen. The app can
    /// hold no visible window in this state, which callers that would answer
    /// that by opening another window need to be able to tell apart.
    var isAwaitingFirstShow: Bool { !hasShownWindow }

    // The first paint is held until Neovim signals `VimEnter` (startup config,
    // notably `guifont`, applied), so the window never appears at an interim
    // font. `startupRelaxed` drops that requirement after a short fallback so a
    // config that never reaches `VimEnter` still shows; `hasReceivedGrid` gates
    // the relaxed show on there being something to draw.
    private var startupRelaxed = false
    private var hasReceivedGrid = false
    private var startupTimeoutTask: Task<Void, Never>?

    // Caps how long the window can stay hidden regardless of how startup
    // stalls. Independent of `startupTimeoutTask`, which only runs once Neovim
    // has attached and so cannot bound a stall before that.
    private var hiddenWindowBackstopTask: Task<Void, Never>?

    // The first transport-start result and callers awaiting it. Normal GUI
    // launches do not wait; the CLI does so it can report a spawn failure.
    private var startupOutcome: WindowStartupOutcome?
    private var startupWaiters:
        [CheckedContinuation<WindowStartupOutcome, Never>] = []

    // A waiting CLI request associated with this window. It observes closure
    // but does not own the window or affect its quit behavior.
    private var cliResponseChannel: CLIResponseChannel?

    // The title Neovim last set. Shown while the window is not being resized; a
    // live resize replaces it with the grid size and restores it when it ends.
    private var currentTitle = "NVIM"

    // The default background color last applied to the window, so the content
    // background and title-bar appearance are only updated when it changes.
    private var lastBackground = RGBColor()

    // Persisted as the window's top-left point plus its grid size (not its pixel
    // size, which is recomputed from the grid and cell size), so a restore is
    // robust across font and display-scale changes.
    private static let savedFrameKey = "NvmmWindowFrame"

    // Live resizes nest in principle (a second can begin before the first
    // reconciles), so track depth rather than a flag; the window snaps to the
    // grid only when the outermost one ends.
    private var liveResizeDepth = 0

    // Layout metrics. The grid view is inset by `gridMargin` on the leading and
    // trailing edges; the trailing inset grows by the scroller's width while
    // the scrollbar is shown. The window cannot shrink below `minGridColumns` ×
    // `minGridRows`.
    private let gridMargin: CGFloat = 4
    private let minGridColumns = 12
    private let minGridRows = 3

    // The grid size the window opens at.
    private let startColumns = 80
    private let startRows = 24

    // The unscaled point size used for the default font, and for any `guifont`
    // entry that omits a `:h<size>` suffix.
    private let defaultFontSize: CGFloat = 15

    // The `guifont` option last applied, so the font is only rebuilt on a
    // change (an empty string is the default: the monospaced system font).
    private var currentGuifont = ""

    // Constraints kept so they can be adjusted without rebuilding the layout:
    // the min-size pair on a font change, the trailing inset as the scrollbar
    // comes and goes.
    private var gridMinWidthConstraint: NSLayoutConstraint!
    private var gridMinHeightConstraint: NSLayoutConstraint!
    private var gridTrailingConstraint: NSLayoutConstraint!

    // Pins the grid view's width for the duration of the scrollbar animation,
    // so the window resizes around the grid rather than the grid reflowing.
    // Held here rather than captured by the animation's completion handler,
    // which is a Sendable closure and cannot carry a constraint across. The
    // counter identifies the animation in flight, so a completion belonging to
    // one that has since been superseded can be told apart and ignored.
    private var scrollbarWidthHold: NSLayoutConstraint?
    private var scrollbarAnimation: UInt64 = 0

    // Whether the scrollbar is showing. Tracked rather than read back from the
    // scroller because it is the target state during the show/hide animation,
    // which outlives the moment the setting changed.
    private var isScrollbarVisible = false

    // The percentage the progress bar would show, independent of whether the
    // setting lets it: turning the setting back on mid-task shows the bar
    // rather than waiting for the next report. Nil means nothing to show.
    private var progressPercent: Int?

    // Bumped on every progress report, so the delayed fallback after a
    // completed task is dropped if a newer report has since arrived.
    private var progressGeneration: UInt64 = 0
    private var progressHoldTask: Task<Void, Never>?

    // Set while the scrollbar animation is resizing the window, so the resize
    // is not mistaken for the user's and forwarded to Neovim: the grid keeps
    // its size in cells throughout, only the window around it changes.
    private var isTogglingScrollbar = false

    // The window this one was opened from, if any. A window opened while
    // another is on screen adopts that window's grid size and cascades from it,
    // rather than restoring the saved frame on top of it.
    private weak var cascadeSource: WindowController?

    // The files and allowlisted Neovim options this window opens with, and the
    // directory it starts in. Set before `start()`.
    private var startupFiles: [String] = []
    private var startupArguments: [String] = []
    private var startupDirectory: String?

    /// How this window reaches Neovim: spawn an embedded process, or connect to
    /// one already running (a `:connect`/`:restart` handoff, or the "Connect to
    /// Running Neovim…" menu). Set before `start()` and on a handoff.
    private enum Source: Sendable {
        case spawn
        case remote(address: String)
    }
    private var source: Source = .spawn

    /// Whether this window owns its Neovim. True when it spawned it or
    /// restarted it (`:restart` continues our own session), false when it
    /// merely connected to a server someone else runs. An owned Neovim is quit
    /// when the window closes; a borrowed one is only detached from, and its
    /// buffers are never prompted about here. Independent of `source`: after
    /// `:restart` the server is reached over a socket yet is still owned.
    var ownsServer = true

    /// The kind of the handoff that produced the current connection, if any, so
    /// a `:restart` whose successor was abandoned (`ENOENT`) is closed quietly
    /// rather than reported as a connection error. Cleared once a reconnection
    /// succeeds.
    private var lastHandoffKind: UIHandoff.Kind?

    /// The address (`v:servername`) of the currently-attached Neovim, captured
    /// after each attach so a failed `:connect` can fall back to it.
    private var currentServerAddress: String?

    /// The server to return to if a `:connect` to a new address fails: the one
    /// we detached from, which stays alive for a plain `:connect`. `:connect`
    /// detaches the current UI before the new address is known good, so a bad
    /// address would otherwise orphan the old Neovim; instead we reconnect to
    /// it. Set on a connect handoff, cleared once consumed.
    private var connectFallback: (address: String, owned: Bool)?

    /// The server address this window connects to, or nil when it spawns
    /// its own Neovim. Used to name the address in a connection-failure alert.
    private var remoteAddress: String? {
        if case .remote(let address) = source { return address }
        return nil
    }

    // MARK: - Lifecycle

    convenience init(renderManager: RenderContextManager,
                     coordinator: TerminationCoordinator,
                     cascadingFrom source: WindowController? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Nvmm"
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = Settings.titlebarAppearsTransparent
        self.init(window: window)
        self.renderManager = renderManager
        self.coordinator = coordinator
        self.cascadeSource = source
        window.delegate = self
        window.registerForDraggedTypes([.fileURL])
        observeSettings()
    }

    override init(window: NSWindow?) {
        let stream = AsyncStream.makeStream(of: NvimCommand.self)
        commands = stream.stream
        commandsContinuation = stream.continuation
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Starting the session

    /// Enqueues a command for the process, preserving order across input sources.
    private func enqueue(_ command: NvimCommand) {
        commandsContinuation.yield(command)
    }

    /// Configures rendering and launches Neovim, opening `files` at startup.
    ///
    /// `directory` is the working directory Neovim starts in; when nil it is
    /// derived from the first file, falling back to the invoking shell's
    /// working directory and then the home directory.
    func start(files: [String] = [], directory: String? = nil,
               arguments: [String] = []) {
        startupFiles = files
        startupArguments = arguments
        startupDirectory = directory
        source = .spawn
        launch()
    }

    /// Waits for the first transport start attempt to succeed or fail.
    ///
    /// The result is retained, so a caller arriving after the spawn completed
    /// receives it immediately. Reconnection does not change the first result.
    func waitForStartup() async -> WindowStartupOutcome {
        if let startupOutcome { return startupOutcome }
        return await withCheckedContinuation { continuation in
            startupWaiters.append(continuation)
        }
    }

    func setCLIResponseChannel(_ channel: CLIResponseChannel) {
        cliResponseChannel = channel
    }

    private func resolveStartup(_ outcome: WindowStartupOutcome) {
        guard startupOutcome == nil else { return }
        startupOutcome = outcome
        let waiters = startupWaiters
        startupWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: outcome) }
    }

    /// Configures rendering and connects to an already-running Neovim listening
    /// on `address` (a Unix domain socket path), attaching a UI to it. The
    /// window is a detached view: closing it leaves that Neovim running.
    func start(connectingTo address: String) {
        source = .remote(address: address)
        ownsServer = false
        launch()
    }

    private func launch() {
        guard let window else {
            resolveStartup(.failed("Could not create an editor window."))
            return
        }
        guard let screen = window.screen ?? NSScreen.main else {
            resolveStartup(.failed("No display is available."))
            handleDisconnect()
            return
        }

        let context: RenderContext
        do {
            context = try renderManager.renderContext(for: screen)
        } catch {
            NSLog("Nvmm: no Metal render context: \(error)")
            resolveStartup(.failed("Could not initialize Metal: "
                                   + error.localizedDescription))
            handleDisconnect()
            return
        }
        gridView.setRenderContext(context)

        let descriptor = FontManager.defaultDescriptor()
        let font = renderManager.fontManager.family(
            descriptor: descriptor, size: defaultFontSize,
            scaleFactor: screen.backingScaleFactor)
        gridView.setFont(font)

        installGridView(in: window)
        window.animationBehavior = .none
        window.resizeIncrements = gridView.cellSize
        window.initialFirstResponder = gridView
        placeWindow(window)
        resizeWindow(in: screen)
        if shouldCenter { window.center() }

        gridView.sendInput = { [weak self] input in
            self?.enqueue(.input(input))
        }
        gridView.sendMouse = { [weak self] button, action, modifiers, row, col in
            self?.enqueue(.mouse(button: button, action: action,
                                 modifiers: modifiers, row: row, col: col))
        }
        gridView.sendPaste = { [weak self] text in
            self?.enqueue(.paste(text))
        }
        gridView.sendFeedkeys = { [weak self] keys in
            self?.enqueue(.feedkeys(keys))
        }
        gridView.fetchCompositionGeometry = { [weak self] in
            await self?.process?.getCompositionGeometry() ?? nil
        }
        gridView.fetchVisualSelection = { [weak self] in
            await self?.process?.getVisualSelection() ?? nil
        }
        scroller.onScroll = { [weak self] line in
            self?.scrollToLine(line)
        }

        startNeovim()
    }

    /// Builds the content-view → grid-view hierarchy and its constraints.
    private func installGridView(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true
        gridView.translatesAutoresizingMaskIntoConstraints = false
        scroller.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scroller)
        contentView.addSubview(gridView)
        contentView.addSubview(progressIndicator)

        isScrollbarVisible = Settings.verticalScrollbar
        scroller.isHidden = !isScrollbarVisible

        let cell = gridView.cellSize
        let safeArea = contentView.safeAreaLayoutGuide
        gridMinWidthConstraint = gridView.widthAnchor.constraint(
            greaterThanOrEqualToConstant: cell.width * CGFloat(minGridColumns))
        gridMinHeightConstraint = gridView.heightAnchor.constraint(
            greaterThanOrEqualToConstant: cell.height * CGFloat(minGridRows))
        gridTrailingConstraint = contentView.trailingAnchor.constraint(
            equalTo: gridView.trailingAnchor, constant: trailingInset)

        NSLayoutConstraint.activate([
            gridView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            gridView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            gridView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor,
                                              constant: gridMargin),
            gridTrailingConstraint,
            gridMinWidthConstraint,
            gridMinHeightConstraint,

            // The scrollbar runs the full height of the grid, flush with the
            // trailing edge: it takes the margin's place rather than sitting
            // inside it.
            scroller.topAnchor.constraint(equalTo: safeArea.topAnchor),
            scroller.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            scroller.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scroller.widthAnchor.constraint(equalToConstant: Scroller.width),

            // The progress bar rides the top edge of the grid, spanning it and
            // its margins, so it reads as part of the window's edge rather than
            // as something drawn in the text.
            progressIndicator.topAnchor.constraint(equalTo: safeArea.topAnchor),
            progressIndicator.leadingAnchor.constraint(
                equalTo: gridView.leadingAnchor, constant: -gridMargin),
            progressIndicator.trailingAnchor.constraint(
                equalTo: gridView.trailingAnchor, constant: gridMargin),
            progressIndicator.heightAnchor.constraint(
                equalToConstant: ProgressIndicator.thickness),
        ])
        contentView.layoutSubtreeIfNeeded()
    }

    // MARK: - Window geometry

    /// The inset between the grid view's trailing edge and the window's: the
    /// margin, plus the scrollbar's width while it is shown.
    private var trailingInset: CGFloat {
        gridMargin + (isScrollbarVisible ? Scroller.width : 0)
    }

    /// The insets between the window frame and the grid view: the leading and
    /// trailing margins horizontally, the safe area (title bar) vertically.
    private var gridInsets: (horizontal: CGFloat, top: CGFloat) {
        // The trailing inset is read from the setting, not from the constraint,
        // which holds an intermediate value while the scrollbar animates.
        (gridMargin + trailingInset,
         window?.contentView?.safeAreaInsets.top ?? 0)
    }

    /// Sizes the window so its grid view is `lastGridSize` cells, clamping the
    /// grid to what fits the screen and anchoring the window's top-left corner.
    /// Used for the initial frame and whenever Neovim changes the grid size
    /// itself (see `reconcileWindowSize`); a user-driven resize is handled by the
    /// window and the end-of-resize snap instead.
    private func resizeWindow(in screen: NSScreen?) {
        guard let window, let screen else { return }
        let cell = gridView.cellSize
        let visible = screen.visibleFrame
        let (horizontalInsets, topInset) = gridInsets
        var frame = window.frame

        // Height: clamp the grid to the screen, then keep the top edge fixed.
        let maxRows = floor((visible.height - topInset) / cell.height)
        let rows = min(maxRows, CGFloat(lastGridSize.height))
        let height = cell.height * rows + topInset
        frame.origin.y = max(visible.origin.y,
                             frame.origin.y + frame.height - height)
        frame.size.height = height

        // Width: clamp to the screen and keep the left edge on screen. Skipped
        // across horizontally-tiled displays sharing a Space, where clamping the
        // x origin would misplace the window.
        if NSScreen.screensHaveSeparateSpaces || NSScreen.screens.count == 1 {
            let maxColumns = floor((visible.width - horizontalInsets) / cell.width)
            let columns = min(maxColumns, CGFloat(lastGridSize.width))
            let width = cell.width * columns + horizontalInsets
            frame.origin.x = min(frame.origin.x,
                                 visible.origin.x + visible.width - width)
            frame.size.width = width
        }

        window.setFrame(frame, display: true)
    }

    /// Positions the window and picks the grid size it opens at: cascaded from
    /// the window it was opened from, if there is one, otherwise restored from
    /// the saved frame. Cascading keeps a second window from landing exactly on
    /// top of the first, which restoring the one saved frame would do.
    private func placeWindow(_ window: NSWindow) {
        guard let source = cascadeSource, let sourceWindow = source.window else {
            loadSavedFrame(in: window)
            return
        }
        lastGridSize = source.lastGridSize
        let frame = sourceWindow.frame
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        window.setFrameTopLeftPoint(sourceWindow.cascadeTopLeft(from: topLeft))
    }

    /// Restores the saved grid size and window position, or falls back to the
    /// starting grid centered on screen when there is nothing saved. The saved
    /// pixel size is deliberately not restored; `resizeWindow` recomputes it
    /// from the grid and current cell size.
    private func loadSavedFrame(in window: NSWindow) {
        if let string = UserDefaults.standard.string(forKey: Self.savedFrameKey) {
            let saved = NSRectFromString(string)
            lastGridSize = GridSize(
                width: max(minGridColumns, Int(saved.size.width)),
                height: max(minGridRows, Int(saved.size.height)))
            window.setFrameTopLeftPoint(saved.origin)
        } else {
            lastGridSize = GridSize(width: startColumns, height: startRows)
            shouldCenter = true
        }
    }

    /// Persists the window's top-left point and current grid size for the next
    /// launch. No-op until the window is on screen so a half-built frame is
    /// never saved.
    private func saveFrame() {
        guard hasShownWindow, let window else { return }
        var rect = window.frame
        rect.origin.y += rect.size.height
        rect.size = CGSize(width: lastGridSize.width, height: lastGridSize.height)
        UserDefaults.standard.set(NSStringFromRect(rect), forKey: Self.savedFrameKey)
    }

    /// Re-fits the window when Neovim changed the grid size on its own — for
    /// example `:set lines`/`columns`, or a restart. A change the window itself
    /// drove (a user resize, so the new grid already matches what the window
    /// fits) is left alone, as is any change during a live resize.
    private func reconcileWindowSize(to gridSize: GridSize) {
        guard gridSize != lastGridSize else { return }
        lastGridSize = gridSize
        if liveResizeDepth == 0 && gridSize != gridView.desiredGridSize {
            resizeWindow(in: window?.screen)
        }
    }

    // MARK: - Neovim session

    /// Builds Neovim argv after the executable name.
    ///
    /// Forwarded arguments retain their order. This preserves both `-c` and its
    /// value and the execution order of `-c` and `+` commands. The tab
    /// preference is expressed as a leading `-p`, but only when the caller did
    /// not choose a layout itself: Neovim takes one layout from `-d`, `-o`,
    /// `-O`, and `-p`, so with `-d` the added `-p` would win the layout slot
    /// and leave one file per tab with nothing to diff against.
    ///
    /// A `--` separates the options from the files, so a name beginning with
    /// `+` or `-` opens as the file it is rather than being read as a command
    /// or an option. Neovim then treats a lone `-` as a file too, which is
    /// what it has to be here: standard input belongs to the RPC transport.
    nonisolated static func neovimArguments(
        options: [String], files: [String], openFilesInBuffers: Bool
    ) -> [String] {
        var arguments = ["--embed"]
        if !files.isEmpty, !openFilesInBuffers, !forwardsLayout(options) {
            arguments.append("-p")
        }
        arguments += options
        if !files.isEmpty {
            arguments.append("--")
            arguments += files
        }
        return arguments
    }

    /// Whether `options` already chooses a window layout. A `-c` value is
    /// skipped so a command that looks like an option is not mistaken for one.
    private nonisolated static func forwardsLayout(
        _ options: [String]
    ) -> Bool {
        var index = 0
        while index < options.count {
            if options[index] == "-c" {
                index += 2
            } else if ["-d", "-o", "-O", "-p"].contains(options[index]) {
                return true
            } else {
                index += 1
            }
        }
        return false
    }

    private func neovimArguments() -> [String] {
        Self.neovimArguments(options: startupArguments, files: startupFiles,
                             openFilesInBuffers: Settings.openFilesInBuffers)
    }

    /// The directory Neovim starts in: the caller's, else the first startup
    /// file's, else the working directory Nvmm was invoked from. Launched from
    /// the Finder there is no such directory, so the home directory is used —
    /// never the app's own, which is the filesystem root.
    private func workingDirectory() -> String {
        if let startupDirectory, !startupDirectory.isEmpty { return startupDirectory }
        if let file = startupFiles.first {
            return (file as NSString).deletingLastPathComponent
        }
        let shellDirectory = ProcessInfo.processInfo.environment["PWD"]
        return shellDirectory ?? NSHomeDirectory()
    }

    /// How the render task reaches Neovim, resolved on the main actor before
    /// the process is created so a missing bundle fails before any stream
    /// exists.
    ///
    /// Deliberately distinct from `Source`, which it is derived from: `Source`
    /// is persistent window state (it survives a reconnect and names the
    /// transport), while `LaunchPlan` is the transient, `Sendable` payload
    /// handed to the render task — carrying the spawn arguments resolved here
    /// so the task need not touch the main actor to build them.
    private enum LaunchPlan: Sendable {
        case spawn(path: String, argv: [String], directory: String)
        case connect(address: String)
    }

    private func startNeovim() {
        startHiddenWindowBackstop()

        let plan: LaunchPlan
        switch source {
        case .spawn:
            guard let nvimPath = NeovimBundle.executableURL?.path else {
                NSLog("Nvmm: bundled nvim not found")
                resolveStartup(.failed("Bundled Neovim executable not found."))
                handleDisconnect()
                return
            }
            let launch = NeovimBundle.launchCommand(nvimPath: nvimPath,
                                                    arguments: neovimArguments())
            plan = .spawn(path: launch.path, argv: launch.argv,
                          directory: workingDirectory())
        case .remote(let address):
            plan = .connect(address: address)
        }

        let process = NeovimProcess()
        self.process = process
        let columns = lastGridSize.width
        let rows = lastGridSize.height

        // One consumer for the window's life applies queued commands in
        // order, forwarding to whichever process is current. It is created
        // once and survives a reconnect (which swaps the process): the command
        // stream has a single iterator, so re-iterating it from a new task
        // would deliver nothing. A reconnect updates `self.process`, which this
        // loop then picks up.
        if inputTask == nil {
            let commands = self.commands
            inputTask = Task { [weak self] in
                for await command in commands {
                    await self?.process?.perform(command)
                }
            }
        }

        // Mirror the current buffer's modified state into the window's
        // document-edited dot as Neovim reports transitions.
        modifiedTask = Task { [weak self] in
            for await modified in process.modifiedStates {
                self?.window?.isDocumentEdited = modified
            }
        }

        // Show the progress of Neovim's running tasks as it reports them.
        progressTask = Task { [weak self] in
            for await update in process.progressUpdates {
                self?.applyProgress(update)
            }
        }

        renderTask = Task { [weak self] in
            do {
                switch plan {
                case .spawn(let path, let argv, let directory):
                    try await process.spawn(path: path, argv: argv,
                                            workingDirectory: directory)
                case .connect(let address):
                    try await process.connect(address)
                }
                self?.resolveStartup(.started)
            } catch {
                NSLog("Nvmm: failed to start nvim: \(error)")
                let code = (error as? NeovimSpawnError)?.code
                if let kind = self?.lastHandoffKind, let code,
                   handoffConnectionErrorIsStale(kind, code) {
                    // A `:restart` whose successor Neovim abandoned: it removed
                    // the socket, so the connect fails with `ENOENT`. Not a
                    // user-visible error — just close the window.
                    self?.handleDisconnect()
                    return
                }
                let reason = (error as? NeovimSpawnError)?.message
                    ?? error.localizedDescription
                self?.resolveStartup(.failed(reason))
                // A failed `:connect`: return to the server we detached from
                // (still alive for a plain `:connect`) rather than orphaning
                // it, noting that the new address was unreachable.
                if let self, let fallback = self.connectFallback {
                    self.recoverToFallback(fallback, reason: reason)
                    return
                }
                if let address = self?.remoteAddress {
                    self?.presentConnectionError(
                        "Could not connect to a Neovim server at “\(address)”.",
                        detail: reason)
                }
                self?.handleDisconnect()
                return
            }

            var options = UIOptions()
            options.extLinegrid = true
            let result = await process.uiAttach(
                width: columns, height: rows, options: options)

            guard result.status == .success else {
                NSLog("Nvmm: UI attach failed: \(result.message)")
                if let address = self?.remoteAddress {
                    self?.presentConnectionError(
                        "Connected to “\(address)”, but attaching a UI failed.",
                        detail: result.message)
                }
                self?.handleDisconnect()
                return
            }

            // Answer Neovim's clipboard requests from the system pasteboard,
            // then point its provider at this UI. Registered before the
            // provider is installed so no request can arrive unhandled.
            await process.registerRequestHandler("clipboard_get", Clipboard.get)
            await process.registerRequestHandler("clipboard_set", Clipboard.set)
            await process.installClipboardProvider()

            // Remember this server's address so a later `:connect` that fails
            // can fall back to it rather than orphaning it.
            let servername = try? await process.request(
                "nvim_eval", [.string("v:servername")])
            let address = servername?.result.stringValue

            guard let self else { return }
            self.isReady = true
            // The connection is up, so a later drop is a real disconnect, not a
            // handoff that failed to connect.
            self.lastHandoffKind = nil
            if let address, !address.isEmpty { self.currentServerAddress = address }
            self.startStartupTimeout()

            for await grid in process.grids {
                self.applyGuifont(grid.guifont)
                self.applyBackground(grid.defaultBackground)
                self.gridView.setGrid(grid)
                self.scroller.update(topline: grid.viewport.topline,
                                     botline: grid.viewport.botline,
                                     lineCount: grid.viewport.lineCount)
                self.hasReceivedGrid = true
                if !self.hasShownWindow, grid.startupComplete || self.startupRelaxed {
                    self.showInitialWindow()
                }
                self.currentTitle = grid.title
                if self.liveResizeDepth == 0 { self.window?.title = self.currentTitle }
                self.reconcileWindowSize(to: grid.size)
            }

            // The grid stream ends when Neovim disconnects. If Neovim asked
            // for a handoff (`:restart`/`:connect`) before closing, reconnect
            // to the new server, reusing this window; otherwise it quit or
            // exited (`:qa`, a crash), so close the window to match.
            if let handoff = await process.pendingHandoff() {
                self.reconnect(handoff)
            } else {
                self.handleDisconnect()
            }
        }
    }

    /// Reconnects the window to a new Neovim after a `:restart` or `:connect`
    /// handoff, reusing the window and its grid view — the last frame stays on
    /// screen until the new server's first flush, so there is no blank flash.
    /// Cancels the tasks bound to the old process and starts fresh ones against
    /// the new address via `startNeovim`.
    private func reconnect(_ handoff: UIHandoff) {
        // Leave `inputTask` running — it is the window's single command
        // consumer and forwards to the new process once `startNeovim` swaps it
        // in. Only the per-process `modifiedTask` is rebuilt, by `startNeovim`.
        modifiedTask?.cancel()
        // The new session has no tasks of its own yet, so nothing carries over.
        progressTask?.cancel()
        progressHoldTask?.cancel()
        progressGeneration &+= 1
        progressPercent = nil
        updateProgressIndicator()
        // For a `:connect`, the server we are leaving stays alive, so remember
        // it as a fallback: if the new address fails, we return to it. A
        // `:restart`'s old server exits, so it has no fallback.
        if handoff.kind == .connect, let address = currentServerAddress {
            connectFallback = (address: address, owned: ownsServer)
        }
        source = .remote(address: handoff.address)
        // A `:restart` continues our own session, so we still own the new
        // server (closing quits it); a `:connect` attaches to a server someone
        // else runs, so it is borrowed (closing only detaches).
        ownsServer = handoff.kind == .restart
        lastHandoffKind = handoff.kind
        startNeovim()
    }

    /// Returns to the server this window detached from when a `:connect` to a
    /// new address failed, so a bad address neither orphans the old Neovim nor
    /// loses the session. Notes that the new address was unreachable, then
    /// reconnects. The fallback is cleared first, so if it too fails to
    /// connect (e.g. `:connect!` stopped the old server) the normal
    /// error-and-close path runs rather than looping.
    private func recoverToFallback(_ fallback: (address: String, owned: Bool),
                                   reason: String) {
        connectFallback = nil
        if let failedAddress = remoteAddress {
            presentConnectionError(
                "Could not connect to a Neovim server at “\(failedAddress)”.",
                detail: reason + "\n\nStaying attached to the current session.")
        }
        source = .remote(address: fallback.address)
        ownsServer = fallback.owned
        lastHandoffKind = nil
        startNeovim()
    }

    // MARK: - Quit lifecycle (QuitSession)

    /// Whether this window's Neovim has any unsaved buffers. False once the
    /// window has no process (never started, or already exited).
    func hasUnsavedBuffers() async -> Bool {
        // A borrowed Neovim's buffers belong to another session; detaching this
        // view never discards them, so they do not gate a quit.
        guard ownsServer, let process else { return false }
        return await process.hasUnsavedBuffers()
    }

    /// Asks Neovim to quit all buffers. A forced quit discards unsaved changes.
    /// The unsaved check and the user's confirmation are done centrally before
    /// this is called (see `TerminationCoordinator`), so a non-forced quit is
    /// issued only when the window is already clean; the outcome is observed
    /// when the grid stream ends and the window closes.
    func beginQuit(force: Bool) {
        guard !hasExited else { return }
        // A window onto a borrowed Neovim detaches rather than quitting:
        // closing our socket drops this UI and leaves that session's Neovim
        // running.
        // Ending the transport ends the grid stream, which closes the window.
        if !ownsServer {
            let process = self.process
            Task { await process?.disconnect() }
            return
        }
        enqueue(.quit(force: force))
    }

    /// Closes the window in response to Neovim disconnecting. Idempotent; the
    /// close runs the `windowWillClose` teardown. `window?.close()` does not
    /// route through `windowShouldClose`, so this does not re-trigger a quit.
    private func handleDisconnect() {
        guard !hasExited else { return }
        hasExited = true
        window?.close()
    }

    /// Reports a failed connection to a remote Neovim, whose window never
    /// opened. App-modal rather than a sheet, since there is no visible window
    /// to attach to. Only the remote path calls this; a spawn failure is an
    /// internal error (a missing bundle), logged but not surfaced.
    private func presentConnectionError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Showing the window

    /// Drops the `VimEnter` requirement after a short delay, so a session that
    /// never reaches `VimEnter` still shows its window; if a grid has already
    /// arrived it is shown at once, otherwise the next grid shows it.
    ///
    /// Cancellation ends the task rather than falling through it, so a window
    /// closed while it is still starting is never shown after the fact.
    private func startStartupTimeout() {
        startupTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard self?.hasShownWindow == false else { return }
            self?.startupRelaxed = true
            if self?.hasReceivedGrid == true { self?.showInitialWindow() }
        }
    }

    /// Bounds how long the window may stay hidden, whatever Neovim is doing.
    ///
    /// Started when the session starts rather than once it has attached, so it
    /// covers every way startup can stall: a spawn or connect that never
    /// completes, a setup request that never comes back, and a Neovim that
    /// attached but flushed no grid — blocked partway through `init.lua`, say.
    /// A deadline further in would be downstream of those stalls and so could
    /// not bound them; `startStartupTimeout` runs after attach for that reason
    /// and cannot serve here.
    ///
    /// It matters because an app holding no visible window has nothing for the
    /// user to close and nothing for a reopen to bring forward, so it answers a
    /// Dock click by opening a second window (see
    /// `applicationShouldHandleReopen`). An empty window is the more honest end
    /// state, and it paints as soon as a grid does arrive.
    private func startHiddenWindowBackstop() {
        hiddenWindowBackstopTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard self?.hasShownWindow == false else { return }
            self?.showInitialWindow()
        }
    }

    /// Shows the window once the first grid is ready, so its first paint is the
    /// Neovim intro screen rather than a blank clear-color frame. Becoming key
    /// makes the grid first responder and focuses it (see `windowDidBecomeKey`).
    private func showInitialWindow() {
        hasShownWindow = true
        gridView.displayIfNeeded()
        showWindow(nil)
        saveFrame()
    }

    // MARK: - Applying window state

    /// Reapplies the settings that are part of this window's state whenever the
    /// defaults change, so the settings window takes effect as it is clicked.
    ///
    /// Settings read at the point of use — where to open a file, whether to
    /// quit after the last window — need nothing here. This is only for state
    /// the window is already holding.
    ///
    /// One notification covers every key rather than an observation per key:
    /// applying is idempotent and costs a comparison, and the notification
    /// coalesces a run of writes that separate observations would not.
    private func observeSettings() {
        let changes = NotificationCenter.default.notifications(
            named: UserDefaults.didChangeNotification)
        settingsTask = Task { [weak self] in
            for await _ in changes {
                self?.applyTitlebarTransparency()
                self?.applyScrollbarVisibility()
                self?.updateProgressIndicator()
                self?.gridView.applyCursorTrailSettings()
            }
        }
    }

    /// Applies the transparent-title-bar setting. The background is reapplied
    /// with it: a transparent title bar shows the editor's background color
    /// behind it, so the window has to be retinted for the new extent.
    private func applyTitlebarTransparency() {
        let transparent = Settings.titlebarAppearsTransparent
        guard let window, window.titlebarAppearsTransparent != transparent else {
            return
        }
        window.titlebarAppearsTransparent = transparent
        applyBackground(lastBackground, force: true)
    }

    /// Shows or hides the scrollbar, animating it and the window together.
    ///
    /// The grid keeps its size in cells: rather than reflowing the text to make
    /// room, the window grows or shrinks by the bar's width around it. Holding
    /// the grid view's width at its current value for the duration is what does
    /// that — it is a required constraint, so the window has to give — and it
    /// is dropped again once the animation lands, leaving the window resizable
    /// as before. Full screen is the exception: the window cannot change size
    /// there, so the grid is resized instead.
    private func applyScrollbarVisibility() {
        let show = Settings.verticalScrollbar
        guard let window, gridTrailingConstraint != nil,
              show != isScrollbarVisible else { return }
        isScrollbarVisible = show
        let inset = trailingInset

        if window.styleMask.contains(.fullScreen) {
            gridTrailingConstraint.constant = inset
            scroller.isHidden = !show
            scroller.alphaValue = show ? 1 : 0
            window.contentView?.layoutSubtreeIfNeeded()
            resizeGridToFitWindow()
            return
        }

        // A toggle arriving mid-animation supersedes the one in flight: drop
        // its hold, and stamp a generation so its completion — which carries a
        // now-stale `show` — leaves the state this pass is establishing alone.
        scrollbarWidthHold?.isActive = false
        scrollbarAnimation &+= 1
        let animation = scrollbarAnimation

        let holdGridWidth = gridView.widthAnchor.constraint(
            equalToConstant: gridView.frame.width)
        holdGridWidth.priority = .required
        holdGridWidth.isActive = true
        scrollbarWidthHold = holdGridWidth
        isTogglingScrollbar = true

        // Fade in from nothing; a fade out keeps drawing until it is done, so
        // the bar is only hidden in the completion handler.
        if show {
            scroller.alphaValue = 0
            scroller.isHidden = false
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            gridTrailingConstraint.animator().constant = inset
            scroller.animator().alphaValue = show ? 1 : 0
        } completionHandler: { [weak self] in
            // AppKit runs the completion handler on the main thread, but does
            // not type it as main-actor isolated.
            MainActor.assumeIsolated {
                guard let self, animation == self.scrollbarAnimation else {
                    return
                }
                self.scrollbarWidthHold?.isActive = false
                self.scrollbarWidthHold = nil
                self.scroller.isHidden = !show
                self.isTogglingScrollbar = false
                self.saveFrame()
            }
        }
    }

    /// Resizes the Neovim grid to the largest one the window now fits. Used
    /// where the layout changed under a window that cannot itself resize — in
    /// full screen — rather than the usual way round.
    private func resizeGridToFitWindow() {
        guard isReady else { return }
        let size = gridView.desiredGridSize
        guard size.width >= 1, size.height >= 1, size != lastGridSize else { return }
        lastGridSize = size
        enqueue(.resize(width: size.width, height: size.height))
    }

    /// Applies one progress report from Neovim.
    ///
    /// A completed task's percentage is held for a moment before the bar falls
    /// back to whatever is still running, so a task that starts and finishes
    /// between two reports is still seen rather than flashing past. The hold is
    /// generation-checked: any report arriving during it wins, and the stale
    /// fallback is dropped.
    private func applyProgress(_ update: ProgressUpdate) {
        progressGeneration &+= 1
        progressPercent = update.percent
        updateProgressIndicator()
        guard update.isCompletion else { return }

        let generation = progressGeneration
        progressHoldTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.progressGeneration == generation else { return }
            let percent = await self.process?.progressPercent() ?? nil
            guard self.progressGeneration == generation else { return }
            self.progressPercent = percent
            self.updateProgressIndicator()
        }
    }

    /// Pushes the current progress into the bar, hiding it when there is
    /// nothing to show or the setting is off.
    private func updateProgressIndicator() {
        guard Settings.progressBar, let percent = progressPercent else {
            progressIndicator.setVisible(false)
            return
        }
        progressIndicator.setProgress(Double(percent))
        progressIndicator.setVisible(true)
    }

    /// Scrolls the window so `line` (one-based) is its top line, in response to
    /// the scrollbar being dragged or clicked.
    private func scrollToLine(_ line: Int) {
        enqueue(.scrollToLine(line))
    }

    /// Tints the content background with Neovim's default background color so
    /// the grid margins match the editor, and sets the window appearance from
    /// the color's lightness so the title-bar text stays legible. Only acts on
    /// a change, unless `force` is set for a reason unrelated to the color —
    /// the title bar becoming transparent changes what the tint has to cover.
    private func applyBackground(_ color: RGBColor, force: Bool = false) {
        guard color != lastBackground || force else { return }
        lastBackground = color

        let r = CGFloat(color.red), g = CGFloat(color.green), b = CGFloat(color.blue)
        // sRGB, which is how the grid's own drawing interprets these same
        // components. `CGColor(red:green:blue:alpha:)` would build the color in
        // Generic RGB instead, so the margins and the title bar would render a
        // visibly different color from the grid they surround.
        window?.contentView?.layer?.backgroundColor = NSColor(
            srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1).cgColor

        // Perceived lightness (HSP model, http://alienryderflex.com/hsp.html).
        let lightness = (0.299 * r * r + 0.587 * g * g + 0.114 * b * b).squareRoot()
        let appearance: NSAppearance.Name = lightness > 127.5 ? .aqua : .darkAqua
        window?.appearance = NSAppearance(named: appearance)
    }

    /// Rebuilds the grid view's font from a `guifont` option string. Only acts
    /// on a change; the empty default keeps the monospaced system font set at
    /// launch, so no work is done until the user sets `guifont`.
    private func applyGuifont(_ guifont: String) {
        guard guifont != currentGuifont else { return }
        currentGuifont = guifont
        guard let screen = window?.screen ?? NSScreen.main else { return }

        let (descriptor, size) = resolveFont(guifont)
        let font = renderManager.fontManager.family(
            descriptor: descriptor, size: size,
            scaleFactor: screen.backingScaleFactor)
        setFont(font)
    }

    /// Resolves a `guifont` list to a descriptor and size: the first installed
    /// face wins. When the list is non-empty but none of its fonts exist, the
    /// error is reported to Neovim and the default monospaced font is used at
    /// the default size. An empty list quietly uses the default.
    private func resolveFont(_ guifont: String) -> (CTFontDescriptor, CGFloat) {
        let fonts = parseGuifont(guifont, defaultSize: defaultFontSize)
        for entry in fonts {
            if let descriptor = FontManager.makeDescriptor(entry.name) {
                return (descriptor, entry.size)
            }
        }
        if !fonts.isEmpty {
            enqueue(.errorWriteln("Error: Invalid font(s): guifont=\(guifont)"))
        }
        return (FontManager.defaultDescriptor(), defaultFontSize)
    }

    /// Applies a new font: the grid keeps its size in cells while the window's
    /// pixel size, resize increment, and minimum-size constraints are recomputed
    /// from the new cell size.
    private func setFont(_ font: FontFamily) {
        gridView.setFont(font)
        let cell = gridView.cellSize
        window?.resizeIncrements = cell
        gridMinWidthConstraint?.constant = cell.width * CGFloat(minGridColumns)
        gridMinHeightConstraint?.constant = cell.height * CGFloat(minGridRows)
        resizeWindow(in: window?.screen)
        saveFrame()
    }

    // MARK: - Window delegate

    // The window is authoritative for size: when it resizes, resize the Neovim
    // grid to the largest whole-cell grid that fits. `resizeIncrements` keeps the
    // drag advancing in whole cells so the grid stays in step with the drawable.
    func windowDidResize(_ notification: Notification) {
        // A scrollbar animation resizes the window around a grid that is being
        // held at its current size, so there is nothing to forward.
        guard isReady, !isTogglingScrollbar else { return }
        let size = gridView.desiredGridSize
        // Show the grid size in the title bar while a live resize is in progress;
        // the real title is restored when the resize ends.
        if liveResizeDepth > 0 {
            window?.title = "\(size.width) × \(size.height)"
        }
        guard size.width >= 1, size.height >= 1, size != lastGridSize else { return }
        lastGridSize = size
        enqueue(.resize(width: size.width, height: size.height))
        if liveResizeDepth == 0 { saveFrame() }
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        liveResizeDepth += 1
    }

    // A whole-cell resize can still leave a sub-cell strip when the cell size
    // is fractional in points. Once Neovim has caught up to the final size,
    // snap the window content to the grid exactly so no partial cell (drawn as
    // the clear color) remains.
    func windowDidEndLiveResize(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.liveResizeDepth = max(0, self.liveResizeDepth - 1)
            guard self.liveResizeDepth == 0 else { return }
            self.snapWindowToGrid()
            self.window?.title = self.currentTitle
            self.saveFrame()
        }
    }

    /// Snaps the window so the grid view is exactly its grid's size, trimming
    /// any sub-cell strip a fractional cell size left after a resize.
    private func snapWindowToGrid() {
        guard isReady, let window else { return }
        let desired = gridView.desiredFrameSize
        guard desired.width > 0, desired.height > 0,
              gridView.frame.size != desired else { return }
        let (horizontalInsets, topInset) = gridInsets
        window.setContentSize(NSSize(width: desired.width + horizontalInsets,
                                     height: desired.height + topInset))
    }

    func windowDidBecomeKey(_ notification: Notification) {
        enqueue(.focus(true))
        window?.makeFirstResponder(gridView)
        gridView.setActive()
    }

    func windowDidResignKey(_ notification: Notification) {
        enqueue(.focus(false))
        gridView.setInactive()
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    // The red close button means the same thing as Close Window, so it is
    // answered the same way: refuse the immediate close, ask about each
    // modified buffer, then quit Neovim. The window closes when its Neovim
    // exits and the grid stream ends (see `handleDisconnect`), which does not
    // route back through here.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // With no Neovim to ask — it never started — there is nothing to
        // prompt about and nothing to quit, so the close proceeds.
        guard process != nil else { return true }
        closeWindow(sender)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // The window is gone, so it counts as exited for any termination drain
        // holding a reference to it.
        hasExited = true
        cliResponseChannel?.closed()
        cliResponseChannel = nil
        saveFrame()
        coordinator?.deregister(self)
        commandsContinuation.finish()
        renderTask?.cancel()
        inputTask?.cancel()
        modifiedTask?.cancel()
        progressTask?.cancel()
        progressHoldTask?.cancel()
        settingsTask?.cancel()
        startupTimeoutTask?.cancel()
        hiddenWindowBackstopTask?.cancel()
        // Close the transport so this window's Neovim does not outlive it.
        let process = self.process
        Task { await process?.disconnect() }
    }
}
