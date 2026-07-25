//
//  NvmmTests
//  NeovimBundleTests.swift
//
//  Covers the pure login-shell command construction used to launch the embedded
//  nvim with the user's login environment when the app starts outside a terminal.
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
