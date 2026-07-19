//
//  Nvmm
//  WindowController.swift
//
//  Placeholder controller: shows a single empty window so the app has a visible
//  surface. It will grow into the controller that owns the grid view and drives
//  a Neovim process.
//

import Cocoa

final class WindowController: NSWindowController, NSWindowDelegate {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Nvmm"
        window.center()
        self.init(window: window)
        window.delegate = self
    }
}
