//
//  Nvmm
//  WindowController.swift
//
//  Owns a grid view and the Neovim process that drives it.
//
//  On start, the controller creates a render context for the window's screen,
//  sizes the view to a fixed grid, spawns an embedded Neovim, attaches a UI,
//  and streams flushed grid snapshots into the view. Window resizing, focus
//  handling, and input are added in a later phase; for now the grid size is
//  fixed and the window shows live editor output.
//

import Cocoa

final class WindowController: NSWindowController, NSWindowDelegate {
    private let gridView = GridView(frame: .zero)
    private var renderManager: RenderContextManager!
    private var process: NeovimProcess?
    private var renderTask: Task<Void, Never>?

    private let columns = 80
    private let rows = 24

    convenience init(renderManager: RenderContextManager) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Nvmm"
        window.center()
        self.init(window: window)
        self.renderManager = renderManager
        window.delegate = self
        window.contentView = gridView
    }

    /// Configures rendering and launches Neovim. Call after the window is on
    /// screen so its screen and backing scale factor are known.
    func start() {
        guard let screen = window?.screen ?? NSScreen.main else { return }

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
            descriptor: descriptor, size: 15,
            scaleFactor: screen.backingScaleFactor)
        gridView.setFont(font)

        let cell = gridView.cellSize
        let contentSize = NSSize(width: cell.width * CGFloat(columns),
                                 height: cell.height * CGFloat(rows))
        window?.setContentSize(contentSize)
        gridView.frame = NSRect(origin: .zero, size: contentSize)

        startNeovim()
    }

    private func startNeovim() {
        guard let nvimPath = NeovimBundle.executableURL?.path else {
            NSLog("Nvmm: bundled nvim not found")
            return
        }

        let process = NeovimProcess()
        self.process = process
        let columns = self.columns
        let rows = self.rows

        renderTask = Task { [weak self] in
            do {
                try await process.spawn(path: nvimPath, argv: [nvimPath, "--embed"])
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

            for await grid in process.grids {
                self?.gridView.setGrid(grid)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        renderTask?.cancel()
    }
}
