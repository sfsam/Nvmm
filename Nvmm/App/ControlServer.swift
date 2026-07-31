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
final class ControlServer {
    typealias Handler = @MainActor (CLIRequest, CLIResponseChannel) -> Void

    private let path: String
    private let handler: Handler
    private var descriptor: Int32 = -1
    // Only ever running or cancelled, never suspended: releasing a suspended
    // dispatch source traps in libdispatch.
    private var source: DispatchSourceRead?
    private var connections: [ObjectIdentifier: ControlConnection] = [:]

    init(path: String = CLIProtocol.endpointPath(),
         handler: @escaping Handler) throws {
        self.path = path
        self.handler = handler
        try start()
    }

    deinit {
        if descriptor != -1 { close(descriptor) }
    }

    func stop() {
        disableListener()
        let active = Array(connections.values)
        connections.removeAll()
        for connection in active { connection.finish() }
    }

    private func disableListener() {
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
        while true {
            let client = accept(descriptor, nil, nil)
            if client == -1 {
                if errno == EINTR { continue }
                // Out of file descriptors: the connection stays queued and the
                // listener stays readable, so returning would re-enter at once
                // and starve the main queue — measured at roughly half a
                // million handler calls a second. Give up the control channel
                // for this run rather than freeze the editor. Recovering it
                // would cost more code than a process this sick is worth.
                if errno == EMFILE || errno == ENFILE {
                    Log.control.error("""
                        No descriptors for control socket; \
                        CLI requests disabled
                        """)
                    disableListener()
                }
                return
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

            let connection = ControlConnection(
                descriptor: client,
                receive: { [weak self] request, channel in
                    self?.receive(request, channel)
                },
                finish: { [weak self] connection in
                    self?.connections.removeValue(
                        forKey: ObjectIdentifier(connection))
                })
            connections[ObjectIdentifier(connection)] = connection
            connection.start()
        }
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
    private let didFinish: @MainActor (ControlConnection) -> Void
    private var source: DispatchSourceRead?
    private var input = Data()
    private var finished = false
    private lazy var channel = CLIResponseChannel(self)

    init(
        descriptor: Int32,
        receive: @escaping @MainActor (CLIRequest, CLIResponseChannel) -> Void,
        finish: @escaping @MainActor (ControlConnection) -> Void
    ) {
        self.descriptor = descriptor
        self.receive = receive
        didFinish = finish
    }

    nonisolated deinit {}

    func start() {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in self?.readRequest() }
        self.source = source
        source.resume()
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
        source?.cancel()
        source = nil
        close(descriptor)
        didFinish(self)
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
                    receive(try JSONDecoder().decode(
                        CLIRequest.self, from: input[..<newline]), channel)
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
