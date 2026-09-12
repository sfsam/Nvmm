//
//  NvmmTests
//  NeovimBundleTests.swift
//
//  Covers startup arguments, directories, and login-shell policy for the
//  embedded nvim process.
//

import XCTest
@testable import Nvmm

final class NeovimBundleTests: XCTestCase {

    func testWindowArgumentsPreserveForwardedOrderAndSeparateFiles() {
        let arguments = WindowController.neovimArguments(
            options: ["-R", "+42", "-c", "set number", "+/needle"],
            files: ["one", "two"], openFilesInBuffers: false)

        XCTAssertEqual(arguments, [
            "--embed", "-p", "-R", "+42", "-c", "set number",
            "+/needle", "--", "one", "two",
        ])
    }

    // A forwarded layout option owns the layout slot. Adding the preference's
    // -p alongside -d would open one file per tab, leaving nothing to diff.
    func testWindowArgumentsLeaveForwardedLayoutAlone() {
        for layout in ["-d", "-o", "-O", "-p"] {
            let arguments = WindowController.neovimArguments(
                options: [layout], files: ["one", "two"],
                openFilesInBuffers: false)

            XCTAssertEqual(arguments, ["--embed", layout, "--", "one", "two"])
        }
    }

    func testWindowArgumentsTreatCommandValueAsValueNotLayout() {
        let arguments = WindowController.neovimArguments(
            options: ["-c", "-d"], files: ["one"], openFilesInBuffers: false)

        XCTAssertEqual(arguments, ["--embed", "-p", "-c", "-d", "--", "one"])
    }

    // Without the separator Neovim reads these names as a command and an
    // option: "+quit" fails with E492, "-R" with an unknown-option error.
    func testWindowArgumentsSeparateFilesNamedLikeOptions() {
        let arguments = WindowController.neovimArguments(
            options: [], files: ["+quit", "-R", "-"],
            openFilesInBuffers: true)

        XCTAssertEqual(arguments, ["--embed", "--", "+quit", "-R", "-"])
    }

    // A -c value beginning with + stays attached, while a preceding + command
    // remains first in Neovim's startup-command execution order.
    func testWindowArgumentsKeepCommandValueWithItsOption() {
        let arguments = WindowController.neovimArguments(
            options: ["+set number", "-c", "+5", "-R"], files: ["one"],
            openFilesInBuffers: true)

        XCTAssertEqual(arguments,
                       ["--embed", "+set number", "-c", "+5", "-R",
                        "--", "one"])
    }

    func testWindowArgumentsOmitTabDefaultForBufferPreference() {
        let arguments = WindowController.neovimArguments(
            options: ["--clean"], files: ["new-file"],
            openFilesInBuffers: true)

        XCTAssertEqual(arguments, ["--embed", "--clean", "--", "new-file"])
    }

    func testWindowArgumentsDoNotAddTabModeWithoutFiles() {
        let arguments = WindowController.neovimArguments(
            options: [], files: [], openFilesInBuffers: false)

        XCTAssertEqual(arguments, ["--embed"])
    }

    // Any CLI environment — non-nil — spawns nvim directly with exactly that
    // environment. A login shell would source the profile and change the
    // environment the request just forwarded. TERM plays no part: a valid
    // CLI environment can lack it (`env -i nvmm -N`).
    func testLaunchCommandWithCLIEnvironmentSpawnsNvimDirectly() {
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
    }

    func testLaunchCommandWithoutCLIEnvironmentUsesLoginShell() {
        let command = NeovimBundle.launchCommand(
            nvimPath: "/opt/x/nvim", arguments: ["--embed"],
            environment: nil)

        XCTAssertEqual(command.argv.count, 3)
        XCTAssertTrue(command.argv.first?.hasPrefix("-") == true)
        XCTAssertEqual(command.argv.dropFirst().first, "-c")
        XCTAssertEqual(command.argv.last,
                       "exec '/opt/x/nvim' '--embed'")
    }

    func testStartupWorkingDirectoryPrefersExplicitDirectory() {
        let directory = WindowController.startupWorkingDirectory(
            directory: "/request", files: ["/files/one"],
            homeDirectory: "/home")

        XCTAssertEqual(directory, "/request")
    }

    func testStartupWorkingDirectoryUsesFirstFileDirectory() {
        let directory = WindowController.startupWorkingDirectory(
            directory: nil, files: ["/files/one", "/other/two"],
            homeDirectory: "/home")

        XCTAssertEqual(directory, "/files")
    }

    func testStartupWorkingDirectoryFallsBackToHome() {
        let directory = WindowController.startupWorkingDirectory(
            directory: nil, files: [], homeDirectory: "/home")

        XCTAssertEqual(directory, "/home")
    }

    func testLoginShellCommandExecsNvimAsLoginShell() {
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
    }

    func testLoginShellCommandUsesShellBasenameForArgv0() {
        let command = NeovimBundle.loginShellCommand(
            shell: "/opt/homebrew/bin/fish", nvimPath: "/x/nvim", arguments: [])
        XCTAssertEqual(command.argv.first, "-fish")
    }

    func testLoginShellCommandQuotesPathsAndArguments() {
        let command = NeovimBundle.loginShellCommand(
            shell: "/bin/sh", nvimPath: "/Apps/My Editor/nvim",
            arguments: ["--embed", "a b", "it's"])

        // Every path and argument is single-quoted so the shell treats spaces and
        // quotes literally.
        XCTAssertEqual(command.argv.last,
            "exec '/Apps/My Editor/nvim' '--embed' 'a b' 'it'\\''s'")
    }
}
