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
        // No windows left: terminate at once. Otherwise ask each window to quit
        // its Neovim and reply once they have (or one refuses, e.g. unsaved
        // buffers on a non-forced quit), keeping the app alive in that case.
        if terminationInFlight { return .terminateLater }
        if terminationCoordinator.isEmpty { return .terminateNow }
        terminationInFlight = true
        Task {
            let exited = await terminationCoordinator.requestQuitAll(force: false)
            terminationInFlight = false
            sender.reply(toApplicationShouldTerminate: exited)
        }
        return .terminateLater
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
