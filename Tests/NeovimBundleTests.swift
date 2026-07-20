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
