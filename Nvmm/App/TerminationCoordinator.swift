//
//  Nvmm
//  TerminationCoordinator.swift
//
//  Owns the set of live editor windows and drives orderly app shutdown.
//
//  Each window (a `QuitSession`) runs its own embedded Neovim. Quitting the app,
//  or the last window closing, must ask every window to end its Neovim and only
//  then let the app terminate. The coordinator holds the registry, asks each
//  session to quit, and reports whether they all exited within a deadline.
//  Windows that exit deregister themselves, so the registry doubles as the
//  "are any windows left?" check AppKit needs.
//

import Foundation

/// A window that owns a Neovim process and can be asked to quit it.
@MainActor protocol QuitSession: AnyObject {
    /// Asks Neovim to quit. A non-forced quit is refused when buffers are
    /// unsaved; a forced quit discards them. Returns immediately; the outcome is
    /// observed through `hasExited` (it quit) and `quitRefused` (it will not,
    /// without force). Each call re-evaluates, clearing a prior refusal.
    func beginQuit(force: Bool)

    /// True once the session's Neovim has exited and its window has closed.
    var hasExited: Bool { get }

    /// True once the most recent non-forced quit was declined (unsaved buffers),
    /// so the drain need not keep waiting on this session.
    var quitRefused: Bool { get }
}

/// Tracks live windows and coordinates app termination across them.
@MainActor final class TerminationCoordinator {
    private var sessions: [QuitSession] = []

    /// Registers a newly created window. The coordinator holds it until it
    /// deregisters, so windows stay alive for the duration of their session.
    func register(_ session: QuitSession) {
        sessions.append(session)
    }

    /// Removes a window as it closes.
    func deregister(_ session: QuitSession) {
        sessions.removeAll { $0 === session }
    }

    /// True when no windows remain; AppKit may terminate immediately.
    var isEmpty: Bool { sessions.isEmpty }

    /// Asks every window to quit and waits, up to `timeout`, for them all to
    /// exit. Returns true only if they did; a false result means at least one
    /// window refused (unsaved buffers, on a non-forced quit) or hung, and the
    /// app should stay running.
    func requestQuitAll(force: Bool,
                        timeout: Duration = .seconds(3)) async -> Bool {
        let draining = sessions
        if draining.isEmpty { return true }

        for session in draining {
            session.beginQuit(force: force)
        }

        // Poll for outcomes rather than await per-session signals: a window
        // exits by its Neovim disconnecting, which it already handles by closing
        // and deregistering. `draining` is a snapshot, so exited windows still
        // report through `hasExited` even after they leave the registry. Stop as
        // soon as every session has settled — exited or refused — so a refusal
        // (unsaved buffers) does not stall the reply for the whole timeout.
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if draining.allSatisfy({ $0.hasExited || $0.quitRefused }) { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return draining.allSatisfy { $0.hasExited }
    }
}
