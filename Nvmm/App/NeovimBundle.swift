//
//  Nvmm
//  NeovimBundle.swift
//
//  Locates the nvim executable and runtime bundled inside the app. The build
//  copies the prebuilt distribution (from Scripts/download_nvim.sh) into the
//  bundle following Neovim's own bin/lib/share layout, mapped onto the app
//  bundle so nvim resolves its libraries (@executable_path/../lib) and runtime
//  (../share/nvim/runtime) unmodified:
//
//    Contents/MacOS/nvim          the executable (an auxiliary executable)
//    Contents/lib/*.dylib         relocated libraries
//    Contents/share/nvim/runtime  the Neovim runtime files
//

import Darwin
import Foundation

enum NeovimBundle {
    /// The bundled nvim executable, or nil if it is not present.
    static var executableURL: URL? {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "nvim") else {
            return nil
        }
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// The bundled Neovim runtime directory (VIMRUNTIME).
    static var runtimeURL: URL? {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/share/nvim/runtime", isDirectory: true)
    }

    /// The executable and argv to launch the embedded nvim with `arguments`
    /// (for example `["--embed"]`).
    ///
    /// Launched from a terminal (`TERM` set) nvim is spawned directly,
    /// inheriting the shell environment. Launched from the GUI — Finder,
    /// Spotlight, the Dock, Xcode — there is no shell environment, so nvim is
    /// exec'd from the user's login shell, which sources the login profile.
    /// That gives nvim the same `PATH`, exports, and tools an interactive
    /// shell has, so `init.lua` and anything it shells out to (LSP servers,
    /// plugin managers, providers) behave as they do in a terminal.
    nonisolated static func launchCommand(
        nvimPath: String, arguments: [String]
    ) -> (path: String, argv: [String]) {
        if ProcessInfo.processInfo.environment["TERM"] != nil {
            return (nvimPath, [nvimPath] + arguments)
        }
        return loginShellCommand(shell: loginShell(),
                                 nvimPath: nvimPath, arguments: arguments)
    }

    /// The command that runs nvim as an exec'd child of `shell`, run as a login
    /// shell. Pure so the argv construction can be tested with an injected shell.
    ///
    /// argv[0] is the shell name prefixed with `-`, the convention that asks a
    /// shell to behave as a login shell and source the login profile. `exec`
    /// replaces the shell with nvim so no shell process lingers holding the RPC
    /// pipes — a lingering wrapper would keep them open past `:detach` and
    /// withhold EOF from the client.
    nonisolated static func loginShellCommand(
        shell: String, nvimPath: String, arguments: [String]
    ) -> (path: String, argv: [String]) {
        var command = "exec " + spawnShellQuoteArg(nvimPath)
        for argument in arguments {
            command += " " + spawnShellQuoteArg(argument)
        }
        let shellName = (shell as NSString).lastPathComponent
        return (shell, ["-" + shellName, "-c", command])
    }

    /// The current user's login shell, or `/bin/sh` if it cannot be determined.
    private nonisolated static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            return String(cString: shell)
        }
        return "/bin/sh"
    }
}
