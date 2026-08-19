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
    /// Whether any of this session's buffers have unsaved changes. Asked
    /// before an app-modal quit or close-all prompt.
    func hasUnsavedBuffers() async -> Bool

    /// Asks Neovim to quit all buffers. A forced quit discards unsaved changes.
    /// The unsaved check and the user's confirmation happen centrally, so the
    /// caller has already decided `force`; this simply issues the quit. Returns
    /// immediately; the outcome is observed through `hasExited`.
    func beginQuit(force: Bool)

    /// Ends a session that did not respond to `beginQuit`. An owned child is
    /// terminated; a borrowed Neovim is only disconnected.
    func forceTerminate() async

    /// True once the session's Neovim has exited and its window has closed.
    var hasExited: Bool { get }
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

    /// The windows that can still accept commands, in creation order. Used to
    /// pick a window to open files in, and to decide whether an open needs a
    /// new window at all.
    var liveSessions: [QuitSession] { sessions.filter { !$0.hasExited } }

    /// Whether any live window has unsaved buffers. The windows are asked in
    /// turn, stopping at the first with unsaved changes. Callers use this to
    /// decide whether an app-modal quit or close-all prompt is needed.
    func anyUnsavedBuffers() async -> Bool {
        // `sessions` is a value type, so the loop iterates a stable snapshot
        // even if a window deregisters while a query is in flight.
        for session in sessions where !session.hasExited {
            if await session.hasUnsavedBuffers() { return true }
        }
        return false
    }

    /// Asks every window to quit and waits, up to `timeout`, for them all to
    /// exit. Returns true only if they did; a false result means at least one
    /// window did not quit (a non-forced quit blocked by unsaved buffers, or a
    /// hang) and the app should stay running. A non-forced quit is expected to
    /// succeed only when the caller has already found every window clean.
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
        // report through `hasExited` even after they leave the registry.
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if draining.allSatisfy({ $0.hasExited }) { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return draining.allSatisfy { $0.hasExited }
    }

    /// Drives the complete application-quit policy. Modified buffers require
    /// confirmation before an orderly forced quit. A timed-out orderly quit
    /// requires a second confirmation before terminating remaining sessions.
    func requestApplicationQuit(
        timeout: Duration = .seconds(3),
        confirmDiscard: () -> Bool,
        confirmForceTermination: () -> Bool
    ) async -> Bool {
        let force: Bool
        if await anyUnsavedBuffers() {
            guard confirmDiscard() else { return false }
            force = true
        } else {
            force = false
        }

        if await requestQuitAll(force: force, timeout: timeout) {
            return true
        }
        guard confirmForceTermination() else { return false }
        await forceTerminateRemaining()
        return true
    }

    /// Terminates sessions still present after an orderly-quit timeout.
    private func forceTerminateRemaining() async {
        let remaining = sessions.filter { !$0.hasExited }
        let tasks = remaining.map { session in
            Task { await session.forceTerminate() }
        }
        for task in tasks {
            await task.value
        }
    }
}
