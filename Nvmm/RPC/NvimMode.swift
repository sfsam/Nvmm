//
//  Nvmm
//  NvimMode.swift
//
//  Neovim's current mode, as reported by `nvim_get_mode`.
//
//  This is distinct from `UIMode`, which is classified from `mode_change` and
//  rides on every grid snapshot for the cursor shape. `UIMode` names only the
//  modes the cursor cares about, so operator-pending, ex mode, and the
//  hit-enter/more/confirm prompts all collapse into `.other` there. Menu
//  actions have to tell those apart — a command issued at a `more` prompt or
//  mid-operator lands somewhere the user did not intend — so they query the
//  full mode instead. See `NeovimProcess.mode()`.
//
//  A failed or timed-out query is itself a mode (`.cancelled`, `.timedOut`),
//  and both count as busy: an unanswered query means Neovim is blocked or gone,
//  and either way it cannot be sent a command.
//

import Foundation

/// A Neovim mode. See `:help mode()`.
nonisolated enum NvimMode: Sendable, Equatable {
    /// The connection failed, or is shutting down.
    case cancelled
    /// Neovim did not answer within the deadline.
    case timedOut
    /// Neovim answered with a mode string this client does not recognize.
    case unknown

    case exModeVim, exMode
    case promptEnter, promptMore, promptConfirm
    case terminal, commandLine, shell
    case normal, normalCtrlIInsert, normalCtrlIReplace, normalCtrlIVirtualReplace
    case operatorPending, operatorPendingForcedChar
    case operatorPendingForcedLine, operatorPendingForcedBlock
    case visualChar, visualLine, visualBlock
    case selectChar, selectLine, selectBlock
    case insert, insertCompletion, insertCompletionCtrlX
    case replace, replaceCompletion, replaceCompletionCtrlX, replaceVirtual

    /// True when Neovim did not report a usable mode, so no command can be
    /// sent with any knowledge of where it would land.
    var isBusy: Bool {
        self == .cancelled || self == .timedOut || self == .unknown
    }

    /// True in the Ex modes (`Q`, `gQ`), where a command would be typed into
    /// the Ex prompt rather than executed.
    var isExMode: Bool {
        self == .exMode || self == .exModeVim
    }

    /// True at a prompt awaiting a keypress: hit-enter, more, or confirm.
    var isPrompt: Bool {
        self == .promptEnter || self == .promptMore || self == .promptConfirm
    }

    var isNormal: Bool {
        switch self {
        case .normal, .normalCtrlIInsert, .normalCtrlIReplace,
             .normalCtrlIVirtualReplace: true
        default: false
        }
    }

    var isCommandLine: Bool { self == .commandLine }

    var isTerminal: Bool { self == .terminal }

    /// True while an operator awaits its motion (`d`, `y`, … pending).
    var isOperatorPending: Bool {
        switch self {
        case .operatorPending, .operatorPendingForcedChar,
             .operatorPendingForcedLine, .operatorPendingForcedBlock: true
        default: false
        }
    }
}

/// Maps a `mode()` short name to a `NvimMode`. Unrecognized names, including
/// any Neovim adds later, map to `.unknown` and so read as busy.
nonisolated func classifyNvimMode(_ shortname: String) -> NvimMode {
    switch shortname {
    case "n": .normal
    case "niI": .normalCtrlIInsert
    case "niR": .normalCtrlIReplace
    case "niV": .normalCtrlIVirtualReplace
    case "no": .operatorPending
    case "nov": .operatorPendingForcedChar
    case "noV": .operatorPendingForcedLine
    case "no\u{16}": .operatorPendingForcedBlock
    case "v": .visualChar
    case "V": .visualLine
    case "\u{16}": .visualBlock
    case "s": .selectChar
    case "S": .selectLine
    case "\u{13}": .selectBlock
    case "i": .insert
    case "ic": .insertCompletion
    case "ix": .insertCompletionCtrlX
    case "R": .replace
    case "Rc": .replaceCompletion
    case "Rx": .replaceCompletionCtrlX
    case "Rv": .replaceVirtual
    case "c": .commandLine
    case "cv": .exModeVim
    case "ce": .exMode
    case "r": .promptEnter
    case "rm": .promptMore
    case "r?": .promptConfirm
    case "!": .shell
    case "t": .terminal
    default: .unknown
    }
}

/// Extracts the mode from an `nvim_get_mode` response. An RPC error, or a
/// reply without a usable `mode` entry, is `.unknown`.
///
/// The reply's `blocking` flag is deliberately not consulted here. A mode
/// read answers where a command would land; whether Neovim is waiting on the
/// user is a separate question, asked only where it changes an outcome (see
/// `parseBlockedAwaitingInput`). Reading it here would refuse ordinary
/// commands during the brief `'timeoutlen'` wait after a mapping prefix,
/// which is a blocking wait that ends on its own.
nonisolated func parseNvimMode(_ response: RPCResponse) -> NvimMode {
    guard !response.isError,
          let shortname = response.result.mapValue(for: .string("mode"))?.stringValue
    else { return .unknown }
    return classifyNvimMode(shortname)
}

/// Maps a bounded RPC result to the mode behavior menu actions consume.
nonisolated func parseNvimMode(_ result: RPCRequestResult) -> NvimMode {
    switch result {
    case .response(let response): parseNvimMode(response)
    case .timedOut: .timedOut
    case .transport: .cancelled
    }
}

/// Whether an `nvim_get_mode` reply says Neovim is blocked waiting for input
/// only the user can supply — the register name after `q`, a `getchar()`
/// prompt. While blocked Neovim answers no other request, so this reply is
/// the one that still arrives.
///
/// No answer at all is not a block: a Neovim too slow to reply, or gone, is
/// not waiting on the user, and reporting it as waiting would tell the user
/// to act on input that does not exist and would hide a dead session behind
/// a report instead of a beep.
///
/// The flag also covers Neovim's own bounded waits, such as the
/// `'timeoutlen'` wait after a mapping prefix, so a single reading can name
/// a block that ends on its own. Callers use it only where refusing costs a
/// dismissible report and a retry.
nonisolated func parseBlockedAwaitingInput(_ result: RPCRequestResult) -> Bool {
    guard case .response(let response) = result else { return false }
    return response.result.mapValue(for: .string("blocking"))?.boolValue == true
}
