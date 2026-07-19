//
//  Nvmm
//  AppDelegate.swift
//

import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var windowController: WindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Startup wiring checks: confirm the two integration points the rest of
        // the app depends on — the utf8proc bridge and the bundled nvim binary.
        logUTF8ProcVersion()
        logBundledNeovim()

        let controller = WindowController()
        controller.showWindow(nil)
        windowController = controller
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
