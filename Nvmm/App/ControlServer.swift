//
//  Nvmm
//  ControlServer.swift
//
//  The app's end of the nvmm control channel: a Unix domain socket that takes
//  one request per connection and answers it.
//
//  The listener binds before ordinary application startup, so a helper that
//  launched the app can be answered as soon as it connects. A request arrives
//  as one newline-terminated JSON line, is validated away from the editor's
//  RPC path, and is handed to `AppDelegate` on the main actor, which decides
//  which window opens.
//
//  A connection normally ends with its first response. `--wait` is the
//  exception: `CLIResponseChannel` holds it open past the acknowledgement so
//  the window's close can be reported on the same connection. That also means
//  an app which exits first reaches the helper as end-of-file.
//

import Darwin
import Foundation
import os

@MainActor
final class CLIResponseChannel {
    private weak var connection: ControlConnection?
    private var acceptedWait = false
    private var closePending = false
    private var finished = false

    fileprivate init(_ connection: ControlConnection) {
        self.connection = connection
    }

    nonisolated deinit {}

    func accepted(wait: Bool) {
        guard !finished, !acceptedWait else { return }
        if wait {
            acceptedWait = true
            connection?.send(.accepted)
            if closePending { closed() }
        } else {
            finished = true
            connection?.send(.accepted, close: true)
        }
    }

    func error(_ message: String) {
        guard !finished, !acceptedWait else { return }
        finished = true
        connection?.send(.error(message), close: true)
    }

    func closed() {
        guard !finished else { return }
        guard acceptedWait else {
            closePending = true
            return
        }
        finished = true
        connection?.send(.closed, close: true)
    }
}

@MainActor
struct ControlServerLimits {
    var maximumPendingConnections = 8
    var preRequestIdleTimeout: TimeInterval = 5
    var descriptorRetryInterval: TimeInterval = 1
}

@MainActor
final class ControlServer {
    typealias Handler = @MainActor (CLIRequest, CLIResponseChannel) -> Void
    typealias AcceptClient = @MainActor (Int32) -> Int32

    private enum AcceptState {
        case running
        case pausedForDescriptors
        case cancelled
    }

    private let path: String
    private let limits: ControlServerLimits
    private let handler: Handler
    private let acceptClient: AcceptClient
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var acceptState = AcceptState.cancelled
    private var descriptorRetryTimer: DispatchSourceTimer?
    private var descriptorExhaustionActive = false
    private var connections: [ObjectIdentifier: ControlConnection] = [:]
    private var pendingConnections: Set<ObjectIdentifier> = []

    init(
        path: String = CLIProtocol.endpointPath(),
        limits: ControlServerLimits = ControlServerLimits(),
        acceptClient: @escaping AcceptClient = { descriptor in
            Darwin.accept(descriptor, nil, nil)
        },
        handler: @escaping Handler
    ) throws {
        precondition(limits.maximumPendingConnections > 0)
        precondition(limits.preRequestIdleTimeout > 0)
        precondition(limits.descriptorRetryInterval > 0)
        self.path = path
        self.limits = limits
        self.acceptClient = acceptClient
        self.handler = handler
        try start()
    }

    deinit {
        descriptorRetryTimer?.cancel()
        if case .pausedForDescriptors = acceptState { source?.resume() }
        source?.cancel()
        if descriptor != -1 { close(descriptor) }
    }

    var pendingConnectionCount: Int { pendingConnections.count }
    var acceptIsPaused: Bool { acceptState == .pausedForDescriptors }

    func stop() {
        disableListener()
        let active = Array(connections.values)
        connections.removeAll()
        for connection in active { connection.finish() }
    }

    private func disableListener() {
        descriptorRetryTimer?.cancel()
        descriptorRetryTimer = nil
        if acceptState == .pausedForDescriptors { source?.resume() }
        acceptState = .cancelled
        source?.cancel()
        source = nil
        if descriptor != -1 {
            close(descriptor)
            descriptor = -1
        }
        var info = stat()
        if lstat(path, &info) == 0,
           info.st_mode & S_IFMT == S_IFSOCK,
           info.st_uid == geteuid() {
            _ = unlink(path)
        }
    }

    private func start() throws {
        try CLIEndpoint.prepareDirectory(
            (path as NSString).deletingLastPathComponent)
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket != -1 else { throw CLIError.system(errno) }
        descriptor = socket
        _ = fcntl(socket, F_SETFD, FD_CLOEXEC)
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)

        do {
            try bindSocket(socket)
            guard chmod(path, S_IRUSR | S_IWUSR) == 0,
                  listen(socket, 16) == 0 else {
                throw CLIError.system(errno)
            }
        } catch {
            close(socket)
            descriptor = -1
            throw error
        }

        let source = DispatchSource.makeReadSource(
            fileDescriptor: socket, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        self.source = source
        acceptState = .running
        source.resume()
    }

    private func bindSocket(_ socket: Int32) throws {
        func bind() throws -> Int32 {
            try CLIEndpoint.withAddress(path) {
                Darwin.bind(socket, $0,
                            socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard try bind() != 0 else { return }
        guard errno == EADDRINUSE else {
            throw CLIError.system(errno)
        }

        let probe = CLIEndpoint.connect(to: path)
        if probe.error == 0 {
            close(probe.fd)
            throw CLIError("Another Nvmm control server is already running.")
        }
        guard probe.error == ECONNREFUSED else {
            throw CLIError.system(probe.error)
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == geteuid() else {
            throw CLIError("Refusing to replace an unsafe control socket "
                           + "path.")
        }
        guard unlink(path) == 0, try bind() == 0 else {
            throw CLIError.system(errno)
        }
    }

    private func acceptClients() {
        while acceptState == .running {
            let client = acceptClient(descriptor)
            if client == -1 {
                if errno == EINTR { continue }
                if errno == EMFILE || errno == ENFILE {
                    pauseForDescriptorExhaustion()
                }
                return
            }
            if descriptorExhaustionActive {
                descriptorExhaustionActive = false
                Log.control.info("Control socket descriptor pressure recovered")
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            _ = fcntl(client, F_SETFL,
                      fcntl(client, F_GETFL) | O_NONBLOCK)
            var noPipe: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noPipe,
                           socklen_t(MemoryLayout<Int32>.size))
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(client, &peerUID, &peerGID) == 0,
                  peerUID == geteuid() else {
                close(client)
                continue
            }
            guard pendingConnections.count
                    < limits.maximumPendingConnections else {
                sendTerminalError(
                    "Too many pending control connections.", to: client)
                continue
            }

            let connection = ControlConnection(
                descriptor: client,
                preRequestIdleTimeout: limits.preRequestIdleTimeout,
                receive: { [weak self] request, channel in
                    self?.receive(request, channel)
                },
                requestComplete: { [weak self] connection in
                    self?.releasePending(connection)
                },
                finish: { [weak self] connection in
                    self?.connectionFinished(connection)
                })
            let identifier = ObjectIdentifier(connection)
            connections[identifier] = connection
            pendingConnections.insert(identifier)
            connection.start()
        }
    }

    private func sendTerminalError(_ message: String, to client: Int32) {
        guard var data = try? JSONEncoder().encode(
            CLIResponse.error(message)) else {
            close(client)
            return
        }
        data.append(0x0a)
        _ = data.withUnsafeBytes { bytes in
            Darwin.write(client, bytes.baseAddress, bytes.count)
        }
        close(client)
    }

    private func releasePending(_ connection: ControlConnection) {
        let identifier = ObjectIdentifier(connection)
        guard pendingConnections.remove(identifier) != nil else { return }
        resumeAcceptingIfPaused()
    }

    private func connectionFinished(_ connection: ControlConnection) {
        let identifier = ObjectIdentifier(connection)
        connections.removeValue(forKey: identifier)
        _ = pendingConnections.remove(identifier)
        resumeAcceptingIfPaused()
    }

    private func pauseForDescriptorExhaustion() {
        guard acceptState == .running, let source else { return }
        acceptState = .pausedForDescriptors
        source.suspend()
        if !descriptorExhaustionActive {
            descriptorExhaustionActive = true
            Log.control.error(
                "Control socket paused by descriptor exhaustion")
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + limits.descriptorRetryInterval)
        timer.setEventHandler { [weak self] in
            self?.resumeAcceptingIfPaused()
        }
        descriptorRetryTimer = timer
        timer.resume()
    }

    private func resumeAcceptingIfPaused() {
        guard acceptState == .pausedForDescriptors, let source else { return }
        acceptState = .running
        descriptorRetryTimer?.cancel()
        descriptorRetryTimer = nil
        source.resume()
    }

    private func receive(_ request: CLIRequest,
                         _ channel: CLIResponseChannel) {
        do {
            try request.validate()
            handler(request, channel)
        } catch let error as CLIProtocolError {
            channel.error(error.message)
        } catch {
            channel.error("Invalid control request.")
        }
    }
}

@MainActor
private final class ControlConnection {
    let descriptor: Int32
    private let receive:
        @MainActor (CLIRequest, CLIResponseChannel) -> Void
    private let preRequestIdleTimeout: TimeInterval
    private let didCompleteRequest: @MainActor (ControlConnection) -> Void
    private let didFinish: @MainActor (ControlConnection) -> Void
    private var source: DispatchSourceRead?
    private var deadline: DispatchSourceTimer?
    private var input = Data()
    private var awaitingRequest = true
    private var finished = false
    private lazy var channel = CLIResponseChannel(self)

    init(
        descriptor: Int32,
        preRequestIdleTimeout: TimeInterval,
        receive: @escaping @MainActor (CLIRequest, CLIResponseChannel) -> Void,
        requestComplete: @escaping @MainActor (ControlConnection) -> Void,
        finish: @escaping @MainActor (ControlConnection) -> Void
    ) {
        self.descriptor = descriptor
        self.preRequestIdleTimeout = preRequestIdleTimeout
        self.receive = receive
        didCompleteRequest = requestComplete
        didFinish = finish
    }

    nonisolated deinit {}

    func start() {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in self?.readRequest() }
        self.source = source
        source.resume()

        let deadline = DispatchSource.makeTimerSource(queue: .main)
        deadline.schedule(deadline: .now() + preRequestIdleTimeout)
        deadline.setEventHandler { [weak self] in
            guard let self, self.awaitingRequest else { return }
            self.finish()
        }
        self.deadline = deadline
        deadline.resume()
    }

    func send(_ response: CLIResponse, close shouldClose: Bool = false) {
        guard !finished,
              var data = try? JSONEncoder().encode(response) else {
            finish()
            return
        }
        data.append(0x0a)
        // One write suffices. A connection sends at most two short responses
        // - an acknowledgement and, for a held connection, its close - and an
        // error response is terminal, so what one connection writes cannot
        // approach the socket's send buffer. A short write therefore means
        // the peer is gone rather than that the buffer is full.
        let count = data.withUnsafeBytes {
            Darwin.write(descriptor, $0.baseAddress, $0.count)
        }
        if count != data.count || shouldClose { finish() }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        deadline = nil
        source?.cancel()
        source = nil
        close(descriptor)
        if awaitingRequest {
            awaitingRequest = false
            didCompleteRequest(self)
        }
        didFinish(self)
    }

    private func completeRequest() {
        guard awaitingRequest else { return }
        awaitingRequest = false
        deadline?.cancel()
        deadline = nil
        didCompleteRequest(self)
    }

    private func readRequest() {
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                input.append(buffer, count: count)
                if input.count > CLIProtocol.maximumRequestBytes {
                    channel.error("Control request is too large.")
                    return
                }
                guard let newline = input.firstIndex(of: 0x0a) else {
                    continue
                }
                guard newline == input.index(before: input.endIndex) else {
                    channel.error("Control request has trailing data.")
                    return
                }
                source?.cancel()
                source = nil
                do {
                    let request = try JSONDecoder().decode(
                        CLIRequest.self, from: input[..<newline])
                    // Handlers enqueue asynchronous application work and
                    // return promptly before this releases the pending slot.
                    defer { completeRequest() }
                    receive(request, channel)
                } catch {
                    channel.error("Control request is not valid JSON.")
                }
                return
            }
            if count == 0 {
                finish()
            } else if errno == EINTR {
                continue
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                finish()
            }
            return
        }
    }
}
