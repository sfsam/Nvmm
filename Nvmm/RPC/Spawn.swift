//
//  Nvmm
//  Spawn.swift
//
//  Low-level process and socket plumbing for the RPC transport: launching a
//  child process with redirected standard streams (posix_spawn), creating
//  pipes, connecting Unix or TCP sockets, and shell-quoting an argument.
//
//  These are pure syscall wrappers with no isolation requirements, so they are
//  marked nonisolated and can be called from the NeovimProcess actor.
//

import Darwin
import Dispatch
import Foundation

/// Quotes one argument for a `/bin/sh` command line.
///
/// The result is wrapped in single quotes, and any embedded single quote is
/// rewritten as `'\''` (close quote, escaped quote, reopen quote). Every other
/// byte, including shell metacharacters, is passed through literally, so the
/// shell reproduces the input exactly.
nonisolated func spawnShellQuoteArg(_ value: String) -> String {
    var quoted = "'"
    for character in value {
        if character == "'" {
            quoted += "'\\''"
        } else {
            quoted.append(character)
        }
    }
    quoted += "'"
    return quoted
}

/// A Neovim server address accepted by the connection UI.
nonisolated enum RPCAddress: Sendable, Equatable {
    case unix(path: String)
    case tcp(host: String, port: UInt16)
}

/// Treats `host:port` and `[IPv6]:port` as TCP. Every other value remains a
/// Unix socket path, which preserves support for relative socket paths.
nonisolated func parseRPCAddress(_ value: String) -> RPCAddress {
    if value.hasPrefix("/") { return .unix(path: value) }

    if value.first == "[", let closing = value.firstIndex(of: "]") {
        let host = String(value[value.index(after: value.startIndex)..<closing])
        let suffix = value[value.index(after: closing)...]
        if suffix.first == ":", let port = UInt16(suffix.dropFirst()), port > 0,
           !host.isEmpty {
            return .tcp(host: host, port: port)
        }
    } else if let separator = value.lastIndex(of: ":") {
        let host = String(value[..<separator])
        let portText = value[value.index(after: separator)...]
        if !host.contains(":"), let port = UInt16(portText), port > 0,
           !host.isEmpty {
            return .tcp(host: host, port: port)
        }
    }

    return .unix(path: value)
}

/// Process and socket plumbing for the RPC transport.
nonisolated enum Spawn {
    private static let tcpConnectTimeoutMilliseconds: Int32 = 5_000

    /// A child process's standard streams. A stream left at -1 is inherited
    /// from the parent; otherwise the descriptor is duplicated onto the child's
    /// standard input (0), output (1), or error (2).
    struct Streams {
        var input: Int32 = -1
        var output: Int32 = -1
        var error: Int32 = -1
    }

    /// The two ends of a pipe created by `openPipe`.
    struct Pipe {
        var readEnd: Int32
        var writeEnd: Int32
    }

    /// The result of `spawn`: a process id, valid only when `error` is zero,
    /// and an errno error code.
    struct Result {
        var pid: pid_t
        var error: Int32
    }

    /// How a spawned child finished, or why its status could not be collected.
    enum Termination: Sendable, Equatable {
        case exited(status: Int32)
        case signaled(signal: Int32)
        case waitFailed(errno: Int32)
    }

    /// Opens a pipe with the close-on-exec flag set on both descriptors.
    /// Returns the pipe and a zero error code, or invalid descriptors and an
    /// errno on failure.
    static func openPipe() -> (pipe: Pipe, error: Int32) {
        var fds: [Int32] = [-1, -1]
        if pipe(&fds) != 0 {
            return (Pipe(readEnd: -1, writeEnd: -1), errno)
        }
        // Racey, but the best we can do: another thread could fork between the
        // pipe() and the fcntl() calls.
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        return (Pipe(readEnd: fds[0], writeEnd: fds[1]), 0)
    }

    /// Spawns a child process executing `path`.
    ///
    /// The child inherits the current process environment, extended by `env`
    /// (each entry a `KEY=VALUE` string). When `workingDirectory` is non-nil
    /// and non-empty the child changes into it before exec.
    ///
    /// - Returns: A `Result`. When `error` is non-zero no process was created
    ///   and `pid` is undefined.
    static func spawn(path: String, argv: [String], env: [String],
                      workingDirectory: String?, streams: Streams) -> Result {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // The child must be able to handle Nvmm's orderly shutdown signal even
        // if the parent process ignored or blocked it.
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)

        var signalMask = sigset_t()
        pthread_sigmask(SIG_SETMASK, nil, &signalMask)
        sigdelset(&signalMask, SIGTERM)
        posix_spawnattr_setsigmask(&attributes, &signalMask)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        if let directory = workingDirectory, !directory.isEmpty {
            let code = posix_spawn_file_actions_addchdir_np(&actions, directory)
            if code != 0 { return Result(pid: 0, error: code) }
        }

        for (source, target) in [(streams.input, 0), (streams.output, 1), (streams.error, 2)] {
            guard source != -1 else { continue }
            let code = posix_spawn_file_actions_adddup2(&actions, source, Int32(target))
            if code != 0 { return Result(pid: 0, error: code) }
        }

        // Inherit the parent environment, with the caller's entries replacing
        // the values of the keys they name. Appending them instead would leave
        // both: a C `getenv` answers with the first of two entries for a key,
        // which is the inherited one, so the caller's value would be ignored.
        var environment = ProcessInfo.processInfo.environment
        for entry in env {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<separator])] =
                String(entry[entry.index(after: separator)...])
        }
        let fullEnv = environment.map { "\($0.key)=\($0.value)" }

        var argvC = argv.map { strdup($0) }
        argvC.append(nil)
        var envC = fullEnv.map { strdup($0) }
        envC.append(nil)
        defer {
            for pointer in argvC where pointer != nil { free(pointer) }
            for pointer in envC where pointer != nil { free(pointer) }
        }

        var pid: pid_t = 0
        let code = posix_spawn(&pid, path, &actions, &attributes, argvC, envC)
        return Result(pid: pid, error: code)
    }

    /// Reaps one exact child without blocking a Swift concurrency executor.
    static func wait(forChild pid: pid_t) async -> Termination {
        precondition(pid > 0)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while true {
                    let waited = Darwin.waitpid(pid, &status, 0)
                    if waited == pid {
                        let signal = status & 0x7f
                        if signal == 0 {
                            continuation.resume(returning: .exited(
                                status: (status >> 8) & 0xff))
                        } else {
                            continuation.resume(
                                returning: .signaled(signal: signal))
                        }
                        return
                    }

                    let failure = errno
                    if waited == -1 && failure == EINTR {
                        continue
                    }
                    continuation.resume(returning: .waitFailed(errno: failure))
                    return
                }
            }
        }
    }

    /// Connects to a Neovim server at a Unix socket path or TCP address.
    /// - Returns: A connected descriptor and a zero error code, or -1 and an
    ///   errno on failure.
    static func connectRPCAddress(_ address: RPCAddress) -> (fd: Int32, error: Int32) {
        switch address {
        case .unix(let path): return connectUnixSocket(path)
        case .tcp(let host, let port): return connectTCPSocket(host: host, port: port)
        }
    }

    private static func connectUnixSocket(_ address: String) -> (fd: Int32, error: Int32) {
        let pathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        let bytes = Array(address.utf8)
        if bytes.count >= pathCapacity {
            return (-1, EINVAL)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd == -1 {
            return (-1, errno)
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(bytes.count + 1)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }

        let code = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                Darwin.connect(fd, sockAddr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if code == -1 {
            let failure = errno
            close(fd)
            return (-1, failure)
        }
        return (fd, 0)
    }

    private static func connectTCPSocket(
        host: String, port: UInt16
    ) -> (fd: Int32, error: Int32) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let status = host.withCString { host in
            String(port).withCString { service in
                getaddrinfo(host, service, &hints, &result)
            }
        }
        guard status == 0, let first = result else {
            return (-1, EHOSTUNREACH)
        }
        defer { freeaddrinfo(first) }

        var candidate: UnsafeMutablePointer<addrinfo>? = first
        var failure = ECONNREFUSED
        while let info = candidate {
            let value = info.pointee
            let fd = socket(value.ai_family, value.ai_socktype, value.ai_protocol)
            if fd != -1 {
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                let flags = fcntl(fd, F_GETFL, 0)
                if flags == -1 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) == -1 {
                    failure = errno
                    close(fd)
                } else if connectTCP(fd, address: value) == 0 {
                    return (fd, 0)
                } else {
                    failure = errno
                    close(fd)
                }
            } else {
                failure = errno
            }
            candidate = value.ai_next
        }
        return (-1, failure)
    }

    /// Completes a nonblocking TCP connect within the startup deadline.
    private static func connectTCP(_ fd: Int32, address: addrinfo) -> Int32 {
        if Darwin.connect(fd, address.ai_addr, address.ai_addrlen) == 0 {
            return 0
        }
        guard errno == EINPROGRESS else { return -1 }

        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let waited = poll(&descriptor, 1, tcpConnectTimeoutMilliseconds)
        if waited == 0 {
            errno = ETIMEDOUT
            return -1
        }
        guard waited > 0 else { return -1 }

        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else {
            return -1
        }
        if error != 0 {
            errno = error
            return -1
        }
        return 0
    }
}
