//
//  Nvmm
//  WindowController+Help.swift
//
//  Opening native Help-menu search results in this window's Neovim.
//

import Cocoa

extension WindowController {
    /// Opens a bundled help topic and brings this editor window forward.
    func openHelp(topic: String) {
        guard let process else { return NSSound.beep() }
        Task {
            guard await process.openHelpTopic(topic) else {
                return NSSound.beep()
            }
            window?.makeKeyAndOrderFront(nil)
        }
    }
}
