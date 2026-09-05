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
//  Every command that names a file goes through helpers installed at UI attach,
//  which use `nvim_cmd` with file and bar magic disabled
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
    /// Neovim is blocked awaiting input, so nothing was written and nothing
    /// was sent: a write issued now would be answered after its deadline,
    /// and an error it raised — E32 for an unnamed buffer — would arrive in
    /// a reply no longer being read, failing where nobody could see it.
    case awaitingInput
    /// The write failed with the reason that should be shown to the user.
    case failed(String)
}

/// Classifies a write response while preserving Neovim's error message.
nonisolated func classifyWriteResponse(
    _ response: RPCResponse?,
    recognizesUnnamedBuffer: Bool = true
) -> WriteOutcome {
    let fallback = String(localized: "Neovim did not complete the save.")
    guard let response else { return .failed(fallback) }
    guard response.isError else { return .written }
    guard let fields = response.error.arrayValue, fields.count == 2,
          let message = fields[1].stringValue else {
        return .failed(fallback)
    }
    if recognizesUnnamedBuffer && message.contains("E32:") {
        return .needsFilename
    }
    return .failed(message)
}

// MARK: - Mode-gated commands

extension NeovimProcess {
    /// Raw control bytes fed to Neovim to leave the current mode.
    /// CTRL-\ CTRL-N returns to Normal mode from anywhere; CTRL-C aborts a
    /// command line or a pending operator.
    private static let escapeToNormal = "\u{1c}\u{0e}"
    private static let abort = "\u{03}"

    /// Creates an empty document according to Nvmm's buffer/tab preference,
    /// by typing the command rather than issuing it.
    ///
    /// `:hide` sets `'hidden'` only while `:enew` runs, so a modified current
    /// buffer is preserved without changing the user's option afterward.
    func newDocument(inBuffers: Bool) {
        typeExCommand(inBuffers ? "hide enew" : "tabnew")
    }

    /// Types an Ex command as the user would, through `nvim_input`.
    ///
    /// This is the one channel that still reaches a Neovim blocked awaiting
    /// input, and the leading keys clear whatever is pending, so a menu
    /// command works in states where `nvim_command` would queue behind the
    /// block instead. Esc answers a pending wait — the register name after
    /// `q`, say — which would otherwise swallow the next key; CTRL-\ CTRL-N
    /// then returns to Normal mode from wherever the editor was.
    ///
    /// Nothing is reported back: an error is Neovim's to show, exactly as
    /// when the command is typed.
    private func typeExCommand(_ command: String) {
        notify("nvim_input",
               [.string("<Esc><C-\\><C-N>:\(command)<CR>")])
    }

    /// The current mode, bounded by a short deadline. A query that times out or
    /// fails is reported as such and reads as busy, so callers refuse to act
    /// rather than send a command into an unknown state.
    func mode(timeout: Duration = .milliseconds(100)) async -> NvimMode {
        parseNvimMode(await queryBounded("nvim_get_mode", [], timeout: timeout))
    }

    /// Whether Neovim is blocked waiting for input that only the user can
    /// give. See `parseBlockedAwaitingInput` for what the answer means, and
    /// for why no answer reads as "not blocked".
    func isBlockedAwaitingInput() async -> Bool {
        parseBlockedAwaitingInput(
            await queryBounded("nvim_get_mode", [],
                               timeout: .milliseconds(250)))
    }

    /// Issues a request that changes Neovim, bounded by a deadline.
    ///
    /// Use this rather than `queryBounded` whenever a late reply would leave
    /// the editor different from before: the result type then carries the
    /// unknown case, so a caller cannot quietly read "no answer" as "nothing
    /// happened". `refused` is for callers that gate on the mode first and so
    /// know the command was never sent.
    func commandBounded(_ method: String, _ arguments: [MPValue],
                        timeout: Duration) async -> CommandResult {
        switch await queryBounded(method, arguments, timeout: timeout) {
        case .response(let response): .done(response)
        case .timedOut, .transport: .unknown
        }
    }

    /// Issues a request that only asks, bounded by a deadline and cancelled
    /// if the deadline passes first. A late answer to a question changes
    /// nothing, so callers may treat no answer as no information.
    func queryBounded(_ method: String, _ arguments: [MPValue],
                        timeout: Duration) async -> RPCRequestResult {
        await withTaskGroup(of: RPCRequestResult.self) { group in
            group.addTask {
                do {
                    return .response(try await self.request(method, arguments))
                } catch let error as RPCError {
                    switch error {
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
    /// caller can inspect the error. The deadline keeps a wedged Neovim from
    /// parking the caller forever, so the outcome may be unknown: the command
    /// was still sent, and runs whenever Neovim reaches it.
    private func normalCommandResponse(_ command: String) async -> CommandResult {
        guard await prepareForCommand() else { return .refused }
        return await commandBounded("nvim_command", [.string(command)],
                                    timeout: .seconds(2))
    }

    /// Opens an exact help tag, typed as the user would type it.
    ///
    /// `nvim_input` reads `<` as the start of key notation, so a literal one
    /// is sent as `<lt>`; tags like `<C-a>` then reach the command line
    /// unchanged. Everything else passes through as typed, which is what
    /// makes tags holding backslashes work.
    func openHelpTopic(_ topic: String) {
        typeExCommand(
            "help \(topic.replacingOccurrences(of: "<", with: "<lt>"))")
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
        guard case .response(let response) = await queryBounded(
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
    /// Writes the current buffer, leaving the mode as it was. Reports
    /// `.needsFilename` for an unnamed buffer so the caller can run a save
    /// panel.
    ///
    /// The mode is not reset first. A command issued over RPC runs against the
    /// buffer as it stands — Insert mode has already applied every keystroke
    /// to the buffer lines — and returns Neovim to whatever it was doing, so
    /// saving mid-insert writes the text just typed and leaves the user
    /// typing. The caller gates on `canSave()`, which refuses the modes that
    /// would swallow the command, exactly as it does for `writeAs`.
    func writeCurrentBuffer() async -> WriteOutcome {
        // A successful write message can displace the mode indicator while
        // Neovim's own UI layer is active, leaving its command window expanded
        // over the statusline. Suppress the message only in that case; errors
        // still reach this response either way.
        guard await !isBlockedAwaitingInput() else { return .awaitingInput }
        let command =
            "if exists('#nvim.ui2#OptionSet') | silent write | else | write | endif"
        return classifyWrite(
            await commandBounded("nvim_command", [.string(command)],
                                 timeout: .seconds(2)))
    }

    /// Switches to a buffer and writes it. Used by the save prompts, which name
    /// the buffer they asked about rather than trusting the current one.
    func writeBuffer(_ bufnr: Int) async -> WriteOutcome {
        guard await !isBlockedAwaitingInput() else { return .awaitingInput }
        return classifyWrite(
            await normalCommandResponse("buffer \(bufnr) | write"))
    }

    /// Turns a command result into a write outcome. An unanswered write was
    /// still sent and may yet complete, so it is never reported as a failed
    /// save — only as one nobody can confirm.
    private nonisolated func classifyWrite(
        _ result: CommandResult
    ) -> WriteOutcome {
        switch result {
        case .done(let response): classifyWriteResponse(response)
        case .refused: classifyWriteResponse(nil)
        case .unknown: .failed(String(localized:
            "Neovim did not answer in time. The save may still complete."))
        }
    }

    /// Switches to a buffer without writing it, so a save panel names the
    /// buffer the user was asked about.
    func switchToBuffer(_ bufnr: Int) async -> Bool {
        switch await normalCommandResponse("buffer \(bufnr)") {
        case .done(let response): !response.isError
        case .refused: false
        // An unanswered switch may still land, but the caller needs a
        // current buffer it can name now, and this is not it.
        case .unknown: false
        }
    }

    /// Saves the current buffer as a literal path and edits it from then on,
    /// overwriting a file already there. The buffer is renamed rather than
    /// copied out, so the window goes on holding one document and a later
    /// save writes the new file. See `write_as`.
    func writeAs(_ path: String) async -> WriteOutcome {
        // A blocked Neovim would never answer this request, and it is not
        // bounded: refusing keeps the caller from waiting forever.
        guard await !isBlockedAwaitingInput() else { return .awaitingInput }
        let lua = "_G.nvmm.write_as(...)"
        let response = try? await request(
            "nvim_exec_lua", [.string(lua), .array([.string(path)])])
        return classifyWriteResponse(
            response, recognizesUnnamedBuffer: false)
    }

    /// Deletes a buffer, discarding its changes when `force` is set.
    @discardableResult
    func deleteBuffer(_ bufnr: Int, force: Bool) async -> Bool {
        await normalCommand("bdelete\(force ? "!" : "") \(bufnr)")
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
        guard case .response(let response) = await queryBounded(
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
        guard case .response(let response) = await queryBounded(
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
    /// Lua helpers the File menu calls into. They live in a global table so
    /// each call is a short `nvim_exec_lua` rather than a resend of the source,
    /// and so they are reachable by name after a reconnect reinstalls them.
    ///
    /// `open_tabs` follows the behavior of a document-based editor rather than
    /// opening a tab per path unconditionally: a pristine untitled window edits
    /// the first path in place, a path already showing in a window is revealed
    /// by switching to it, and anything else opens a new tab.
    static let fileHelpersLua = """
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

            -- Saves the current buffer as `path` and edits it from then on,
            -- as a Save As does: `:saveas` renames the buffer, clears
            -- 'modified', and detects the filetype from the new name.
            --
            -- It also leaves the name the buffer had behind in a buffer of
            -- its own, holding the alternate file — `[No Name]` when the
            -- document had no name yet. Nothing is editing that buffer, and
            -- it would make one document look like two, so it is wiped.
            -- Only a buffer this write created is touched, only under the
            -- name it took over, and only while it is unloaded, unmodified,
            -- and in no window.
            function _G.nvmm.write_as(path)
              local mods = {}
              if vim.fn.exists('#nvim.ui2#OptionSet') == 1 then
                mods = {silent = true}
              end
              local old = vim.api.nvim_buf_get_name(0)
              local existing = {}
              for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
                existing[bufnr] = true
              end

              vim.api.nvim_cmd({cmd = 'saveas', args = {path}, bang = true,
                                mods = mods,
                                magic = {file = false, bar = false}}, {})

              for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
                local info = not existing[bufnr]
                  and vim.fn.getbufinfo(bufnr)[1]
                if info and info.name == old and info.loaded == 0
                   and info.changed == 0 and #info.windows == 0 then
                  vim.api.nvim_buf_delete(bufnr, {force = false})
                end
              end
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
}
