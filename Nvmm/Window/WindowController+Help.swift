//
//  Nvmm
//  WindowController+Help.swift
//
//  Opening native Help-menu search results in this window's Neovim.
//

import Cocoa

extension WindowController {
    /// Opens a bundled help topic and brings this editor window forward.
    ///
    /// The topic is typed rather than issued as a command, so the Help menu
    /// works even while Neovim is blocked awaiting input. A tag Neovim does
    /// not recognize is reported by Neovim itself, in the window brought
    /// forward here.
    func openHelp(topic: String) {
        guard let process else { return NSSound.beep() }
        Task {
            await process.openHelpTopic(topic)
            window?.makeKeyAndOrderFront(nil)
        }
    }
}
