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

    private var writer = MessagePackWriter()
    private var unpacker = MessagePackUnpacker()

    private let inbound: AsyncStream<Inbound>
    private let inboundContinuation: AsyncStream<Inbound>.Continuation

    /// Notifications Neovim sends the client, in wire order. Once a UI is
    /// attached, the controller consumes `redraw`, `vimenter`, `progress`, and
    /// `modified`, so those no longer appear here. The stream finishes when the
    /// connection closes.
    nonisolated let notifications: AsyncStream<RPCNotification>
    private let notificationsContinuation: AsyncStream<RPCNotification>.Continuation

    /// UI model, present once `uiAttach` has run. Redraw notifications feed it.
    private var ui: UIController?

    /// Grid snapshots published on each flush, in order. The stream finishes
    /// when the connection closes.
    nonisolated let grids: AsyncStream<Grid>
    private let gridsContinuation: AsyncStream<Grid>.Continuation

    /// The current buffer's `modified` state, published on each transition so
    /// the window can show a document-edited dot. Finishes on disconnect.
    nonisolated let modifiedStates: AsyncStream<Bool>
    private let modifiedStatesContinuation: AsyncStream<Bool>.Continuation

    init() {
        let inboundPair = AsyncStream.makeStream(of: Inbound.self)
        inbound = inboundPair.stream
        inboundContinuation = inboundPair.continuation

        let notificationPair = AsyncStream.makeStream(of: RPCNotification.self)
        notifications = notificationPair.stream
        notificationsContinuation = notificationPair.continuation

        let gridsPair = AsyncStream.makeStream(of: Grid.self)
        grids = gridsPair.stream
        gridsContinuation = gridsPair.continuation

        let modifiedPair = AsyncStream.makeStream(of: Bool.self)
        modifiedStates = modifiedPair.stream
        modifiedStatesContinuation = modifiedPair.continuation
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

        // The child reads its stdin from the write pipe and writes its stdout
        // to the read pipe; the parent keeps the opposite ends.
        let streams = Spawn.Streams(input: write.pipe.readEnd, output: read.pipe.writeEnd)
        let result = Spawn.spawn(path: path, argv: argv, env: env,
                                 workingDirectory: workingDirectory, streams: streams)

        // Close the descriptors the child duplicated, whether or not it spawned.
        close(write.pipe.readEnd)
        close(read.pipe.writeEnd)

        if result.error != 0 {
            close(read.pipe.readEnd)
            close(write.pipe.writeEnd)
            throw NeovimSpawnError(code: result.error, operation: "spawn")
        }

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
        io = TransportIO(readFD: readFD, writeFD: writeFD) { event in
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

    /// Applies one input command as its `nvim_*` notification. Callers funnel
    /// key, mouse, resize, and focus events through a single ordered channel and
    /// `perform` here so they reach Neovim in the order the user produced them.
    func perform(_ command: NvimCommand) {
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
            notify("nvim_paste", [.string(data), false, -1])
        case .errorWriteln(let text):
            notify("nvim_echo",
                   [.array([.array([.string(text)])]), true,
                    .map([(.string("err"), true)])])
        case .quit(let force):
            // `silent!` suppresses the "no write since last change" error (and
            // its press-a-key prompt) that a refused non-forced quit would spill
            // into the editor; the command still quits when buffers are clean.
            notify("nvim_command",
                   [.string(force ? "silent! quitall!" : "silent! quitall")])
        }
    }

    /// Whether any loaded buffer has unsaved changes. Assumes unsaved on an
    /// error, timeout, or unexpected result, so a quit is never issued that
    /// could silently discard work.
    func hasUnsavedBuffers() async -> Bool {
        let expr = "len(filter(map(getbufinfo(), 'v:val.changed'), 'v:val'))"
        guard let response = try? await request("nvim_eval", [.string(expr)]),
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
            while let value = unpacker.unpack() {
                dispatch(value)
            }
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
                for grid in ui.redraw(arguments) { gridsContinuation.yield(grid) }
                return
            case "vimenter":
                ui.vimenter()
                return
            case "progress":
                if arguments.count == 1, case .map(let event) = arguments[0] {
                    ui.progress(event)
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
        guard let id = message[1].integer?.unsigned,
              let method = message[2].stringValue else { return }
        // The client exposes no methods yet, so every request is rejected.
        let error: MPValue = .array([.int(1), .string("Unknown method: \(method)")])
        guard state == .connected else { return }
        send { $0.encodeResponse(id: id, error: error, result: .null) }
    }

    private func finishDisconnect(_ error: RPCTransportError) {
        guard state != .closed else { return }
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

// MARK: - UI attachment

extension NeovimProcess {
    /// The most recent flushed grid, or nil if no UI has attached and drawn.
    func currentGrid() -> Grid? { ui?.globalGrid }

    /// A pending restart/connect handoff Neovim requested, if any.
    func pendingHandoff() -> UIHandoff? { ui?.handoff }

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
        let controller = ui ?? UIController()
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

        let attachOptions = supportedOptions(requested: options,
                                             supported: capabilities.uiOptions)
        let attachArgs: [MPValue] = [.int(MPInteger(width)),
                                     .int(MPInteger(height)), .map(attachOptions)]
        let attachOutcome = await requestWaiting("nvim_ui_attach", attachArgs, until: deadline)
        guard case .response(let attached) = attachOutcome, !attached.isError else {
            return attachFailure(attachOutcome, "UI attachment")
        }

        installModifiedAutocmd()

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
            case .connectionClosed: break
            }
        }
        return result
    }

    /// The `nvim_set_client_info` arguments identifying this UI client.
    private func clientInfoArguments() -> [MPValue] {
        let version: MPValue = .map([(.string("major"), .int(0)), (.string("minor"), .int(1))])
        let methods: MPValue = .map([])
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
    private let emit: @Sendable (Inbound) -> Void

    private var readSource: DispatchSourceRead!
    private var writeSource: DispatchSourceWrite!
    private var writeResumed = false
    private var outgoing: [UInt8] = []
    private var readBuffer = [UInt8](repeating: 0, count: 16384)
    private var closed = false
    private var pendingCancels = 2

    init(readFD: Int32, writeFD: Int32, emit: @escaping @Sendable (Inbound) -> Void) {
        self.readFD = readFD
        self.writeFD = writeFD
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
            self.outgoing.append(contentsOf: bytes)
            if !self.writeResumed {
                self.writeSource.resume()
                self.writeResumed = true
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
            repeat {
                count = read(readFD, raw.baseAddress, raw.count)
            } while count == -1 && errno == EINTR
        }

        if count > 0 {
            emit(.data(Array(readBuffer[0..<count])))
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
        if outgoing.isEmpty {
            if writeResumed {
                writeSource.suspend()
                writeResumed = false
            }
            return
        }

        var written = -1
        outgoing.withUnsafeBytes { raw in
            repeat {
                written = write(writeFD, raw.baseAddress, raw.count)
            } while written == -1 && errno == EINTR
        }

        if written == -1 {
            let error = errno
            if error != EAGAIN && error != EWOULDBLOCK {
                beginShutdown(.writeFailed(errno: error))
            }
            return
        }

        outgoing.removeFirst(written)
        if outgoing.isEmpty {
            writeSource.suspend()
            writeResumed = false
        }
    }

    private func beginShutdown(_ error: RPCTransportError) {
        guard !closed else { return }
        closed = true
        emit(.disconnected(error))

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
