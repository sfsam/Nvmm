//
//  Nvmm
//  NeovimProcess.swift
//
//  The MessagePack-RPC transport to a single Neovim process.
//
//  `NeovimProcess` is an actor that owns the connection: the pending-request
//  map, the message-id counter, the outgoing encoder, and the streaming
//  decoder. Actor isolation serializes all of that in one isolation domain,
//  without an explicit queue or a lock around the response table.
//
//  `TransportIO` performs the byte-level I/O. It confines two dispatch sources
//  and their buffers to one serial queue and reports up to the actor as an
//  ordered stream of `Inbound` events (decoded on the actor). Reads run for the
//  life of the connection; the write source runs only while bytes are queued.
//
//  Requests are `async`: a checked continuation is stored under the message id
//  and resumed when the response arrives, on timeout, or on disconnect. The one
//  synchronous escape hatch, `requestSync`, blocks the calling thread on a
//  semaphore the actor signals; it exists for AppKit entry points that cannot
//  await, and never runs on the actor's own executor.
//

import Darwin
import Foundation
import os

// MARK: - Inbound events

/// One event delivered from the I/O queue to the actor, in wire order. A
/// terminal `disconnected` follows the last `data` so the actor drains decoded
/// messages before failing outstanding requests.
private nonisolated enum Inbound: Sendable {
    case data([UInt8])
    case disconnected(RPCTransportError)
}

// MARK: - Synchronous waiter

/// Backs one `requestSync` call: the actor stores the outcome and signals the
/// semaphore exactly once, unblocking the calling thread. Safe to share because
/// the semaphore orders the actor's write before the caller's read.
private nonisolated final class SyncWaiter: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private var outcome: RPCSyncResult = .transport(.connectionClosed)
    private var signalled = false

    /// Records the outcome and wakes the caller. Only the first call has effect.
    func finish(_ result: RPCSyncResult) {
        guard !signalled else { return }
        signalled = true
        outcome = result
        semaphore.signal()
    }

    /// The recorded outcome. Read only after `semaphore.wait()` returns.
    func take() -> RPCSyncResult { outcome }
}

// MARK: - Pending request

/// One outstanding request, keyed by message id until it completes.
private nonisolated enum Pending {
    case async(CheckedContinuation<RPCResponse, any Error>)
    case sync(SyncWaiter)

    /// Delivers the outcome to whoever is waiting.
    func complete(_ result: RPCSyncResult) {
        switch self {
        case .async(let continuation):
            switch result {
            case .response(let response): continuation.resume(returning: response)
            case .timedOut: continuation.resume(throwing: RPCError.timedOut)
            case .transport(let error): continuation.resume(throwing: RPCError.transport(error))
            }
        case .sync(let waiter):
            waiter.finish(result)
        }
    }
}

// MARK: - Composition geometry

/// The current window's editable-text geometry, in zero-based grid coordinates.
/// `textCol`/`textWidth` exclude the gutters where a preedit must not displace
/// buffer cells; `rightToLeft` marks a `rightleft` window; `cellwidthOverrides`
/// carries the buffer's `getcellwidths()` entries.
nonisolated struct CompositionGeometry: Sendable, Equatable {
    var windowID: Int32 = 0
    var textRow: Int32 = 0
    var textCol: Int32 = 0
    var textWidth: Int32 = 0
    var textHeight: Int32 = 0
    var rightToLeft = false
    var cellwidthOverrides: [CellwidthOverride] = []
}

/// Parses the `getCompositionGeometry` reply into normalized zero-based grid
/// coordinates, returning nil for any malformed or out-of-range shape.
///
/// Expected result array:
/// `[winid, winrow, wincol, width, height, textoff, rightleft, cellwidths]`,
/// with row/column values 1-based as the Vimscript-facing APIs report them.
nonisolated func parseCompositionGeometry(_ result: MPValue) -> CompositionGeometry? {
    guard let values = result.arrayValue, values.count == 8,
          let windowID = values[0].integer?.signed,
          let winRow = values[1].integer?.signed,
          let winCol = values[2].integer?.signed,
          let width = values[3].integer?.signed,
          let textHeight = values[4].integer?.signed,
          let textOffset = values[5].integer?.signed,
          let rightToLeft = values[6].boolValue,
          let overrides = values[7].arrayValue
    else { return nil }

    let textRow = winRow - 1
    let windowColumn = winCol - 1
    guard windowID > 0, textRow >= 0, windowColumn >= 0, textHeight > 0,
          textOffset >= 0, width > textOffset else { return nil }

    var geometry = CompositionGeometry()
    geometry.windowID = Int32(truncatingIfNeeded: windowID)
    geometry.textRow = Int32(truncatingIfNeeded: textRow)
    geometry.textHeight = Int32(truncatingIfNeeded: textHeight)
    geometry.rightToLeft = rightToLeft
    // LTR windows draw text after the left gutter/textoff; RTL windows start the
    // editable text at wincol with the offset on the opposite edge.
    let textColumn = rightToLeft ? windowColumn : windowColumn + textOffset
    geometry.textCol = Int32(truncatingIfNeeded: textColumn)
    geometry.textWidth = Int32(truncatingIfNeeded: width - textOffset)

    for item in overrides {
        guard let range = item.arrayValue, range.count == 3,
              let first = range[0].integer?.signed,
              let last = range[1].integer?.signed,
              let cellWidth = range[2].integer?.signed,
              first >= 0, last >= first, cellWidth == 1 || cellWidth == 2
        else { return nil }
        geometry.cellwidthOverrides.append(CellwidthOverride(
            first: Int32(truncatingIfNeeded: first),
            last: Int32(truncatingIfNeeded: last),
            width: Int32(truncatingIfNeeded: cellWidth)))
    }
    return geometry
}

// MARK: - Visual selection

/// A Visual-mode selection: its extent on the screen grid and the
/// selected text.
///
/// `start` and `end` are inclusive zero-based grid points, ordered so that
/// `start` comes first on screen regardless of which end the cursor is at.
nonisolated struct VisualSelection: Sendable, Equatable {
    var start = GridPoint(row: 0, column: 0)
    var end = GridPoint(row: 0, column: 0)
    var text = ""

    /// True if the point lies within the selection, treating it as a run of
    /// screen cells from `start` to `end`.
    func contains(_ point: GridPoint) -> Bool {
        if start.row == end.row {
            return point.row == start.row &&
                point.column >= start.column && point.column <= end.column
        }
        if point.row == start.row { return point.column >= start.column }
        if point.row == end.row { return point.column <= end.column }
        return point.row > start.row && point.row < end.row
    }
}

/// True for the mode short names that mean a Visual (not Select) selection.
private nonisolated func isVisualModeName(_ name: String) -> Bool {
    switch name {
    case "v", "V", "\u{16}", "vs", "Vs", "\u{16}s": return true
    default: return false
    }
}

/// Parses the `getVisualSelection` reply, returning nil for a malformed shape,
/// a non-Visual mode, an off-screen end, or an empty selection.
///
/// Expected result array: `[mode, startScreenpos, cursorScreenpos, lines]`,
/// where the screen positions are `screenpos()` dictionaries with 1-based
/// `row`/`col`, and `lines` is the selected text one line per entry.
nonisolated func parseVisualSelection(_ result: MPValue) -> VisualSelection? {
    guard let values = result.arrayValue, values.count >= 4,
          let mode = values[0].stringValue, isVisualModeName(mode),
          let startRow = values[1].mapValue(for: .string("row"))?.integer?.signed,
          let startCol = values[1].mapValue(for: .string("col"))?.integer?.signed,
          let cursorRow = values[2].mapValue(for: .string("row"))?.integer?.signed,
          let cursorCol = values[2].mapValue(for: .string("col"))?.integer?.signed,
          let lines = values[3].arrayValue,
          startRow > 0, cursorRow > 0
    else { return nil }

    // `screenpos()` reports the anchor and the cursor in buffer order, which is
    // not screen order when the selection was made backwards.
    let startIsFirst = startRow < cursorRow ||
        (startRow == cursorRow && startCol <= cursorCol)
    let first = GridPoint(row: Int(startRow) - 1, column: Int(startCol) - 1)
    let second = GridPoint(row: Int(cursorRow) - 1, column: Int(cursorCol) - 1)

    var selection = VisualSelection()
    selection.start = startIsFirst ? first : second
    selection.end = startIsFirst ? second : first
    selection.text = lines.compactMap(\.stringValue).joined(separator: "\n")

    return selection.text.isEmpty ? nil : selection
}

// MARK: - Process actor

/// An RPC connection to one Neovim process.
///
/// Spawn or connect exactly once per instance. Requests may then be issued
/// until the connection closes — by `disconnect()`, by Neovim exiting, or by a
/// transport error — after which every request fails with a transport error.
actor NeovimProcess {
    private enum State { case idle, connected, closed }

    private var state: State = .idle
    private var nextID: UInt64 = 0
    private var pending: [UInt64: Pending] = [:]
    private var timeouts: [UInt64: Task<Void, Never>] = [:]
    private var io: TransportIO?
    private var consumer: Task<Void, Never>?
    private var standardErrorCapture: StandardErrorCapture?
    private var childPID: pid_t?
    private var childWaitTask: Task<Spawn.Termination, Never>?
    private var childTerminationResult: Spawn.Termination?
    private var terminalTransportError: RPCTransportError?

    private let limits: RPCResourceLimits
    private var writer = MessagePackWriter()
    private var unpacker: MessagePackUnpacker
    private var streamedRedrawGrid: Grid?
    private var activeReverseRequests = 0

    private let standardErrorHandler: StandardErrorCapture.Handler
    private let inbound: AsyncStream<Inbound>
    private let inboundContinuation: AsyncStream<Inbound>.Continuation

    // Handlers for inbound RPC requests, keyed by method name. Populated after
    // attach (e.g. the clipboard provider); an unknown method is rejected.
    private var requestHandlers: [String: RequestHandler] = [:]

    /// Notifications Neovim sends the client, in wire order. Once a UI is
    /// attached, the controller consumes `redraw`, `vimenter`, `progress`, and
    /// `modified`, so those no longer appear here. Bounded to the most recent
    /// few, so an unconsumed or slow reader cannot grow it without limit. The
    /// stream finishes when the connection closes.
    nonisolated let notifications: AsyncStream<RPCNotification>
    private let notificationsContinuation: AsyncStream<RPCNotification>.Continuation

    /// UI model, present once `uiAttach` has run. Redraw notifications feed it.
    private var ui: UIController?

    /// Grid snapshots published on each flush. Each is a complete snapshot, so
    /// the stream keeps only the newest: a consumer that falls behind renders
    /// the latest frame and skips the ones it superseded. Finishes on
    /// disconnect.
    nonisolated let grids: AsyncStream<Grid>
    private let gridsContinuation: AsyncStream<Grid>.Continuation

    /// The current buffer's `modified` state, published on each transition so
    /// the window can show a document-edited dot. Finishes on disconnect.
    nonisolated let modifiedStates: AsyncStream<Bool>
    private let modifiedStatesContinuation: AsyncStream<Bool>.Continuation

    /// What the progress bar should show, published as Neovim's `Progress`
    /// events arrive. Finishes on disconnect.
    nonisolated let progressUpdates: AsyncStream<ProgressUpdate>
    private let progressUpdatesContinuation: AsyncStream<ProgressUpdate>.Continuation

    init(
        limits: RPCResourceLimits = .production,
        standardErrorHandler: @escaping StandardErrorCapture.Handler =
            StandardErrorCapture.log
    ) {
        self.limits = limits
        self.standardErrorHandler = standardErrorHandler
        unpacker = MessagePackUnpacker(limits: limits)

        let inboundPair = AsyncStream.makeStream(of: Inbound.self)
        inbound = inboundPair.stream
        inboundContinuation = inboundPair.continuation

        let notificationPair = AsyncStream.makeStream(
            of: RPCNotification.self,
            bufferingPolicy: .bufferingNewest(
                limits.maximumRetainedNotifications))
        notifications = notificationPair.stream
        notificationsContinuation = notificationPair.continuation

        // Each grid is a complete snapshot, so a consumer that falls behind
        // wants the latest frame, not a backlog: keep only the newest.
        let gridsPair = AsyncStream.makeStream(
            of: Grid.self, bufferingPolicy: .bufferingNewest(1))
        grids = gridsPair.stream
        gridsContinuation = gridsPair.continuation

        let modifiedPair = AsyncStream.makeStream(
            of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        modifiedStates = modifiedPair.stream
        modifiedStatesContinuation = modifiedPair.continuation

        let progressPair = AsyncStream.makeStream(
            of: ProgressUpdate.self, bufferingPolicy: .bufferingNewest(1))
        progressUpdates = progressPair.stream
        progressUpdatesContinuation = progressPair.continuation
    }

    // MARK: Connecting

    /// Spawns a Neovim process and connects to it over pipes.
    /// - Throws: `NeovimSpawnError` if a pipe or the process could not be created.
    func spawn(path: String, argv: [String], env: [String] = [],
               workingDirectory: String? = nil) throws {
        guard state == .idle else {
            throw NeovimSpawnError(code: EISCONN, operation: "spawn")
        }

        let read = Spawn.openPipe()
        if read.error != 0 {
            throw NeovimSpawnError(code: read.error, operation: "pipe")
        }
        let write = Spawn.openPipe()
        if write.error != 0 {
            close(read.pipe.readEnd)
            close(read.pipe.writeEnd)
            throw NeovimSpawnError(code: write.error, operation: "pipe")
        }
        let standardError = Spawn.openPipe()
        if standardError.error != 0 {
            close(read.pipe.readEnd)
            close(read.pipe.writeEnd)
            close(write.pipe.readEnd)
            close(write.pipe.writeEnd)
            throw NeovimSpawnError(code: standardError.error, operation: "pipe")
        }

        // The child reads its stdin from the write pipe and writes its stdout
        // and stderr to their read pipes; the parent keeps the opposite ends.
        let streams = Spawn.Streams(input: write.pipe.readEnd,
                                    output: read.pipe.writeEnd,
                                    error: standardError.pipe.writeEnd)
        let result = Spawn.spawn(path: path, argv: argv, env: env,
                                 workingDirectory: workingDirectory,
                                 streams: streams)

        // Close the descriptors the child duplicated, whether or not it spawned.
        close(write.pipe.readEnd)
        close(read.pipe.writeEnd)
        close(standardError.pipe.writeEnd)

        if result.error != 0 {
            close(read.pipe.readEnd)
            close(write.pipe.writeEnd)
            close(standardError.pipe.readEnd)
            throw NeovimSpawnError(code: result.error, operation: "spawn")
        }

        childPID = result.pid
        let waitTask = Task {
            await Spawn.wait(forChild: result.pid)
        }
        childWaitTask = waitTask
        Task { [weak self] in
            let termination = await waitTask.value
            await self?.recordChildTermination(
                termination, pid: result.pid)
        }
        standardErrorCapture = StandardErrorCapture(
            fileDescriptor: standardError.pipe.readEnd,
            handler: standardErrorHandler)
        attach(readFD: read.pipe.readEnd, writeFD: write.pipe.writeEnd)
    }

    /// Connects to an existing Neovim process over a Unix domain socket.
    /// - Throws: `NeovimSpawnError` if the socket could not be connected.
    func connect(_ address: String) throws {
        guard state == .idle else {
            throw NeovimSpawnError(code: EISCONN, operation: "connect")
        }
        let socket = Spawn.connectUnixSocket(address)
        if socket.error != 0 {
            throw NeovimSpawnError(code: socket.error, operation: "connect")
        }
        attach(readFD: socket.fd, writeFD: socket.fd)
    }

    /// Starts the I/O loop over already-open descriptors.
    ///
    /// `readFD` and `writeFD` may be the same descriptor (a socket) or distinct
    /// (a pipe pair). The transport takes ownership and closes them on shutdown.
    func attach(readFD: Int32, writeFD: Int32) {
        guard state == .idle else { return }

        let continuation = inboundContinuation
        io = TransportIO(readFD: readFD, writeFD: writeFD,
                         limits: limits) { event in
            continuation.yield(event)
        }
        state = .connected

        consumer = Task { [self] in
            for await event in inbound {
                handle(event)
            }
        }
    }

    /// Closes the transport. Neovim, if it was spawned, exits on stdin EOF; an
    /// external Neovim reached via `connect` keeps running.
    func disconnect() {
        guard state == .connected else { return }
        io?.shutdown(.connectionClosed)
    }

    /// The reason the transport ended, once its streams have finished.
    func transportTermination() -> RPCTransportError? {
        terminalTransportError
    }

    /// Waits for and returns the spawned child's termination status.
    ///
    /// A socket connection has no child owned by Nvmm and returns `nil`.
    func childTermination() async -> Spawn.Termination? {
        if let childTerminationResult {
            return childTerminationResult
        }
        guard let childWaitTask else { return nil }
        return await childWaitTask.value
    }

    /// Terminates the locally spawned child, escalating from `SIGTERM` to
    /// `SIGKILL` if it does not exit during `gracePeriod`.
    ///
    /// A socket connection has no child owned by Nvmm and returns `nil`.
    /// Calling this after the child exited returns its recorded status.
    func terminateChild(
        gracePeriod: Duration = .seconds(1)
    ) async -> Spawn.Termination? {
        if let childTerminationResult {
            return childTerminationResult
        }
        guard let pid = childPID, let waitTask = childWaitTask else {
            return nil
        }

        _ = Darwin.kill(pid, SIGTERM)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: gracePeriod)
        while clock.now < deadline {
            if let childTerminationResult {
                return childTerminationResult
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        // The actor clears `childPID` when the exact-PID waiter completes.
        // Escalate only while this is still the child originally requested.
        if childPID == pid {
            _ = Darwin.kill(pid, SIGKILL)
        }
        return await waitTask.value
    }

    private func recordChildTermination(
        _ termination: Spawn.Termination,
        pid: pid_t
    ) {
        guard childPID == pid else { return }
        childTerminationResult = termination
        childWaitTask = nil
        childPID = nil
    }

    // MARK: Requests

    /// Issues a request and awaits its response.
    ///
    /// Returns the response even when Neovim reports an RPC-level error (carried
    /// in `RPCResponse.error`). Throws `RPCError.transport` if the connection
    /// closes first, and `CancellationError` if the awaiting task is cancelled.
    func request(_ method: String, _ arguments: [MPValue] = []) async throws -> RPCResponse {
        guard state == .connected else {
            throw RPCError.transport(.connectionClosed)
        }
        let id = nextID
        nextID &+= 1

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Cancellation may have already fired (its handler ran before this
                // body), so resolve here rather than registering and hanging.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard state == .connected else {
                    continuation.resume(throwing: RPCError.transport(.connectionClosed))
                    return
                }
                pending[id] = .async(continuation)
                send { $0.encodeRequest(id: id, method: method, arguments: arguments) }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    /// Issues a request and blocks the calling thread until it completes or the
    /// timeout elapses.
    ///
    /// This is the sole synchronous path, for AppKit entry points that cannot
    /// await. It must never be called on the actor's executor: it blocks a thread
    /// while the actor runs elsewhere to deliver the result.
    nonisolated func requestSync(_ method: String, _ arguments: [MPValue] = [],
                                 timeout: Duration) -> RPCSyncResult {
        let waiter = SyncWaiter()
        Task { await self.startSync(method: method, arguments: arguments,
                                    timeout: timeout, waiter: waiter) }
        waiter.semaphore.wait()
        return waiter.take()
    }

    /// Sends a fire-and-forget notification. No response is expected.
    func notify(_ method: String, _ arguments: [MPValue] = []) {
        guard state == .connected else { return }
        send { $0.encodeNotification(method: method, arguments: arguments) }
    }

    /// Applies one user command. Callers funnel commands through a single
    /// ordered channel and await `perform` so a result-bearing operation
    /// finishes before the next command reaches Neovim.
    func perform(_ command: NvimCommand) async {
        switch command {
        case .input(let text):
            notify("nvim_input", [.string(text)])
        case .mouse(let button, let action, let modifiers, let row, let col):
            notify("nvim_input_mouse",
                   [.string(button), .string(action), .string(modifiers),
                    0, .int(MPInteger(row)), .int(MPInteger(col))])
        case .resize(let width, let height):
            notify("nvim_ui_try_resize",
                   [.int(MPInteger(width)), .int(MPInteger(height))])
        case .focus(let focused):
            notify("nvim_ui_set_focus", [.bool(focused)])
        case .paste(let data):
            await paste(data)
        case .feedkeys(let keys):
            // Mode "n" (no remapping) with K_SPECIAL escaping, so the raw
            // control bytes in `keys` are fed literally.
            notify("nvim_feedkeys", [.string(keys), .string("n"), .bool(true)])
        case .undoRedo(let action, let reply):
            let outcome = await performUndoRedo(action)
            await reply(outcome)
        case .errorWriteln(let text):
            notify("nvim_echo",
                   [.array([.array([.string(text)])]), true,
                    .map([(.string("err"), true)])])
        case .scrollToLine(let line):
            // `zt` rather than `winrestview`: it redraws through Neovim's own
            // scrolling, so wrapped lines, folds, and `smoothscroll` are
            // accounted for, and it takes the cursor along, which is what
            // dragging a scrollbar is expected to do.
            notify("nvim_command", [.string("normal! \(line)Gzt")])
        case .quit(let force):
            // `quitall`/`quitall!` end every window. The app checks for unsaved
            // buffers and confirms with the user before a non-forced quit, so
            // this is only issued when it will succeed; `silent!` still guards
            // against another error (e.g. a running terminal) spilling a
            // press-a-key prompt into the editor.
            notify("nvim_command",
                   [.string(force ? "silent! quitall!" : "silent! quitall")])
        }
    }

    /// Streams a paste through result-bearing requests. Keeping each request
    /// bounded and awaiting its response prevents a large clipboard value from
    /// overflowing the transport's finite outbound queue.
    private func paste(_ data: String) async {
        let chunks = pasteChunks(data, maximumBytes: nvimPasteChunkBytes)
        for (index, chunk) in chunks.enumerated() {
            let phase: Int
            if chunks.count == 1 {
                phase = -1
            } else if index == 0 {
                phase = 1
            } else if index == chunks.count - 1 {
                phase = 3
            } else {
                phase = 2
            }

            guard let response = try? await request(
                "nvim_paste",
                [.string(chunk), false, .int(MPInteger(phase))]),
                  !response.isError, response.result.boolValue == true
            else { return }
        }
    }

    /// Runs one mode-aware Undo or Redo and observes whether Neovim moved in
    /// its undo tree.
    func performUndoRedo(_ action: UndoRedoAction) async -> UndoRedoOutcome {
        let mode = await mode()
        guard let keys = action.keys(for: mode),
              let before = await undoSequence()
        else { return .unavailable }

        let arguments: [MPValue] = [
            .string(keys), .string("n"), .bool(true),
        ]
        guard let response = try? await request("nvim_feedkeys", arguments),
              !response.isError,
              let after = await undoSequence()
        else { return .unavailable }

        return undoRedoOutcome(before: before, after: after)
    }

    /// The current position in the current buffer's undo tree.
    private func undoSequence() async -> MPInteger? {
        guard let response = try? await request(
                  "nvim_eval", [.string("undotree().seq_cur")]),
              !response.isError
        else { return nil }
        return response.result.integer
    }

    /// Whether any loaded buffer has unsaved changes. Assumes unsaved on an
    /// error, timeout, or unexpected result, so a quit is never issued that
    /// could silently discard work.
    func hasUnsavedBuffers() async -> Bool {
        let expr = "len(filter(map(getbufinfo(), 'v:val.changed'), 'v:val'))"
        // Bounded: a Neovim wedged in a plugin or prompt would otherwise never
        // answer, and this runs before the quit drain's own deadline, leaving
        // the app terminating forever. A timeout counts as unsaved so the quit
        // path prompts rather than discards.
        guard case .response(let response) = await requestBounded(
                  "nvim_eval", [.string(expr)], timeout: .seconds(1)),
              !response.isError,
              let count = response.result.integer?.signed else { return true }
        return count != 0
    }

    /// Queries the current window's editable-text geometry for composition
    /// layout. Returns nil when Neovim has no usable window info, the request
    /// errors, or the connection is down. This is `async`; the caller
    /// generation-checks the reply on the main actor and caches it, so the
    /// synchronous text-input geometry queries never block on the actor.
    func getCompositionGeometry() async -> CompositionGeometry? {
        let lua = """
            local w = vim.api.nvim_get_current_win()
            local i = vim.fn.getwininfo(w)[1]
            if not i then return nil end
            return {w, i.winrow, i.wincol, i.width, i.height, i.textoff,
                    vim.wo[w].rightleft, vim.fn.getcellwidths()}
            """
        guard let response = try? await request("nvim_exec_lua",
                                                [.string(lua), .array([])]),
              !response.isError else { return nil }
        return parseCompositionGeometry(response.result)
    }

    /// Queries the current Visual-mode selection — its screen extent and its
    /// text — so a Look Up gesture inside a selection looks up the whole
    /// selection rather than the single word under the pointer. Bounded by a
    /// short deadline: the gesture is transient, and a late answer would open a
    /// popover the user has stopped asking for.
    func getVisualSelection(
        timeout: Duration = .milliseconds(100)) async -> VisualSelection? {
        let expr = """
            [mode(), screenpos(0, line('v'), col('v')), \
            screenpos(0, line('.'), col('.')), \
            getregion(getpos('v'), getpos('.'), {'type': mode()})]
            """
        guard case .response(let response) = await requestBounded(
                "nvim_eval", [.string(expr)], timeout: timeout),
              !response.isError else { return nil }
        return parseVisualSelection(response.result)
    }

    private func startSync(method: String, arguments: [MPValue],
                           timeout: Duration, waiter: SyncWaiter) {
        guard state == .connected else {
            waiter.finish(.transport(.connectionClosed))
            return
        }
        let id = nextID
        nextID &+= 1
        pending[id] = .sync(waiter)
        send { $0.encodeRequest(id: id, method: method, arguments: arguments) }
        armTimeout(id: id, timeout: timeout)
    }

    private func armTimeout(id: UInt64, timeout: Duration) {
        timeouts[id] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if Task.isCancelled { return }
            await self?.fireTimeout(id: id)
        }
    }

    private func fireTimeout(id: UInt64) {
        timeouts.removeValue(forKey: id)
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.complete(.timedOut)
    }

    private func cancel(id: UInt64) {
        timeouts.removeValue(forKey: id)?.cancel()
        guard let entry = pending.removeValue(forKey: id) else { return }
        switch entry {
        case .async(let continuation): continuation.resume(throwing: CancellationError())
        case .sync(let waiter): waiter.finish(.transport(.connectionClosed))
        }
    }

    /// Encodes one framed message into the shared writer and hands the bytes to
    /// the transport. The writer is cleared and reused; the byte copy handed off
    /// is independent of the writer's storage.
    private func send(_ encode: (inout MessagePackWriter) -> Void) {
        writer.clear()
        encode(&writer)
        io?.send(writer.bytes)
    }

    // MARK: Inbound dispatch

    private func handle(_ event: Inbound) {
        switch event {
        case .data(let bytes):
            unpacker.feed(bytes)
            let redrawItem: ((MessagePackRedrawItem) -> Void)? =
                ui == nil ? nil : { [self] item in
                guard let ui else { return }
                switch item {
                case .event(let event):
                    if let grid = ui.applyRedrawEvent(event) {
                        streamedRedrawGrid = grid
                    }
                case .gridLineStart(let prefix):
                    ui.beginStreamingGridLine(prefix)
                case .gridLineCell(let cell):
                    ui.applyStreamingGridLineCell(cell)
                case .gridLineEnd(let wrap):
                    ui.endStreamingGridLine(wrap)
                }
            }
            while let value = unpacker.unpack(redrawItem: redrawItem) {
                dispatch(value)
            }
            // A decoder limit was hit. Shut down through the transport rather
            // than finishing the disconnect here, so the ordered disconnect
            // event runs the normal teardown after the dispatch sources are
            // cancelled. The unpacker stays failed, ignoring any further data.
            if unpacker.failed {
                io?.shutdown(.protocolViolation)
            }
            io?.didConsumeInbound(bytes.count)
        case .disconnected(let error):
            finishDisconnect(error)
        }
    }

    private func dispatch(_ value: MPValue) {
        guard case .array(let message) = value else { return }
        if isResponse(message) {
            handleResponse(message)
        } else if isNotification(message) {
            handleNotification(message)
        } else if isRequest(message) {
            handleRequest(message)
        }
        // Malformed envelopes are dropped: the decoder already found the next
        // message boundary, so skipping one is safe.
    }

    private func handleResponse(_ message: [MPValue]) {
        guard let id = message[1].integer?.unsigned else { return }
        timeouts.removeValue(forKey: id)?.cancel()
        guard let entry = pending.removeValue(forKey: id) else { return } // stale
        entry.complete(.response(RPCResponse(error: message[2], result: message[3])))
    }

    private func handleNotification(_ message: [MPValue]) {
        guard let method = message[1].stringValue,
              let arguments = message[2].arrayValue else { return }

        // An attached UI absorbs its own notification channels; the rest flow
        // to the public stream. Without a UI, every notif flows to the stream.
        if let ui {
            switch method {
            case "redraw":
                if let grid = streamedRedrawGrid {
                    streamedRedrawGrid = nil
                    gridsContinuation.yield(grid)
                } else {
                    for grid in ui.redraw(arguments) {
                        gridsContinuation.yield(grid)
                    }
                }
                return
            case "vimenter":
                ui.vimenter()
                return
            case "progress":
                if arguments.count == 1, case .map(let event) = arguments[0] {
                    switch ui.progress(event) {
                    case .ignored:
                        break
                    case .changed:
                        publishProgressUpdate(
                            ProgressUpdate(percent: ui.progressPercent,
                                           isCompletion: false),
                            to: progressUpdatesContinuation)
                    case .completed(let percent):
                        publishProgressUpdate(
                            ProgressUpdate(percent: percent, isCompletion: true),
                            to: progressUpdatesContinuation)
                    }
                }
                return
            case "modified":
                if arguments.count == 1, let value = arguments[0].boolValue,
                   ui.setModified(value) {
                    modifiedStatesContinuation.yield(value)
                }
                return
            default:
                break
            }
        }
        notificationsContinuation.yield(RPCNotification(method: method, arguments: arguments))
    }

    private func handleRequest(_ message: [MPValue]) {
        // `isRequest` guarantees the envelope shape, so these hold.
        guard let id = message[1].integer?.unsigned,
              let method = message[2].stringValue,
              let arguments = message[3].arrayValue else { return }

        guard let handler = requestHandlers[method] else {
            respond(id: id, outcome: .error("Unknown method: \(method)"))
            return
        }

        guard activeReverseRequests < limits.maximumReverseRequests else {
            io?.shutdown(.protocolViolation)
            return
        }
        activeReverseRequests += 1

        Task { [weak self] in
            let outcome = await handler(arguments)
            await self?.finishRequest(id: id, outcome: outcome)
        }
    }

    private func finishRequest(id: UInt64, outcome: RequestOutcome) {
        activeReverseRequests -= 1
        respond(id: id, outcome: outcome)
    }

    /// Registers a handler for an inbound RPC request method, replacing any
    /// prior handler for the same name. Call after attach.
    func registerRequestHandler(_ method: String,
                                _ handler: @escaping RequestHandler) {
        requestHandlers[method] = handler
    }

    /// Sends a request handler's outcome back to Neovim. Dropped if the
    /// connection closed while the handler ran.
    private func respond(id: UInt64, outcome: RequestOutcome) {
        guard state == .connected else { return }
        switch outcome {
        case .result(let value):
            send { $0.encodeResponse(id: id, error: .null, result: value) }
        case .error(let message):
            // A two-element `[type, message]` error, as Neovim expects; it is
            // raised at the caller's `rpcrequest`.
            let error: MPValue = .array([.int(1), .string(message)])
            send { $0.encodeResponse(id: id, error: error, result: .null) }
        }
    }

    private func finishDisconnect(_ error: RPCTransportError) {
        guard state != .closed else { return }
        terminalTransportError = error
        switch error {
        case .connectionClosed:
            Log.rpc.info(
                "RPC transport closed: \(error.description, privacy: .public)")
        case .readFailed, .writeFailed, .protocolViolation:
            Log.rpc.error(
                "RPC transport closed: \(error.description, privacy: .public)")
        }
        state = .closed

        for (_, task) in timeouts { task.cancel() }
        timeouts.removeAll()

        let outstanding = pending
        pending.removeAll()
        for (_, entry) in outstanding {
            entry.complete(.transport(error))
        }

        notificationsContinuation.finish()
        gridsContinuation.finish()
        modifiedStatesContinuation.finish()
        progressUpdatesContinuation.finish()
        inboundContinuation.finish()
        io = nil
    }

    // MARK: Message classification

    // MessagePack-RPC envelopes: request [0, id, method, args],
    // response [1, id, error, result], notification [2, method, args].

    private func isRequest(_ message: [MPValue]) -> Bool {
        message.count == 4 && message[0].integer?.unsigned == 0
            && message[1].integer != nil && message[2].stringValue != nil
            && message[3].arrayValue != nil
    }

    private func isResponse(_ message: [MPValue]) -> Bool {
        message.count == 4 && message[0].integer?.unsigned == 1
            && message[1].integer != nil
    }

    private func isNotification(_ message: [MPValue]) -> Bool {
        message.count == 3 && message[0].integer?.unsigned == 2
            && message[1].stringValue != nil && message[2].arrayValue != nil
    }
}

/// Publishes progress without allowing a state snapshot to displace an unseen
/// completion. The process actor remains authoritative for the latest state,
/// so dropping a snapshot while a completion is pending loses no state.
nonisolated func publishProgressUpdate(
    _ update: ProgressUpdate,
    to continuation: AsyncStream<ProgressUpdate>.Continuation
) {
    switch continuation.yield(update) {
    case .dropped(let displaced)
        where displaced.isCompletion && !update.isCompletion:
        _ = continuation.yield(displaced)
    default:
        break
    }
}

// MARK: - UI attachment

extension NeovimProcess {
    /// A pending restart/connect handoff Neovim requested, if any.
    func pendingHandoff() -> UIHandoff? { ui?.handoff }

    /// The percentage the progress bar should show for the tasks running now,
    /// or nil if there is nothing to show. Asked for after a completed task's
    /// value has been held, to fall back to whatever is still running.
    func progressPercent() -> Int? { ui?.progressPercent }

    /// The outcome of one negotiation request, awaited under a shared deadline.
    private enum AttachOutcome {
        case response(RPCResponse)
        case timedOut
        case transport(RPCTransportError)
    }

    /// Negotiates the API and attaches a UI of the given size.
    ///
    /// Runs the startup transaction under one shared deadline:
    /// `nvim_get_api_info` → validate → `nvim_set_client_info` →
    /// `nvim_ui_attach`, attaching only the options Neovim supports. On
    /// success, redraw notifications feed the UI model and flushed grids are
    /// published on `grids`.
    func uiAttach(width: Int, height: Int, options: UIOptions,
                  timeout: Duration = .seconds(5)) async -> UIAttachResult {
        let controller = ui ?? UIController(limits: limits)
        ui = controller

        let deadline = ContinuousClock.now.advanced(by: timeout)

        let apiOutcome = await requestWaiting("nvim_get_api_info", [], until: deadline)
        guard case .response(let api) = apiOutcome, !api.isError else {
            return attachFailure(apiOutcome, "API negotiation")
        }

        let (validation, capabilities) = validateAPIMetadata(api.result, requested: options)
        guard validation.status == .success else { return validation }

        let clientOutcome = await requestWaiting(
            "nvim_set_client_info", clientInfoArguments(), until: deadline)
        guard case .response(let client) = clientOutcome, !client.isError else {
            return attachFailure(clientOutcome, "Client registration")
        }

        // Register the VimEnter signal before attaching, so it is in place
        // before Neovim finishes startup. It lets the window hold its first
        // paint until startup config (notably `guifont`) has been applied.
        // Channel 0 broadcasts, reaching this UI without hard-coding a channel.
        notify("nvim_command",
               [.string("autocmd VimEnter * silent! call rpcnotify(0, 'vimenter')")])
        // A UI connecting to an already-running Neovim has missed VimEnter (it
        // fired during that Neovim's startup), so fire the signal now if
        // startup is already complete. On a fresh `--embed` spawn this is a
        // no-op:
        // Neovim pauses before loading startup files until `nvim_ui_attach`, so
        // `v:vim_did_enter` is still 0 here and only the autocmd above fires.
        notify("nvim_command",
               [.string("if v:vim_did_enter | call rpcnotify(0, 'vimenter') | endif")])

        let attachOptions = supportedOptions(requested: options,
                                             supported: capabilities.uiOptions)
        let attachArgs: [MPValue] = [.int(MPInteger(width)),
                                     .int(MPInteger(height)), .map(attachOptions)]
        let attachOutcome = await requestWaiting("nvim_ui_attach", attachArgs, until: deadline)
        guard case .response(let attached) = attachOutcome, !attached.isError else {
            return attachFailure(attachOutcome, "UI attachment")
        }

        installModifiedAutocmd()
        installProgressAutocmd()
        installFileHelpers()

        var result = validation
        result.status = .success
        return result
    }

    /// Installs the autocmd group that reports the current buffer's `modified`
    /// state back over RPC (consumed on `modifiedStates`), for the window's
    /// document-edited dot. `BufModifiedSet` fires on the flag's transitions;
    /// `BufEnter`/`WinEnter` cover the buffer changing without the flag itself
    /// changing; `OptionSet pattern=modified` covers `:set (no)modified`, which
    /// `BufModifiedSet` does not fire for. The trailing `notify()` seeds the
    /// initial state. Fire-and-forget, matching the post-attach convention.
    private func installModifiedAutocmd() {
        let lua = """
            local group = vim.api.nvim_create_augroup('NvmmModified', {clear=true})
            local function notify()
              vim.rpcnotify(0, 'modified', vim.bo.modified)
            end
            vim.api.nvim_create_autocmd({'BufModifiedSet', 'BufEnter', 'WinEnter'},
              {group=group, callback=notify})
            vim.api.nvim_create_autocmd('OptionSet',
              {group=group, pattern='modified', callback=notify})
            notify()
            """
        notify("nvim_exec_lua", [.string(lua), .array([])])
    }

    /// Installs the autocmd that forwards Neovim's `Progress` events over RPC
    /// (consumed on `progressUpdates`), for the window's progress bar. The
    /// event carries the task's id, status, and percentage in `ev.data`, which
    /// is passed through unchanged. Guarded on the event existing, so an older
    /// Neovim without it simply reports no progress. Fire-and-forget, matching
    /// the post-attach convention.
    private func installProgressAutocmd() {
        let lua = """
            if vim.fn.exists('##Progress') ~= 1 then return end
            local group = vim.api.nvim_create_augroup('NvmmProgress', {clear=true})
            vim.api.nvim_create_autocmd('Progress', {group=group,
              callback=function(ev) vim.rpcnotify(0, 'progress', ev.data) end})
            """
        notify("nvim_exec_lua", [.string(lua), .array([])])
    }

    /// Points Neovim's `g:clipboard` provider at this UI, so the `+`/`*`
    /// registers route through the `clipboard_get`/`clipboard_set` request
    /// handlers. Resolves this UI's channel by its client name (set in
    /// `clientInfoArguments`) rather than hard-coding it, so it survives a
    /// future reconnect. Register the handlers before calling this.
    func installClipboardProvider() async {
        let lua = """
            local function channel()
              for _, ui in ipairs(vim.api.nvim_list_uis()) do
                local client = vim.api.nvim_get_chan_info(ui.chan).client
                if type(client) == 'table' and client.name == 'Nvmm' then
                  return ui.chan
                end
              end
              error('Nvmm clipboard provider: no attached Nvmm UI')
            end
            local function set(lines, regtype)
              return vim.rpcrequest(channel(), 'clipboard_set', lines, regtype)
            end
            local function get()
              return vim.rpcrequest(channel(), 'clipboard_get')
            end
            vim.g.clipboard = {
              name = 'Nvmm',
              copy = { ['+'] = set, ['*'] = set },
              paste = { ['+'] = get, ['*'] = get },
            }
            -- Neovim caches the clipboard provider on first access, which
            -- happens eagerly at startup when 'clipboard' is unnamed/
            -- unnamedplus -- before this UI sets g:clipboard. Re-run the
            -- provider detection so the register operations pick up this
            -- provider instead of the built-in pbcopy/pbpaste.
            pcall(vim.fn['provider#clipboard#Executable'])
            """
        // Awaited (not fire-and-forget) so `g:clipboard` is in place before the
        // window becomes interactive, and so a setup failure surfaces here
        // rather than silently leaving Neovim on its default provider.
        do {
            let response = try await request("nvim_exec_lua", [.string(lua), .array([])])
            if response.isError {
                let detail = String(describing: response.error)
                Log.rpc.error("Clipboard provider setup failed: \(detail)")
            }
        } catch {
            Log.rpc.error("Clipboard provider setup failed: \(error)")
        }
    }

    /// Issues a request and awaits its response or the shared deadline,
    /// whichever comes first. A timeout cancels the in-flight request.
    private func requestWaiting(_ method: String, _ arguments: [MPValue],
                                until deadline: ContinuousClock.Instant) async -> AttachOutcome {
        let remaining = ContinuousClock.now.duration(to: deadline)
        if remaining <= .zero { return .timedOut }

        return await withTaskGroup(of: AttachOutcome.self) { group in
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
                try? await Task.sleep(for: remaining)
                return .timedOut
            }
            let first = await group.next() ?? .transport(.connectionClosed)
            group.cancelAll()
            return first
        }
    }

    private func attachFailure(_ outcome: AttachOutcome, _ operation: String) -> UIAttachResult {
        var result = UIAttachResult()
        switch outcome {
        case .response(let response):
            result.status = .rpcError
            result.message = "\(operation) was rejected by Neovim"
            result.rpcError = response.error
        case .timedOut:
            result.status = .timedOut
            result.message = "\(operation) timed out"
        case .transport(let error):
            result.status = .transportError
            result.message = "\(operation) failed because the RPC connection closed"
            result.transportError = error
            switch error {
            case .readFailed(let code), .writeFailed(let code): result.systemError = code
            case .connectionClosed, .protocolViolation: break
            }
        }
        return result
    }

    /// The `nvim_set_client_info` arguments identifying this UI client.
    private func clientInfoArguments() -> [MPValue] {
        let version: MPValue = .map([(.string("major"), .int(0)), (.string("minor"), .int(1))])
        // Declares the reverse-RPC methods dispatched by `handleRequest`, so
        // channel inspection describes them; the `nargs` count matches.
        let methods: MPValue = .map([
            (.string("clipboard_get"), .map([(.string("nargs"), .int(0))])),
            (.string("clipboard_set"), .map([(.string("nargs"), .int(2))])),
        ])
        let attributes: MPValue = .map([(.string("license"), .string("MIT"))])
        return [.string("Nvmm"), version, .string("ui"), methods, attributes]
    }

    /// The requested options intersected with what Neovim supports, as map pairs.
    private func supportedOptions(requested: UIOptions,
                                  supported: [String]) -> [(MPValue, MPValue)] {
        var pairs: [(MPValue, MPValue)] = []
        for (name, value) in requestedOptionList(requested) where supported.contains(name) {
            pairs.append((.string(name), .bool(value)))
        }
        return pairs
    }
}

// MARK: - Transport I/O

/// Byte-level transport for one connection, confined to a single serial queue.
///
/// All mutable state below is touched only on `queue`, which is what makes the
/// `@unchecked Sendable` conformance sound. The read source runs for the life of
/// the connection; the write source is resumed only while `outgoing` is non-empty
/// so an idle connection does not spin. Event and cancel handlers retain `self`,
/// so the transport stays alive until both sources finish cancelling, at which
/// point the descriptors are closed and the retain cycle is broken.
private nonisolated final class TransportIO: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.nvmm.rpc", qos: .userInitiated)
    private let readFD: Int32
    private let writeFD: Int32
    private let limits: RPCResourceLimits
    private let emit: @Sendable (Inbound) -> Void

    private var readSource: DispatchSourceRead!
    private var writeSource: DispatchSourceWrite!
    private var readResumed = true
    private var writeResumed = false
    private var outgoing: [[UInt8]] = []
    private var outgoingHead = 0
    private var outgoingOffset = 0
    private var outgoingBytes = 0
    private var inboundQueuedBytes = 0
    private var readBuffer = [UInt8](repeating: 0, count: 16384)
    private var closed = false
    private var pendingCancels = 2

    init(readFD: Int32, writeFD: Int32, limits: RPCResourceLimits,
         emit: @escaping @Sendable (Inbound) -> Void) {
        self.readFD = readFD
        self.writeFD = writeFD
        self.limits = limits
        self.emit = emit

        setNonBlocking(readFD)
        if writeFD != readFD { setNonBlocking(writeFD) }

        readSource = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: writeFD, queue: queue)

        readSource.setEventHandler { self.canRead() }
        writeSource.setEventHandler { self.canWrite() }
        readSource.setCancelHandler { self.sourceCancelled() }
        writeSource.setCancelHandler { self.sourceCancelled() }

        // The read source runs immediately; the write source waits for data.
        readSource.resume()
    }

    /// Queues bytes to be written. Resumes the write source if it was idle.
    func send(_ bytes: [UInt8]) {
        queue.async {
            guard !self.closed else { return }
            guard bytes.count <=
                    self.limits.maximumOutboundQueuedBytes -
                    self.outgoingBytes
            else {
                self.beginShutdown(.protocolViolation)
                return
            }
            self.outgoing.append(bytes)
            self.outgoingBytes += bytes.count
            if !self.writeResumed {
                self.writeSource.resume()
                self.writeResumed = true
            }
        }
    }

    /// Returns credit after the process actor has consumed an inbound chunk.
    func didConsumeInbound(_ count: Int) {
        queue.async {
            self.inboundQueuedBytes -= count
            assert(self.inboundQueuedBytes >= 0)
            if !self.closed, !self.readResumed,
               self.inboundQueuedBytes <= self.limits.inboundResumeBytes {
                self.readSource.resume()
                self.readResumed = true
            }
        }
    }

    /// Begins an orderly shutdown: reports the disconnect, then cancels both
    /// sources. The descriptors are closed once both cancellations complete.
    func shutdown(_ error: RPCTransportError) {
        queue.async { self.beginShutdown(error) }
    }

    // MARK: Queue-confined

    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    private func canRead() {
        guard !closed else { return }
        var count = -1
        readBuffer.withUnsafeMutableBytes { raw in
            let credit = limits.maximumInboundQueuedBytes - inboundQueuedBytes
            repeat {
                count = read(readFD, raw.baseAddress, min(raw.count, credit))
            } while count == -1 && errno == EINTR
        }

        if count > 0 {
            inboundQueuedBytes += count
            emit(.data(Array(readBuffer[0..<count])))
            if inboundQueuedBytes >= limits.maximumInboundQueuedBytes {
                readSource.suspend()
                readResumed = false
            }
            return
        }
        if count == 0 {
            beginShutdown(.connectionClosed)
            return
        }
        let error = errno
        if error == EAGAIN || error == EWOULDBLOCK { return }
        beginShutdown(.readFailed(errno: error))
    }

    private func canWrite() {
        guard !closed else { return }
        if outgoingHead == outgoing.count {
            if writeResumed {
                writeSource.suspend()
                writeResumed = false
            }
            return
        }

        var written = -1
        outgoing[outgoingHead].withUnsafeBytes { raw in
            repeat {
                written = write(writeFD,
                                raw.baseAddress?.advanced(by: outgoingOffset),
                                raw.count - outgoingOffset)
            } while written == -1 && errno == EINTR
        }

        if written == -1 {
            let error = errno
            if error != EAGAIN && error != EWOULDBLOCK {
                beginShutdown(.writeFailed(errno: error))
            }
            return
        }

        outgoingOffset += written
        outgoingBytes -= written
        if outgoingOffset == outgoing[outgoingHead].count {
            outgoingHead += 1
            outgoingOffset = 0
            if outgoingHead == outgoing.count {
                outgoing.removeAll(keepingCapacity: true)
                outgoingHead = 0
                writeSource.suspend()
                writeResumed = false
            } else if outgoingHead > 1_024,
                      outgoingHead * 2 > outgoing.count {
                outgoing.removeFirst(outgoingHead)
                outgoingHead = 0
            }
        }
    }

    private func beginShutdown(_ error: RPCTransportError) {
        guard !closed else { return }
        closed = true
        emit(.disconnected(error))

        if !readResumed {
            readSource.resume()
            readResumed = true
        }
        readSource.cancel()
        // A suspended source must be resumed before it can be cancelled.
        if !writeResumed {
            writeSource.resume()
            writeResumed = true
        }
        writeSource.cancel()
    }

    private func sourceCancelled() {
        pendingCancels -= 1
        // Close only after both sources have finished cancelling, so neither is
        // still watching a descriptor that has been closed.
        guard pendingCancels == 0 else { return }
        close(readFD)
        if writeFD != readFD { close(writeFD) }
    }
}
