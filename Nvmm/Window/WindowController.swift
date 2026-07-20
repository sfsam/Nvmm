//
//  Nvmm
//  WindowController.swift
//
//  Owns a grid view and the Neovim process that drives it.
//
//  The window uses a full-size content view; the grid view is a subview inset
//  by a margin on the leading and trailing edges (the trailing inset is where a
//  vertical scroller will sit) and pinned to the content view's safe area at the
//  top and its bottom edge, via Auto Layout. On start the controller sizes the
//  window to a starting grid, spawns an embedded Neovim, and attaches a UI. It
//  then streams flushed grid snapshots into the view and forwards user input —
//  keys, mouse, and window resize — to Neovim through one ordered command
//  channel. The window is authoritative for size: a resize resizes the Neovim
//  grid to fill it, and when a live resize ends the window snaps to the exact
//  grid size so no partial cell is left over. Focus mirrors into
//  `nvim_ui_set_focus` and the view's active state.
//

import Cocoa
import CoreText

final class WindowController: NSWindowController, NSWindowDelegate {
    private let gridView = GridView(frame: .zero)
    private var renderManager: RenderContextManager!
    private var process: NeovimProcess?

    private var renderTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?

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
    // trailing edges; the trailing inset grows by a scroller's width once one is
    // added. The window cannot shrink below `minGridColumns` × `minGridRows`.
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

    // Constraints kept so later work can adjust them without rebuilding the
    // layout: the min-size pair on a font change, the trailing inset when a
    // scroller appears.
    private var gridMinWidthConstraint: NSLayoutConstraint!
    private var gridMinHeightConstraint: NSLayoutConstraint!
    private var gridTrailingConstraint: NSLayoutConstraint!

    convenience init(renderManager: RenderContextManager) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Nvmm"
        window.tabbingMode = .disallowed
        self.init(window: window)
        self.renderManager = renderManager
        window.delegate = self
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

    /// Enqueues a command for the process, preserving order across input sources.
    private func enqueue(_ command: NvimCommand) {
        commandsContinuation.yield(command)
    }

    /// Configures rendering and launches Neovim. Call after the window is on
    /// screen so its screen and backing scale factor are known.
    func start() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }

        let context: RenderContext
        do {
            context = try renderManager.renderContext(for: screen)
        } catch {
            NSLog("Nvmm: no Metal render context: \(error)")
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
        loadSavedFrame(in: window)
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
        gridView.fetchCompositionGeometry = { [weak self] in
            await self?.process?.getCompositionGeometry() ?? nil
        }

        startNeovim()
    }

    /// Builds the content-view → grid-view hierarchy and its constraints.
    private func installGridView(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true
        gridView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(gridView)

        let cell = gridView.cellSize
        let safeArea = contentView.safeAreaLayoutGuide
        gridMinWidthConstraint = gridView.widthAnchor.constraint(
            greaterThanOrEqualToConstant: cell.width * CGFloat(minGridColumns))
        gridMinHeightConstraint = gridView.heightAnchor.constraint(
            greaterThanOrEqualToConstant: cell.height * CGFloat(minGridRows))
        gridTrailingConstraint = contentView.trailingAnchor.constraint(
            equalTo: gridView.trailingAnchor, constant: gridMargin)

        NSLayoutConstraint.activate([
            gridView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            gridView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            gridView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor,
                                              constant: gridMargin),
            gridTrailingConstraint,
            gridMinWidthConstraint,
            gridMinHeightConstraint,
        ])
        contentView.layoutSubtreeIfNeeded()
    }

    /// The insets between the window frame and the grid view: the leading and
    /// trailing margins horizontally, the safe area (title bar) vertically.
    private var gridInsets: (horizontal: CGFloat, top: CGFloat) {
        (gridMargin + (gridTrailingConstraint?.constant ?? gridMargin),
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

    private func startNeovim() {
        guard let nvimPath = NeovimBundle.executableURL?.path else {
            NSLog("Nvmm: bundled nvim not found")
            return
        }

        let launch = NeovimBundle.launchCommand(nvimPath: nvimPath,
                                                arguments: ["--embed"])

        let process = NeovimProcess()
        self.process = process
        let columns = lastGridSize.width
        let rows = lastGridSize.height

        // A single consumer applies queued commands in order on the process actor.
        inputTask = Task {
            for await command in commands {
                await process.perform(command)
            }
        }

        renderTask = Task { [weak self] in
            do {
                try await process.spawn(path: launch.path, argv: launch.argv)
            } catch {
                NSLog("Nvmm: failed to spawn nvim: \(error)")
                return
            }

            var options = UIOptions()
            options.extLinegrid = true
            let result = await process.uiAttach(
                width: columns, height: rows, options: options)

            guard result.status == .success else {
                NSLog("Nvmm: UI attach failed: \(result.message)")
                return
            }

            guard let self else { return }
            self.isReady = true

            for await grid in process.grids {
                self.applyGuifont(grid.guifont)
                self.applyBackground(grid.defaultBackground)
                self.gridView.setGrid(grid)
                if !self.hasShownWindow { self.showInitialWindow() }
                self.currentTitle = grid.title
                if self.liveResizeDepth == 0 { self.window?.title = self.currentTitle }
                self.reconcileWindowSize(to: grid.size)
            }
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

    /// Tints the content background with Neovim's default background color so
    /// the grid margins match the editor, and sets the window appearance from
    /// the color's lightness so the title-bar text stays legible. Only acts on
    /// a change.
    private func applyBackground(_ color: RGBColor) {
        guard color != lastBackground else { return }
        lastBackground = color

        let r = CGFloat(color.red), g = CGFloat(color.green), b = CGFloat(color.blue)
        window?.contentView?.layer?.backgroundColor = CGColor(
            red: r / 255, green: g / 255, blue: b / 255, alpha: 1)

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
        guard isReady else { return }
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

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        commandsContinuation.finish()
        renderTask?.cancel()
        inputTask?.cancel()
    }
}
