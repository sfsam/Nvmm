//
//  Nvmm
//  Spawn.swift
//
//  Low-level process and socket plumbing for the RPC transport: launching a
//  child process with redirected standard streams (posix_spawn), creating
//  pipes, connecting a Unix domain socket, and shell-quoting an argument.
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

/// Process and socket plumbing for the RPC transport.
nonisolated enum Spawn {
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

        // Inherit the parent environment and append the caller's additions.
        let fullEnv = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" } + env

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

    /// Connects a new stream socket to a Unix domain socket address.
    /// - Returns: A connected descriptor and a zero error code, or -1 and an
    ///   errno on failure.
    static func connectUnixSocket(_ address: String) -> (fd: Int32, error: Int32) {
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
}
