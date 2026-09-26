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
//  The bundled copy is the default. Settings can name another Neovim instead;
//  `executablePath` picks the one a launch uses.
//

import Darwin
import Foundation

/// Why no Neovim executable could be chosen for a launch.
nonisolated enum NeovimLaunchError: Error, Equatable {
    case invalidCustomPath(String)
    case bundledExecutableMissing

    var title: String {
        switch self {
        case .invalidCustomPath:
            String(localized: "Could Not Start Neovim")
        case .bundledExecutableMissing:
            String(localized: "Nvmm Is Incomplete or Damaged")
        }
    }

    var message: String {
        switch self {
        case .invalidCustomPath(let path) where path.isEmpty:
            String(localized:
                "Choose a Neovim executable in Settings, or select Bundled.")
        case .invalidCustomPath(let path):
            String(localized:
                "The Neovim chosen in Settings is not an executable file: “\(path)”.")
        case .bundledExecutableMissing:
            String(localized:
                "The bundled Neovim executable is missing. Reinstall Nvmm.")
        }
    }
}

enum NeovimBundle {
    /// The bundled nvim executable, or nil if it is not present.
    static var executableURL: URL? {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "nvim") else {
            return nil
        }
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// The built-in help tag index beside the bundled Neovim runtime.
    static var helpTagsURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/share/nvim/runtime/doc/tags")
    }

    /// Whether `path` is an absolute path to an executable regular file.
    /// Nothing is expanded: no `~`, variable, or command name. Symlinks are
    /// followed.
    nonisolated static func isExecutablePath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        var isDirectory: ObjCBool = false
        let manager = FileManager.default
        return manager.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && manager.isExecutableFile(atPath: path)
    }

    /// The nvim a launch runs: the custom one when Settings chooses it,
    /// otherwise the bundled one.
    ///
    /// A custom path that is not an executable file is an error, never a
    /// fallback, so a typo cannot quietly start a different Neovim.
    nonisolated static func executablePath(
        useCustom: Bool, customPath: String, bundledPath: String?,
        isExecutableFile: (String) -> Bool = isExecutablePath
    ) throws(NeovimLaunchError) -> String {
        if useCustom {
            guard isExecutableFile(customPath) else {
                throw .invalidCustomPath(customPath)
            }
            return customPath
        }
        guard let bundledPath else { throw .bundledExecutableMissing }
        return bundledPath
    }

    /// The executable and argv to launch nvim with `arguments` (for example
    /// `["--embed"]`).
    ///
    /// `environment` is a control request's environment, or nil for a window
    /// the app opens on its own. Any request environment — even an empty one
    /// — spawns nvim directly: a login profile would change the exact
    /// environment the request forwarded.
    ///
    /// With nil, nvim is exec'd from the user's login shell, inheriting the
    /// app environment and sourcing the login profile. Native windows
    /// therefore get the user's configured `PATH`, exports, and tools
    /// regardless of how the app was launched. `TERM` plays no part in the
    /// choice: provenance belongs to the window-opening action.
    nonisolated static func launchCommand(
        nvimPath: String, arguments: [String],
        environment: [String: String]? = nil
    ) -> (path: String, argv: [String]) {
        if environment != nil {
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
