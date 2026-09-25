//
//  NvmmTests
//  NeovimTestSupport.swift
//
//  Shared scaffolding for the tests that run a real bundled Neovim: spawning
//  it isolated from the user's configuration, attaching a UI, and waiting on
//  the state its main loop produces after a call returns.
//

import XCTest
@testable import Nvmm

struct NeovimTestError: Error {}

/// A headless Neovim listening on a socket, for tests that connect to it.
struct ListeningNvim {
    let socket: String
    let process: Process
}

extension XCTestCase {

    /// The bundled Neovim, or a skip when the build has none.
    func bundledNvim() async throws -> URL {
        guard let nvim = await MainActor.run(
            body: { NeovimBundle.executableURL }) else {
            throw XCTSkip("bundled nvim executable not available")
        }
        return nvim
    }

    /// Private XDG directories keep a test from reading user configuration
    /// and keep swap or state files from affecting later test or editor runs.
    func isolatedNvimEnvironment(root: URL) -> [String] {
        [
            "EXINIT=",
            "NVIM_APPNAME=nvim",
            "VIMINIT=",
            "XDG_CACHE_HOME=\(root.appendingPathComponent("cache").path)",
            "XDG_CONFIG_HOME=\(root.appendingPathComponent("config").path)",
            "XDG_CONFIG_DIRS=\(root.appendingPathComponent("config-dirs").path)",
            "XDG_DATA_HOME=\(root.appendingPathComponent("data").path)",
            "XDG_DATA_DIRS=\(root.appendingPathComponent("data-dirs").path)",
            "XDG_STATE_HOME=\(root.appendingPathComponent("state").path)",
        ]
    }

    /// Spawns a real bundled Neovim and reaps the child when the test ends.
    ///
    /// Closing the transport alone is not enough: a buffer left modified sends
    /// Neovim to a prompt on its way out, and with no UI to answer it the
    /// process waits there forever. `terminateChild` escalates to `SIGKILL`,
    /// which ends it whatever state it stopped in.
    func spawnNvim(_ arguments: [String]) async throws -> NeovimProcess {
        let nvim = try await bundledNvim()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmm-test-\(UUID().uuidString)")
        let process = NeovimProcess()
        try await process.spawn(
            path: nvim.path, argv: [nvim.path] + arguments,
            env: isolatedNvimEnvironment(root: root))
        addTeardownBlock {
            await process.disconnect()
            _ = await process.terminateChild()
            try? FileManager.default.removeItem(at: root)
        }
        return process
    }

    /// Runs `body` against an embedded Neovim with no configuration at all.
    func withNvim(
        _ body: (NeovimProcess) async throws -> Void
    ) async throws {
        try await body(spawnNvim(["--embed", "-n", "-u", "NONE", "-i", "NONE"]))
    }

    /// Runs `body` against an embedded Neovim whose private configuration
    /// directory holds `initLua` and, when given, `ginitVim`.
    func withConfiguredNvim(
        initLua: String,
        ginitVim: String?,
        arguments: [String] = [],
        _ body: (NeovimProcess) async throws -> Void
    ) async throws {
        let nvim = try await bundledNvim()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmm-config-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeConfiguration(root: root, initLua: initLua, ginitVim: ginitVim)

        let process = NeovimProcess()
        try await process.spawn(
            path: nvim.path,
            argv: [nvim.path, "--embed", "-n", "-i", "NONE"] + arguments,
            env: isolatedNvimEnvironment(root: root))
        do {
            try await body(process)
        } catch {
            await process.disconnect()
            _ = await process.terminateChild()
            throw error
        }
        await process.disconnect()
        _ = await process.terminateChild()
    }

    /// Runs `body` against a headless Neovim listening on a fresh socket.
    /// The server is killed afterward: tests leave modified buffers, and a
    /// `SIGTERM` would send it to a prompt no UI can answer.
    func withListeningNvim(
        ginitVim: String? = nil,
        _ body: (ListeningNvim) async throws -> Void
    ) async throws {
        let nvim = try await bundledNvim()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmm-server-test-\(UUID().uuidString)")
        try writeConfiguration(root: root, initLua: nil, ginitVim: ginitVim)
        let socket = NSTemporaryDirectory()
            + "nvmm-server-\(UUID().uuidString).sock"

        var environment = ProcessInfo.processInfo.environment
        for entry in isolatedNvimEnvironment(root: root) {
            let pair = entry.split(
                separator: "=", maxSplits: 1,
                omittingEmptySubsequences: false)
            environment[String(pair[0])] = String(pair[1])
        }
        let server = Process()
        server.executableURL = nvim
        server.arguments = ["--headless", "-n", "-i", "NONE",
                            "--listen", socket]
        server.environment = environment
        try server.run()
        defer {
            if server.isRunning { kill(server.processIdentifier, SIGKILL) }
            try? FileManager.default.removeItem(atPath: socket)
            try? FileManager.default.removeItem(at: root)
        }

        // The server creates the socket asynchronously.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: socket) {
            if ContinuousClock.now >= deadline {
                throw XCTSkip("nvim server socket did not appear")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await body(ListeningNvim(socket: socket, process: server))
    }

    private func writeConfiguration(
        root: URL, initLua: String?, ginitVim: String?
    ) throws {
        let config = root.appendingPathComponent("config/nvim")
        try FileManager.default.createDirectory(
            at: config, withIntermediateDirectories: true)
        if let initLua {
            try Data(initLua.utf8).write(
                to: config.appendingPathComponent("init.lua"))
        }
        if let ginitVim {
            try Data(ginitVim.utf8).write(
                to: config.appendingPathComponent("ginit.vim"))
        }
    }

    /// Attaches an 80x24 linegrid UI and runs GUI startup, failing the test
    /// if Neovim refuses the attachment.
    func attachLinegridUI(_ process: NeovimProcess) async throws {
        var options = UIOptions()
        options.extLinegrid = true
        let result = await process.uiAttach(
            width: 80, height: 24, options: options)
        guard result.status == .success else {
            XCTFail(
                "attach failed: \(result.status) \(result.message) "
                    + "\(String(describing: result.rpcError))")
            throw NeovimTestError()
        }
        await process.activateGUIStartup()
    }

    /// Polls a Vimscript condition until it holds. Typed keys are consumed by
    /// Neovim's main loop rather than answered like a request, so the state
    /// they produce arrives after the call that sent them.
    func waitUntilTrue(
        _ process: NeovimProcess, _ expr: String,
        timeout: Duration = .seconds(3)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let reply = try? await process.request(
                "nvim_eval", [.string(expr)])
            if let reply, !reply.isError,
               reply.result.integer?.signed == 1 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
}

/// Awaits the first stream value matching `predicate`, or nil on timeout.
func awaitFirst<T: Sendable>(
    _ stream: AsyncStream<T>,
    timeout: Duration = .seconds(2),
    where predicate: @escaping @Sendable (T) -> Bool
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            for await value in stream where predicate(value) { return value }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

/// The first grid published once GUI startup has completed.
func awaitStartupGrid(
    _ stream: AsyncStream<Grid>, timeout: Duration = .seconds(2)
) async -> Grid? {
    await awaitFirst(stream, timeout: timeout) { $0.startupComplete }
}

/// The first grid whose text contains every one of `needles`.
func awaitGrid(
    _ stream: AsyncStream<Grid>, containing needles: [String],
    timeout: Duration = .seconds(2)
) async -> Grid? {
    await awaitFirst(stream, timeout: timeout) { grid in
        let text = (0..<grid.size.height).map { row in
            (0..<grid.size.width).map { grid.cell(row, $0).text }.joined()
        }.joined(separator: "\n")
        return needles.allSatisfy { text.contains($0) }
    }
}
