//
//  NvmmTests
//  NeovimBundleTests.swift
//
//  Covers startup arguments, directories, login-shell policy, and choosing
//  which nvim to run.
//

import XCTest
@testable import Nvmm

final class NeovimBundleTests: XCTestCase {

    func testWindowArguments() {
        let cases: [(String, [String], [String], Bool, [String])] = [
            ("forwarded order kept, files separated",
             ["-R", "+42", "-c", "set number", "+/needle"], ["one", "two"], false,
             ["--embed", "-p", "-R", "+42", "-c", "set number", "+/needle",
              "--", "one", "two"]),
            // A -c value is a value, never a layout option.
            ("command value is not a layout", ["-c", "-d"], ["one"], false,
             ["--embed", "-p", "-c", "-d", "--", "one"]),
            // Without the separator Neovim reads these names as a command and
            // an option: "+quit" fails with E492, "-R" with an unknown option.
            ("files named like options", [], ["+quit", "-R", "-"], true,
             ["--embed", "--", "+quit", "-R", "-"]),
            // A -c value beginning with + stays attached, while a preceding +
            // command remains first in Neovim's startup-command order.
            ("command value kept with its option",
             ["+set number", "-c", "+5", "-R"], ["one"], true,
             ["--embed", "+set number", "-c", "+5", "-R", "--", "one"]),
            ("no tab default for buffers", ["--clean"], ["new-file"], true,
             ["--embed", "--clean", "--", "new-file"]),
            ("no tab mode without files", [], [], false, ["--embed"]),
        ]
        for (label, options, files, inBuffers, expected) in cases {
            XCTAssertEqual(
                WindowController.neovimArguments(
                    options: options, files: files,
                    openFilesInBuffers: inBuffers),
                expected, label)
        }

        // A forwarded layout option owns the layout slot. Adding the
        // preference's -p alongside -d would open one file per tab, leaving
        // nothing to diff.
        for layout in ["-d", "-o", "-O", "-p"] {
            XCTAssertEqual(
                WindowController.neovimArguments(
                    options: [layout], files: ["one", "two"],
                    openFilesInBuffers: false),
                ["--embed", layout, "--", "one", "two"], layout)
        }
    }

    // Any CLI environment — non-nil — spawns nvim directly with exactly that
    // environment. A login shell would source the profile and change the
    // environment the request just forwarded. TERM plays no part: a valid
    // CLI environment can lack it (`env -i nvmm`). Without one, a native
    // window starts nvim through the login shell.
    func testLaunchCommand() {
        let environments: [[String: String]] = [
            ["TERM": "xterm-256color"],
            ["PATH": "/opt/project/bin:/usr/bin"],
            [:],
        ]
        for environment in environments {
            let command = NeovimBundle.launchCommand(
                nvimPath: "/opt/x/nvim", arguments: ["--embed"],
                environment: environment)
            XCTAssertEqual(command.path, "/opt/x/nvim")
            XCTAssertEqual(command.argv, ["/opt/x/nvim", "--embed"])
        }

        let command = NeovimBundle.launchCommand(
            nvimPath: "/opt/x/nvim", arguments: ["--embed"],
            environment: nil)
        XCTAssertEqual(command.argv.count, 3)
        XCTAssertTrue(command.argv.first?.hasPrefix("-") == true)
        XCTAssertEqual(command.argv.dropFirst().first, "-c")
        XCTAssertEqual(command.argv.last,
                       "exec '/opt/x/nvim' '--embed'")
    }

    func testStartupWorkingDirectory() {
        let cases: [(String?, [String], String)] = [
            ("/request", ["/files/one"], "/request"),
            (nil, ["/files/one", "/other/two"], "/files"),
            (nil, [], "/home"),
        ]
        for (directory, files, expected) in cases {
            XCTAssertEqual(
                WindowController.startupWorkingDirectory(
                    directory: directory, files: files,
                    homeDirectory: "/home"),
                expected)
        }
    }

    func testLoginShellCommand() {
        let command = NeovimBundle.loginShellCommand(
            shell: "/bin/zsh", nvimPath: "/Apps/Nvmm.app/Contents/MacOS/nvim",
            arguments: ["--embed"])

        XCTAssertEqual(command.path, "/bin/zsh")
        // argv[0] prefixed with '-' requests a login shell; -c runs the command;
        // exec replaces the shell so no wrapper lingers on the RPC pipes.
        XCTAssertEqual(command.argv, [
            "-zsh", "-c",
            "exec '/Apps/Nvmm.app/Contents/MacOS/nvim' '--embed'",
        ])

        XCTAssertEqual(NeovimBundle.loginShellCommand(
            shell: "/opt/homebrew/bin/fish", nvimPath: "/x/nvim",
            arguments: []).argv.first, "-fish")

        // Every path and argument is single-quoted so the shell treats spaces
        // and quotes literally.
        XCTAssertEqual(NeovimBundle.loginShellCommand(
            shell: "/bin/sh", nvimPath: "/Apps/My Editor/nvim",
            arguments: ["--embed", "a b", "it's"]).argv.last,
            "exec '/Apps/My Editor/nvim' '--embed' 'a b' 'it'\\''s'")
    }

    // A custom path is used only as given and only when it is executable; a
    // bad one is an error rather than a quiet fallback to the bundled nvim.
    func testExecutablePath() {
        let bundled = "/Apps/Nvmm.app/Contents/MacOS/nvim"
        let custom = "/opt/homebrew/bin/nvim"
        let cases: [(String, Bool, String, String?,
                     Result<String, NeovimLaunchError>)] = [
            ("bundled", false, custom, bundled, .success(bundled)),
            ("custom", true, custom, nil, .success(custom)),
            ("relative custom", true, "bin/nvim", bundled,
             .failure(.invalidCustomPath("bin/nvim"))),
            ("home-relative custom", true, "~/nvim", bundled,
             .failure(.invalidCustomPath("~/nvim"))),
            ("missing custom", true, "/missing/nvim", bundled,
             .failure(.invalidCustomPath("/missing/nvim"))),
            ("empty custom", true, "", bundled,
             .failure(.invalidCustomPath(""))),
            ("missing bundle", false, "", nil,
             .failure(.bundledExecutableMissing)),
        ]
        for (label, useCustom, path, bundledPath, expected) in cases {
            let result = Result { () throws(NeovimLaunchError) -> String in
                try NeovimBundle.executablePath(
                    useCustom: useCustom, customPath: path,
                    bundledPath: bundledPath,
                    isExecutableFile: { $0 == custom })
            }
            XCTAssertEqual(result, expected, label)
        }
    }

    func testIsExecutablePath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvmm-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("plain")
        try Data().write(to: file)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: "/bin/sh")

        XCTAssertTrue(NeovimBundle.isExecutablePath("/bin/sh"))
        XCTAssertTrue(NeovimBundle.isExecutablePath(link.path))
        XCTAssertFalse(NeovimBundle.isExecutablePath(file.path))
        XCTAssertFalse(NeovimBundle.isExecutablePath(directory.path))
        XCTAssertFalse(NeovimBundle.isExecutablePath("bin/sh"))
        XCTAssertFalse(NeovimBundle.isExecutablePath(""))
    }
}
