//
//  NvmmTests
//  UIControllerTests.swift
//
//  UIController coverage: mode classification and policy, redraw event handling
//  (grids, highlights, modes), progress tracking, and restart / connect handoffs.
//  Each case drives a bare controller with synthetic redraw arrays and asserts on
//  the flushed snapshot. One live case attaches a real bundled `nvim --embed` and
//  checks that typed text lands in the grid.
//

import XCTest
@testable import Nvmm

final class UIControllerTests: XCTestCase {

    // MARK: Event-building helpers

    /// A map value from string keys.
    private func map(_ pairs: (String, MPValue)...) -> MPValue {
        .map(pairs.map { (.string($0.0), $0.1) })
    }

    /// The RGB components of a color, for concise assertions. Qualified because
    /// XCTest transitively exposes Carbon's `RGBColor`.
    private func assertRGB(_ color: Nvmm.RGBColor, _ red: UInt8, _ green: UInt8,
                           _ blue: UInt8, line: UInt = #line) {
        XCTAssertEqual(color.red, red, line: line)
        XCTAssertEqual(color.green, green, line: line)
        XCTAssertEqual(color.blue, blue, line: line)
    }

    // MARK: Mode classification & policy

    func testClassifiesUiModeNamesAndShortNames() {
        let names: [(String, UIMode)] = [
            ("normal", .normal), ("insert", .insert), ("replace", .replace),
            ("vreplace", .virtualReplace), ("cmdline_normal", .commandLine),
            ("cmdline_insert", .commandLine), ("cmdline_replace", .commandLine),
            ("terminal", .terminal), ("visual", .visual),
            ("visual_select", .select), ("select", .select), ("prompt", .prompt),
        ]
        for (value, expected) in names {
            XCTAssertEqual(classifyUIModeName(value), expected)
        }
        XCTAssertNil(classifyUIModeName("confirm"))

        let shortnames: [(String, UIMode)] = [
            ("n", .normal), ("i", .insert), ("ic", .insert), ("ix", .insert),
            ("R", .replace), ("Rc", .replace), ("Rx", .replace),
            ("Rv", .virtualReplace), ("Rvc", .virtualReplace), ("Rvx", .virtualReplace),
            ("c", .commandLine), ("cv", .commandLine), ("ce", .commandLine),
            ("t", .terminal), ("v", .visual), ("s", .select), ("r", .prompt),
        ]
        for (value, expected) in shortnames {
            XCTAssertEqual(classifyUIModeShortname(value), expected)
        }
        XCTAssertNil(classifyUIModeShortname("m"))
    }

    func testDerivesUiModePolicyWithoutCursorPresentation() {
        XCTAssertTrue(acceptsTextInput(.insert))
        XCTAssertTrue(acceptsTextInput(.replace))
        XCTAssertTrue(acceptsTextInput(.virtualReplace))
        XCTAssertTrue(acceptsTextInput(.commandLine))
        XCTAssertTrue(acceptsTextInput(.terminal))
        XCTAssertFalse(acceptsTextInput(.normal))
        XCTAssertTrue(isVisualSelection(.visual))
        XCTAssertFalse(isVisualSelection(.select))
        XCTAssertTrue(displacesForComposition(.insert))
        XCTAssertFalse(displacesForComposition(.replace))
        XCTAssertEqual(textEntryMode(for: .virtualReplace), .replace)
        XCTAssertEqual(textEntryMode(for: .commandLine), .commandLine)
    }

    // MARK: Modes through redraw

    func testModeInfoFallsBackToShortNameForTextEntryEligibility() {
        let controller = UIController()
        let modeInfo: MPValue = ["mode_info_set",
            [true, [map(("short_name", "i")), map(("short_name", "r"))]]]
        let flush: MPValue = ["flush", []]

        _ = controller.redraw([modeInfo, ["mode_change", ["insert", 0]], flush])
        var grid = controller.globalGrid
        XCTAssertTrue(grid.acceptsTextInput)
        XCTAssertEqual(grid.semanticMode, .insert)
        XCTAssertTrue(grid.displacesForComposition)

        _ = controller.redraw([["mode_change", ["prompt", 1]], flush])
        grid = controller.globalGrid
        XCTAssertFalse(grid.acceptsTextInput)
        XCTAssertEqual(grid.semanticMode, .prompt)
        XCTAssertFalse(grid.displacesForComposition)
    }

    func testVisualModeFlagUsesDescriptiveUiModeName() {
        let controller = UIController()
        let modeInfo: MPValue = ["mode_info_set",
            [true, [map(("name", "visual")), map(("name", "visual_select"))]]]
        let flush: MPValue = ["flush", []]

        _ = controller.redraw([
            ["grid_resize", [1, 1, 1]], modeInfo,
            ["mode_change", ["visual", 0]], flush,
        ])
        XCTAssertTrue(controller.globalGrid.isVisualMode)

        _ = controller.redraw([["mode_change", ["visual_select", 1]], flush])
        XCTAssertFalse(controller.globalGrid.isVisualMode)
    }

    func testUiModeNamePrecedenceAndFlushPublication() {
        let controller = UIController()
        let modeInfo: MPValue = ["mode_info_set", [true, [
            map(("name", "normal"), ("short_name", "i")),
            map(("name", "insert"), ("short_name", "i")),
        ]]]
        let flush: MPValue = ["flush", []]

        _ = controller.redraw([modeInfo, ["mode_change", ["unknown", 0]], flush])
        XCTAssertEqual(controller.globalGrid.semanticMode, .normal)

        // A mode change without a flush is not yet published.
        _ = controller.redraw([["mode_change", ["insert", 1]]])
        XCTAssertEqual(controller.globalGrid.semanticMode, .normal)

        _ = controller.redraw([flush])
        XCTAssertEqual(controller.globalGrid.semanticMode, .insert)
    }

    // MARK: Options

    func testMouseMoveEventOptionIsTracked() {
        let controller = UIController()
        XCTAssertFalse(controller.mousemoveevent)

        _ = controller.redraw([["option_set", ["mousemoveevent", true]]])
        XCTAssertTrue(controller.mousemoveevent)

        // A non-boolean payload leaves the option unchanged.
        _ = controller.redraw([["option_set", ["mousemoveevent", 0]]])
        XCTAssertTrue(controller.mousemoveevent)

        _ = controller.redraw([["option_set", ["mousemoveevent", false]]])
        XCTAssertFalse(controller.mousemoveevent)
    }

    // MARK: Grids

    func testUnsupportedGridEventsAreIgnored() {
        let controller = UIController()
        let flush: MPValue = ["flush", []]

        let flushed = controller.redraw([
            ["grid_resize", [2, 10, 10]],
            ["grid_line", [2, 0, 0, []]],
            ["grid_clear", [2]],
            ["grid_cursor_goto", [2, 0, 0]],
            ["grid_scroll", [2, 0, 1, 0, 1, 1]],
            ["grid_resize", [1, 2, 1]],
            ["grid_cursor_goto", [1, 0, 1]],
            flush,
        ])

        XCTAssertEqual(flushed.count, 1)
        let grid = controller.globalGrid
        XCTAssertEqual(grid.width, 2)
        XCTAssertEqual(grid.height, 1)
        XCTAssertEqual(grid.cursor.column, 1)
    }

    func testGridLineWithoutInitialHighlightIsIgnored() {
        let controller = UIController()
        _ = controller.redraw([
            ["grid_resize", [1, 1, 1]],
            ["grid_line", [1, 0, 0, [["bad"]]]],  // first cell lacks a highlight id
            ["grid_line", [1, 0, 0, [["x", 0]]]],
            ["flush", []],
        ])
        XCTAssertEqual(controller.globalGrid.cell(0, 0).text, "x")
    }

    func testSparseHighlightIdUsesDefinedAttributes() {
        let controller = UIController()
        _ = controller.redraw([
            ["grid_resize", [1, 1, 1]],
            ["hl_attr_define", [5, map(("foreground", 0x11_2233),
                                       ("background", 0x44_5566))]],
            ["grid_line", [1, 0, 0, [["x", 5]]]],
            ["flush", []],
        ])
        let cell = controller.globalGrid.cell(0, 0)
        assertRGB(cell.foreground, 0x11, 0x22, 0x33)
        assertRGB(cell.background, 0x44, 0x55, 0x66)
        XCTAssertFalse(cell.hasSpecialColor)
    }

    func testConsecutiveSparseHighlightIdsDoNotShiftAttributes() {
        let controller = UIController()
        _ = controller.redraw([
            ["grid_resize", [1, 2, 1]],
            ["hl_attr_define", [5, map(("foreground", 0x10_2030),
                                       ("background", 0x40_5060))]],
            ["hl_attr_define", [6, map(("foreground", 0xa0_b0c0),
                                       ("background", 0xd0_e0f0))]],
            ["grid_line", [1, 0, 0, [["a", 5], ["b", 6]]]],
            ["flush", []],
        ])
        let grid = controller.globalGrid
        assertRGB(grid.cell(0, 0).foreground, 0x10, 0x20, 0x30)
        assertRGB(grid.cell(0, 0).background, 0x40, 0x50, 0x60)
        assertRGB(grid.cell(0, 1).foreground, 0xa0, 0xb0, 0xc0)
        assertRGB(grid.cell(0, 1).background, 0xd0, 0xe0, 0xf0)
    }

    func testGridLineCellsInheritPreviousHighlight() {
        let controller = UIController()
        _ = controller.redraw([
            ["grid_resize", [1, 3, 1]],
            ["hl_attr_define", [5, map(("foreground", 0x11_2233),
                                       ("background", 0x44_5566))]],
            ["grid_line", [1, 0, 0, [["a", 5], ["b"], ["c"]]]],
            ["flush", []],
        ])
        let grid = controller.globalGrid
        for col in 0..<3 {
            assertRGB(grid.cell(0, col).foreground, 0x11, 0x22, 0x33)
            assertRGB(grid.cell(0, col).background, 0x44, 0x55, 0x66)
        }
    }

    func testHighlightAttributesStoreBundledNeovimAttributes() {
        let controller = UIController()
        let attrs = map(
            ("foreground", 0x11_2233), ("background", 0x44_5566),
            ("special", 0x77_8899), ("underline", true), ("undercurl", true),
            ("underdouble", true), ("underdotted", true), ("underdashed", true),
            ("strikethrough", true), ("overline", true), ("dim", true),
            ("blend", 35), ("nocombine", true))
        _ = controller.redraw([
            ["grid_resize", [1, 1, 1]],
            ["hl_attr_define", [5, attrs]],
            ["grid_line", [1, 0, 0, [["x", 5]]]],
            ["flush", []],
        ])

        let cell = controller.globalGrid.cell(0, 0)
        assertRGB(cell.foreground, 0x11, 0x22, 0x33)
        assertRGB(cell.background, 0x44, 0x55, 0x66)
        assertRGB(cell.special, 0x77, 0x88, 0x99)
        XCTAssertTrue(cell.hasSpecialColor)
        XCTAssertTrue(cell.hasUnderline)
        XCTAssertTrue(cell.hasUndercurl)
        XCTAssertTrue(cell.hasUnderdouble)
        XCTAssertTrue(cell.hasUnderdotted)
        XCTAssertTrue(cell.hasUnderdashed)
        XCTAssertTrue(cell.hasStrikethrough)
        XCTAssertTrue(cell.hasOverline)
        XCTAssertTrue(cell.isDim)
        XCTAssertEqual(cell.blend, 35)
        XCTAssertTrue(cell.hasNocombine)
    }

    func testHighlightGroupMappingsDowngradeWhenGroupsMove() {
        let controller = UIController()
        let flush: MPValue = ["flush", []]

        _ = controller.redraw([
            ["grid_resize", [1, 2, 1]],
            ["hl_group_set", ["StatusLine", 5]],
            ["hl_group_set", ["TabLine", 5]],
            ["grid_line", [1, 0, 0, [["a", 5], ["b", 5]]]],
            flush,
        ])
        var grid = controller.globalGrid
        let shared = grid.pointerStyle(0, 0)
        XCTAssertTrue(shared.contains(.statusLine))
        XCTAssertTrue(shared.contains(.tabline))

        _ = controller.redraw([
            ["hl_group_set", ["TabLine", 6]],
            ["grid_line", [1, 0, 0, [["a", 5], ["b", 6]]]],
            flush,
        ])
        grid = controller.globalGrid
        XCTAssertEqual(grid.pointerStyle(0, 0), .statusLine)
        XCTAssertEqual(grid.pointerStyle(0, 1), .tabline)

        _ = controller.redraw([
            ["hl_group_set", ["StatusLine", 7]],
            ["hl_group_set", ["Normal", 7]],   // not a tracked group
            ["grid_line", [1, 0, 0, [["c", 5], ["d", 7]]]],
            flush,
        ])
        grid = controller.globalGrid
        XCTAssertEqual(grid.pointerStyle(0, 0), .normal)
        XCTAssertEqual(grid.pointerStyle(0, 1), .statusLine)
    }

    // MARK: Progress

    func testProgressTracksMostRecentKnownPercentage() {
        let controller = UIController()

        controller.progress([(.string("id"), 1), (.string("status"), "running"),
                             (.string("percent"), 25)])
        XCTAssertEqual(controller.progressPercent, 25)

        controller.progress([(.string("id"), "plugin.task"),
                             (.string("status"), "running"), (.string("percent"), 60)])
        XCTAssertEqual(controller.progressPercent, 60)

        controller.progress([(.string("id"), "plugin.task"),
                             (.string("status"), "success")])
        XCTAssertEqual(controller.progressPercent, 25)
    }

    func testProgressHidesUnknownAndClampsPercentages() {
        let controller = UIController()

        controller.progress([(.string("id"), 1), (.string("status"), "running")])
        XCTAssertNil(controller.progressPercent)

        controller.progress([(.string("id"), 1), (.string("status"), "running"),
                             (.string("percent"), 150)])
        XCTAssertNil(controller.progressPercent)

        controller.progress([(.string("id"), 1), (.string("status"), "running"),
                             (.string("percent"), -20)])
        XCTAssertEqual(controller.progressPercent, 0)
    }

    func testProgressIgnoresMalformedEventsAndRemovesTerminalStatuses() {
        let controller = UIController()

        controller.progress([(.string("status"), "running")])
        XCTAssertNil(controller.progressPercent)

        for terminal in ["failed", "cancel"] {
            controller.progress([(.string("id"), 1), (.string("status"), "running"),
                                 (.string("percent"), 50)])
            controller.progress([(.string("id"), 1), (.string("status"), .string(terminal))])
            XCTAssertNil(controller.progressPercent)
        }
    }

    /// The outcome tells the window what to do: hold a finished task's value,
    /// fall back to what is still running, or do nothing at all.
    func testProgressOutcomes() {
        let controller = UIController()

        // A running task changes what is shown.
        XCTAssertEqual(
            controller.progress([(.string("id"), 1), (.string("status"), "running"),
                                 (.string("percent"), 40)]), .changed)

        // A task that ends with a percentage is held; one that ends without a
        // percentage has nothing to hold, so the bar just falls back.
        XCTAssertEqual(
            controller.progress([(.string("id"), 1), (.string("status"), "success"),
                                 (.string("percent"), 100)]), .completed(100))
        XCTAssertEqual(
            controller.progress([(.string("id"), 2), (.string("status"), "success")]),
            .changed)

        // 100% while still "running" is a finished task in all but name.
        XCTAssertEqual(
            controller.progress([(.string("id"), 3), (.string("status"), "running"),
                                 (.string("percent"), 100)]), .completed(100))
        XCTAssertNil(controller.progressPercent)

        // Nothing to act on: no id, no status, or a status we do not track.
        XCTAssertEqual(controller.progress([(.string("status"), "running")]), .ignored)
        XCTAssertEqual(controller.progress([(.string("id"), 1)]), .ignored)
        XCTAssertEqual(
            controller.progress([(.string("id"), 1), (.string("status"), "queued")]),
            .ignored)
    }

    /// Numeric and string ids are separate namespaces, so task 1 and task "1"
    /// do not overwrite each other.
    func testProgressIdNamespacesAreSeparate() {
        let controller = UIController()

        controller.progress([(.string("id"), 1), (.string("status"), "running"),
                             (.string("percent"), 10)])
        controller.progress([(.string("id"), "1"), (.string("status"), "running"),
                             (.string("percent"), 70)])
        XCTAssertEqual(controller.progressPercent, 70)

        controller.progress([(.string("id"), "1"), (.string("status"), "success")])
        XCTAssertEqual(controller.progressPercent, 10)
    }

    // MARK: Modified

    func testSetModifiedReportsOnlyTransitions() {
        let controller = UIController()
        XCTAssertFalse(controller.modified)

        XCTAssertTrue(controller.setModified(true))
        XCTAssertTrue(controller.modified)
        XCTAssertFalse(controller.setModified(true))

        XCTAssertTrue(controller.setModified(false))
        XCTAssertFalse(controller.modified)
        XCTAssertFalse(controller.setModified(false))
    }

    // MARK: Startup

    func testFlushMarksStartupCompleteOnlyAfterVimenter() {
        let controller = UIController()
        let flush: MPValue = ["flush", []]

        let before = controller.redraw([flush])
        XCTAssertEqual(before.count, 1)
        XCTAssertFalse(before[0].startupComplete)

        controller.vimenter()
        let after = controller.redraw([flush])
        XCTAssertEqual(after.count, 1)
        XCTAssertTrue(after[0].startupComplete)
    }

    // MARK: Handoff

    func testRestartEventRecordsServerHandoff() {
        let controller = UIController()
        _ = controller.redraw([["restart", "/tmp/nvim-restart.sock"]])
        let handoff = controller.handoff
        XCTAssertEqual(handoff?.kind, .restart)
        XCTAssertEqual(handoff?.address, "/tmp/nvim-restart.sock")
    }

    func testConnectEventRecordsServerHandoff() {
        let controller = UIController()
        _ = controller.redraw([["connect", "/tmp/nvim-connect.sock"]])
        let handoff = controller.handoff
        XCTAssertEqual(handoff?.kind, .connect)
        XCTAssertEqual(handoff?.address, "/tmp/nvim-connect.sock")
    }

    func testRealRestartEmitsHandoffFromNeovim() async throws {
        guard let nvim = await MainActor.run(body: { NeovimBundle.executableURL }) else {
            throw XCTSkip("bundled nvim executable not available")
        }
        let process = NeovimProcess()
        try await process.spawn(path: nvim.path,
                                argv: [nvim.path, "--clean", "--embed"])
        var options = UIOptions()
        options.extLinegrid = true
        let result = await process.uiAttach(width: 80, height: 24, options: options)
        guard result.status == .success else {
            await process.disconnect()
            return XCTFail("attach failed: \(result.status) \(result.message)")
        }

        // `:restart` starts a new server, sends the UI a "restart" handoff
        // naming its address, then the old server exits. The reconnection
        // consumer lives in WindowController; here we confirm Neovim emits the
        // handoff and we capture it through the real transport. The old server
        // may exit before replying, so the request result is ignored.
        _ = try? await process.request("nvim_command", [.string("restart")])

        var handoff: UIHandoff?
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let captured = await process.pendingHandoff() {
                handoff = captured
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        await process.disconnect()

        XCTAssertEqual(handoff?.kind, .restart)
        XCTAssertFalse(handoff?.address.isEmpty ?? true)

        // Nothing reconnected to the successor, so quit it rather than leak it.
        if let address = handoff?.address, !address.isEmpty {
            let successor = NeovimProcess()
            try? await successor.connect(address)
            _ = try? await successor.request("nvim_command", [.string("qall!")])
            await successor.disconnect()
        }
    }

    func testMissingRestartSocketIsAnAbandonedHandoff() {
        XCTAssertTrue(handoffConnectionErrorIsStale(.restart, ENOENT))
        XCTAssertFalse(handoffConnectionErrorIsStale(.connect, ENOENT))
        XCTAssertFalse(handoffConnectionErrorIsStale(.restart, ECONNREFUSED))
    }

    // MARK: Live attach

    /// Concatenates `count` cells of a row into a string.
    private func rowText(_ grid: Grid, row: Int, count: Int) -> String {
        (0..<count).map { grid.cell(row, $0).text }.joined()
    }

    /// Awaits the first published grid matching `predicate`, or nil on timeout.
    private func awaitGrid(_ process: NeovimProcess, timeout: Duration,
                           where predicate: @escaping @Sendable (Grid) -> Bool) async -> Grid? {
        await withTaskGroup(of: Grid?.self) { group in
            group.addTask {
                for await grid in process.grids where predicate(grid) { return grid }
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

    /// Awaits the first `modifiedStates` value matching `predicate`, or nil on
    /// timeout.
    private func awaitModified(_ process: NeovimProcess, timeout: Duration,
                              where predicate: @escaping @Sendable (Bool) -> Bool) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                for await value in process.modifiedStates where predicate(value) {
                    return value
                }
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

    func testModifiedStatePublishedWhenBufferChanges() async throws {
        guard let nvim = await MainActor.run(body: { NeovimBundle.executableURL }) else {
            throw XCTSkip("bundled nvim executable not available")
        }
        let process = NeovimProcess()
        try await process.spawn(path: nvim.path, argv: [nvim.path, "--clean", "--embed"])

        var options = UIOptions()
        options.extLinegrid = true
        let result = await process.uiAttach(width: 80, height: 24, options: options)
        guard result.status == .success else {
            await process.disconnect()
            return XCTFail("attach failed: \(result.status) \(result.message)")
        }

        _ = try await process.request("nvim_input", [.string("ihello")])
        let modified = await awaitModified(process, timeout: .seconds(5)) { $0 }
        await process.disconnect()

        XCTAssertEqual(modified, true)
    }

    func testAttachAndTypedTextLandsInGrid() async throws {
        guard let nvim = await MainActor.run(body: { NeovimBundle.executableURL }) else {
            throw XCTSkip("bundled nvim executable not available")
        }
        let process = NeovimProcess()
        try await process.spawn(path: nvim.path, argv: [nvim.path, "--clean", "--embed"])

        var options = UIOptions()
        options.extLinegrid = true
        let result = await process.uiAttach(width: 80, height: 24, options: options)
        guard result.status == .success else {
            await process.disconnect()
            return XCTFail("attach failed: \(result.status) \(result.message)")
        }

        _ = try await process.request("nvim_input", [.string("ihello")])
        let grid = await awaitGrid(process, timeout: .seconds(5)) { grid in
            grid.width >= 5 && (0..<5).allSatisfy { !grid.cell(0, $0).text.isEmpty }
                && grid.cell(0, 0).text == "h"
        }
        await process.disconnect()

        guard let grid else { return XCTFail("no grid with typed text arrived") }
        XCTAssertEqual(rowText(grid, row: 0, count: 5), "hello")
    }

    func testConnectToRunningNvimAttachesAndTypedTextLandsInGrid() async throws {
        guard let nvim = await MainActor.run(body: { NeovimBundle.executableURL }) else {
            throw XCTSkip("bundled nvim executable not available")
        }

        // A headless server completes startup — firing VimEnter — without a UI,
        // so a UI connecting afterward has missed VimEnter. This exercises the
        // connect path that latches `startupComplete` from `v:vim_did_enter`.
        let socket = NSTemporaryDirectory() + "nvmm-connect-\(UUID().uuidString).sock"
        let server = Process()
        server.executableURL = URL(fileURLWithPath: nvim.path)
        server.arguments = ["--headless", "--clean", "-n", "-i", "NONE",
                            "--listen", socket]
        try server.run()
        defer {
            server.terminate()
            try? FileManager.default.removeItem(atPath: socket)
        }

        // The server creates the socket asynchronously; wait for it to appear.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: socket) {
            if ContinuousClock.now >= deadline {
                throw XCTSkip("nvim server socket did not appear")
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let process = NeovimProcess()
        try await process.connect(socket)

        var options = UIOptions()
        options.extLinegrid = true
        let result = await process.uiAttach(width: 80, height: 24, options: options)
        guard result.status == .success else {
            await process.disconnect()
            return XCTFail("attach failed: \(result.status) \(result.message)")
        }

        _ = try await process.request("nvim_input", [.string("ihello")])
        let grid = await awaitGrid(process, timeout: .seconds(5)) { grid in
            grid.startupComplete && grid.width >= 5 && grid.cell(0, 0).text == "h"
        }
        await process.disconnect()

        guard let grid else {
            return XCTFail("no startup-complete grid with typed text arrived")
        }
        XCTAssertEqual(rowText(grid, row: 0, count: 5), "hello")

        // Detaching this UI must leave the server running.
        XCTAssertTrue(server.isRunning, "server should survive UI disconnect")
    }
}
