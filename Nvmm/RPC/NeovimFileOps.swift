//
//  Nvmm
//  NeovimFileOps.swift
//
//  The Neovim side of the File menu: opening, saving, and closing documents.
//
//  These are actor methods rather than `NvimCommand` cases for two reasons.
//  They need responses — a write reports whether the buffer had a name, a
//  buffer query returns the modified set — and most of them are a mode-reset
//  keypress followed by a command, which must reach Neovim in that order.
//  Performing both inside one actor call orders them by construction, without
//  routing through the input stream.
//
//  Every command that names a file goes through helpers installed by
//  `installFileHelpers`, which use `nvim_cmd` with file and bar magic disabled
//  so `%`, `#`, `|`, and spaces in a path are taken literally.
//

import Foundation

// MARK: - Value types

/// A buffer with unsaved changes. `changedtick` identifies the *version* of
/// the buffer, so a buffer the user chose to discard can be told apart from
/// the same buffer edited again afterwards.
nonisolated struct ModifiedBuffer: Sendable, Equatable {
    var bufnr: Int
    var name: String
    var changedtick: Int
}

/// The current buffer, as the close-a-buffer path needs to see it.
nonisolated struct CurrentBufferInfo: Sendable, Equatable {
    var isOnlyBuffer: Bool
    var isModified: Bool
    var bufnr: Int
    var name: String
}

/// The outcome of writing a buffer.
nonisolated enum WriteOutcome: Sendable, Equatable {
    /// The buffer was written.
    case written
    /// The buffer has no name; the caller must ask for one (E32).
    case needsFilename
    /// The write failed, or the connection did.
    case failed
}

// MARK: - Mode-gated commands

extension NeovimProcess {
    /// Raw control bytes fed to Neovim to leave the current mode.
    /// CTRL-\ CTRL-N returns to Normal mode from anywhere; CTRL-C aborts a
    /// command line or a pending operator.
    private static let escapeToNormal = "\u{1c}\u{0e}"
    private static let abort = "\u{03}"

    /// The current mode, bounded by a short deadline. A query that times out or
    /// fails is reported as such and reads as busy, so callers refuse to act
    /// rather than send a command into an unknown state.
    func mode(timeout: Duration = .milliseconds(100)) async -> NvimMode {
        switch await requestBounded("nvim_get_mode", [], timeout: timeout) {
        case .response(let response): return parseNvimMode(response)
        case .timedOut: return .timedOut
        case .transport: return .cancelled
        }
    }

    /// Issues a request bounded by a deadline, cancelling it if the deadline
    /// passes first.
    func requestBounded(_ method: String, _ arguments: [MPValue],
                        timeout: Duration) async -> RPCSyncResult {
        await withTaskGroup(of: RPCSyncResult.self) { group in
            group.addTask {
                do {
                    return .response(try await self.request(method, arguments))
                } catch let error as RPCError {
                    switch error {
                    case .timedOut: return .timedOut
                    case .transport(let transport): return .transport(transport)
                    }
                } catch {
                    return .transport(.connectionClosed)
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .transport(.connectionClosed)
            group.cancelAll()
            return first
        }
    }

    /// Whether a command may be issued now, returning Neovim to Normal mode
    /// first if it is somewhere else. False when Neovim is busy, in an Ex mode,
    /// or at a prompt: the command would be swallowed by whatever is waiting
    /// for input.
    ///
    /// Callers that put up a panel before acting gate on this first, so the
    /// panel does not appear only to be followed by a beep.
    func prepareForCommand() async -> Bool {
        let mode = await self.mode()
        if mode.isBusy || mode.isExMode || mode.isPrompt { return false }
        if !mode.isNormal { feedkeys(Self.escapeToNormal) }
        return true
    }

    /// Runs an Ex command from Normal mode, fire and forget.
    /// Returns false when the mode did not allow it; the caller beeps.
    @discardableResult
    func normalCommand(_ command: String) async -> Bool {
        guard await prepareForCommand() else { return false }
        notify("nvim_command", [.string(command)])
        return true
    }

    /// Runs an Ex command from Normal mode and waits for its response, so the
    /// caller can inspect the error. Returns nil when the mode did not allow
    /// the command, or the connection failed.
    private func normalCommandResponse(_ command: String) async -> RPCResponse? {
        guard await prepareForCommand() else { return nil }
        return try? await request("nvim_command", [.string(command)])
    }

    /// Whether the current mode permits a save, aborting a command line or a
    /// pending operator first. False when Neovim is busy, at a prompt, in an Ex
    /// mode, or in a terminal buffer — nothing there is a document to write.
    func canSave() async -> Bool {
        let mode = await self.mode()
        if mode.isBusy || mode.isPrompt || mode.isExMode || mode.isTerminal {
            return false
        }
        if mode.isCommandLine || mode.isOperatorPending { feedkeys(Self.abort) }
        return true
    }

    /// Feeds raw control bytes literally, in the same no-remap mode the input
    /// path uses, so they are applied in order with the command that follows.
    private func feedkeys(_ keys: String) {
        notify("nvim_feedkeys", [.string(keys), .string("n"), .bool(true)])
    }
}

// MARK: - Opening files

extension NeovimProcess {
    /// Opens paths in tabs, reusing an already-visible window for a path that is
    /// open in one. The caller has checked the mode.
    func openTabs(_ paths: [String]) {
        callHelper("open_tabs", paths)
    }

    /// Opens paths as buffers in the current window.
    func openBuffers(_ paths: [String]) {
        callHelper("open_buffers", paths)
    }

    /// Opens paths per the "open files in buffers instead of tabs" preference.
    func open(_ paths: [String], inBuffers: Bool) {
        if inBuffers { openBuffers(paths) } else { openTabs(paths) }
    }

    /// How many of the given paths already have a buffer. Nil when the query
    /// timed out or failed, which the caller reads as "no idea", not zero.
    func openCount(_ paths: [String],
                   timeout: Duration = .milliseconds(250)) async -> Int? {
        let lua = "return _G.nvmm.open_count(...)"
        let arguments: [MPValue] = [.string(lua), .array([mpStrings(paths)])]
        guard case .response(let response) = await requestBounded(
                  "nvim_exec_lua", arguments, timeout: timeout),
              !response.isError else { return nil }
        guard let count = response.result.integer?.signed else { return nil }
        return Int(count)
    }

    /// Inserts dropped text at the cursor and selects what was inserted.
    func dropText(_ lines: [String]) {
        callHelper("drop_text", lines)
    }

    /// Applies a file drop. Dropping files inserts their paths — the usual
    /// behavior on macOS, and what a command line or a shell in a terminal
    /// buffer wants; `opensFiles` (the user held Option) opens them instead,
    /// as tabs or buffers per the preference.
    ///
    /// The mode is read once here and every branch decided from it, so the
    /// keypress that leaves the current mode and the command that follows it
    /// are issued together, in order.
    func drop(paths: [String], opensFiles: Bool, inBuffers: Bool) async {
        let mode = await self.mode()
        if mode.isBusy || mode.isPrompt || mode.isExMode { return }

        if opensFiles {
            if !mode.isNormal { feedkeys(Self.escapeToNormal) }
            open(paths, inBuffers: inBuffers)
            return
        }

        // A command line and a terminal take text, not an insertion with a
        // selection left behind.
        if mode.isCommandLine || mode.isTerminal {
            notify("nvim_paste",
                   [.string(paths.joined(separator: " ")), .bool(false), .int(-1)])
            return
        }

        if !mode.isNormal { feedkeys(Self.escapeToNormal) }
        dropText(paths)
    }

    /// Calls one of the installed Lua helpers with a list of strings.
    private func callHelper(_ name: String, _ values: [String]) {
        notify("nvim_exec_lua",
               [.string("_G.nvmm.\(name)(...)"), .array([mpStrings(values)])])
    }

    private func mpStrings(_ values: [String]) -> MPValue {
        .array(values.map { .string($0) })
    }
}

// MARK: - Saving

extension NeovimProcess {
    /// Writes the current buffer. Reports `.needsFilename` for an unnamed
    /// buffer so the caller can run a save panel.
    func writeCurrentBuffer() async -> WriteOutcome {
        // A successful write message can displace the mode indicator while
        // Neovim's own UI layer is active, leaving its command window expanded
        // over the statusline. Suppress the message only in that case; errors
        // still reach this response either way.
        let command =
            "if exists('#nvim.ui2#OptionSet') | silent write | else | write | endif"
        return writeOutcome(for: await normalCommandResponse(command))
    }

    /// Switches to a buffer and writes it. Used by the save prompts, which name
    /// the buffer they asked about rather than trusting the current one.
    func writeBuffer(_ bufnr: Int) async -> WriteOutcome {
        writeOutcome(for: await normalCommandResponse("buffer \(bufnr) | write"))
    }

    /// Switches to a buffer without writing it, so a save panel names the
    /// buffer the user was asked about.
    func switchToBuffer(_ bufnr: Int) async -> Bool {
        guard let response = await normalCommandResponse("buffer \(bufnr)") else {
            return false
        }
        return !response.isError
    }

    /// Force-writes the current buffer to a literal path.
    func writeAs(_ path: String) async -> Bool {
        let lua = "_G.nvmm.write_as(...)"
        guard let response = try? await request(
                  "nvim_exec_lua", [.string(lua), .array([.string(path)])])
        else { return false }
        return !response.isError
    }

    /// Deletes a buffer, discarding its changes when `force` is set.
    @discardableResult
    func deleteBuffer(_ bufnr: Int, force: Bool) async -> Bool {
        await normalCommand("bdelete\(force ? "!" : "") \(bufnr)")
    }

    /// Classifies a write response. Neovim reports an unnamed buffer as E32,
    /// which is a request for a filename rather than a failure.
    private func writeOutcome(for response: RPCResponse?) -> WriteOutcome {
        guard let response else { return .failed }
        guard response.isError else { return .written }
        return isErrorCode(response.error, "E32") ? .needsFilename : .failed
    }

    /// Whether an RPC error carries the given Vim error code. Neovim sends
    /// `[type, message]`, with the message reading like
    /// `Vim(write):E32: No file name`.
    private func isErrorCode(_ error: MPValue, _ code: String) -> Bool {
        guard let fields = error.arrayValue, fields.count == 2,
              let message = fields[1].stringValue else { return false }
        return message.contains("\(code):")
    }
}

// MARK: - Buffer queries

extension NeovimProcess {
    /// Every buffer with unsaved changes. Nil when the query timed out or
    /// failed, which callers treat as "cannot know", never as "none".
    func modifiedBuffers(
        timeout: Duration = .milliseconds(250)) async -> [ModifiedBuffer]? {
        let expr = "map(filter(getbufinfo(), 'v:val.changed'), "
            + "'[v:val.bufnr, v:val.name, v:val.changedtick]')"
        guard case .response(let response) = await requestBounded(
                  "nvim_eval", [.string(expr)], timeout: timeout),
              !response.isError,
              let entries = response.result.arrayValue else { return nil }

        var buffers: [ModifiedBuffer] = []
        buffers.reserveCapacity(entries.count)
        for entry in entries {
            guard let fields = entry.arrayValue, fields.count == 3,
                  let bufnr = fields[0].integer?.signed,
                  let name = fields[1].stringValue,
                  let tick = fields[2].integer?.signed else { return nil }
            buffers.append(ModifiedBuffer(bufnr: Int(bufnr), name: name,
                                          changedtick: Int(tick)))
        }
        return buffers
    }

    /// The current buffer's identity and state, or nil if it cannot be read.
    func currentBufferInfo(
        timeout: Duration = .milliseconds(250)) async -> CurrentBufferInfo? {
        let expr = "[len(filter(range(1, bufnr('$')), 'buflisted(v:val)')) == 1, "
            + "&modified, bufnr('%'), bufname('%')]"
        guard case .response(let response) = await requestBounded(
                  "nvim_eval", [.string(expr)], timeout: timeout),
              !response.isError,
              let fields = response.result.arrayValue, fields.count == 4,
              let isOnly = fields[0].integer?.signed,
              let isModified = fields[1].integer?.signed,
              let bufnr = fields[2].integer?.signed,
              let name = fields[3].stringValue else { return nil }
        return CurrentBufferInfo(isOnlyBuffer: isOnly != 0,
                                 isModified: isModified != 0,
                                 bufnr: Int(bufnr), name: name)
    }
}

// MARK: - Helper installation

extension NeovimProcess {
    /// Installs the Lua helpers the File menu calls into. They live in a global
    /// table so each call is a short `nvim_exec_lua` rather than a resend of
    /// the source, and so they are reachable by name after a reconnect
    /// reinstalls them.
    ///
    /// `open_tabs` follows the behavior of a document-based editor rather than
    /// opening a tab per path unconditionally: a pristine untitled window edits
    /// the first path in place, a path already showing in a window is revealed
    /// by switching to it, and anything else opens a new tab.
    func installFileHelpers() {
        let lua = """
            _G.nvmm = _G.nvmm or {}

            -- Runs a file command with the path taken literally: no wildcard
            -- or `%`/`#` expansion, and no `|` command separation.
            local function file_cmd(cmd, path, bang)
              vim.api.nvim_cmd({cmd = cmd, args = {path}, bang = bang,
                                magic = {file = false, bar = false}}, {})
            end

            -- The buffer showing an exact absolute path, or -1.
            local function bufnr_for_path(path)
              local target = vim.fn.fnamemodify(path, ':p')
              for _, info in ipairs(vim.fn.getbufinfo()) do
                if info.name ~= ''
                   and vim.fn.fnamemodify(info.name, ':p') == target then
                  return info.bufnr
                end
              end
              return -1
            end

            function _G.nvmm.open_tabs(paths)
              local edit = vim.fn.bufnr('$') == 1 and vim.fn.line('$') == 1
                and vim.fn.bufname(1) == '' and vim.fn.getline(1) == ''

              for _, path in ipairs(paths) do
                if edit then
                  edit = false
                  file_cmd('edit', path, false)
                else
                  local bufnr = bufnr_for_path(path)
                  local windows = {}

                  if bufnr ~= -1 then
                    windows = vim.fn.getbufinfo(bufnr)[1].windows
                    if #windows == 0 then bufnr = -1 end
                  end

                  if bufnr == -1 then
                    file_cmd('tabedit', path, false)
                  else
                    local pos = vim.fn.win_id2tabwin(windows[1])
                    vim.cmd('tabnext ' .. pos[1])
                    vim.cmd(pos[2] .. ' wincmd w')
                  end
                end
              end
            end

            function _G.nvmm.open_buffers(paths)
              for _, path in ipairs(paths) do
                file_cmd('edit', path, false)
              end
            end

            function _G.nvmm.open_count(paths)
              local open = 0
              for _, path in ipairs(paths) do
                if bufnr_for_path(path) ~= -1 then open = open + 1 end
              end
              return open
            end

            function _G.nvmm.write_as(path)
              local mods = {}
              if vim.fn.exists('#nvim.ui2#OptionSet') == 1 then
                mods = {silent = true}
              end
              vim.api.nvim_cmd({cmd = 'write', args = {path}, bang = true,
                                mods = mods,
                                magic = {file = false, bar = false}}, {})
            end

            -- Inserts dropped text at the cursor and leaves it selected.
            function _G.nvmm.drop_text(lines)
              local start = vim.fn.getpos('.')
              if start[3] ~= 1 then start[3] = start[3] + 1 end
              vim.api.nvim_put(lines, 'c', true, true)
              vim.fn.setpos("'<", start)
              vim.fn.setpos("'>", vim.fn.getpos('.'))
              vim.cmd('normal! gv')
            end
            """
        notify("nvim_exec_lua", [.string(lua), .array([])])
    }
}
