//
//  NvmmTests
//  TerminationCoordinatorTests.swift
//
//  Coverage for the app-shutdown drain: quitting all sessions, reporting
//  success only when they all exit, the unsaved-refusal (non-forced) case, the
//  forced upgrade, and the empty registry. Uses a fake `QuitSession` so no
//  Neovim or window is involved.
//

import XCTest
@testable import Nvmm

@MainActor
final class TerminationCoordinatorTests: XCTestCase {

    /// A stand-in window: records the quit request and exits when told to, so a
    /// test can drive the coordinator's poll deterministically.
    private final class FakeSession: QuitSession {
        var hasExited = false
        var quitRefused = false
        var quitCount = 0
        var lastForce = false
        /// When set, `beginQuit` exits immediately (a clean buffer that quits);
        /// when false, it refuses unless forced (an unsaved buffer).
        var exitsOnQuit: Bool
        var exitsOnForce: Bool

        init(exitsOnQuit: Bool, exitsOnForce: Bool = true) {
            self.exitsOnQuit = exitsOnQuit
            self.exitsOnForce = exitsOnForce
        }

        func beginQuit(force: Bool) {
            quitCount += 1
            lastForce = force
            quitRefused = false
            if force ? exitsOnForce : exitsOnQuit {
                hasExited = true
            } else if !force {
                quitRefused = true
            }
        }
    }

    func testEmptyRegistryReportsExited() async {
        let coordinator = TerminationCoordinator()
        XCTAssertTrue(coordinator.isEmpty)
        let exited = await coordinator.requestQuitAll(force: false)
        XCTAssertTrue(exited)
    }

    func testAllCleanSessionsExit() async {
        let coordinator = TerminationCoordinator()
        let a = FakeSession(exitsOnQuit: true)
        let b = FakeSession(exitsOnQuit: true)
        coordinator.register(a)
        coordinator.register(b)

        let exited = await coordinator.requestQuitAll(force: false)
        XCTAssertTrue(exited)
        XCTAssertEqual(a.quitCount, 1)
        XCTAssertEqual(b.quitCount, 1)
        XCTAssertFalse(a.lastForce)
    }

    func testUnsavedSessionRefusesNonForcedQuit() async {
        let coordinator = TerminationCoordinator()
        let clean = FakeSession(exitsOnQuit: true)
        let dirty = FakeSession(exitsOnQuit: false)
        coordinator.register(clean)
        coordinator.register(dirty)

        // A refusal settles immediately, so the drain returns well before the
        // (generous) timeout rather than stalling on it.
        let start = ContinuousClock.now
        let exited = await coordinator.requestQuitAll(force: false,
                                                      timeout: .seconds(10))
        let elapsed = ContinuousClock.now - start

        XCTAssertFalse(exited)
        XCTAssertTrue(clean.hasExited)
        XCTAssertFalse(dirty.hasExited)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testForcedQuitExitsUnsavedSession() async {
        let coordinator = TerminationCoordinator()
        let dirty = FakeSession(exitsOnQuit: false, exitsOnForce: true)
        coordinator.register(dirty)

        let exited = await coordinator.requestQuitAll(force: true)
        XCTAssertTrue(exited)
        XCTAssertTrue(dirty.lastForce)
    }

    func testDeregisterRemovesSession() async {
        let coordinator = TerminationCoordinator()
        let a = FakeSession(exitsOnQuit: true)
        coordinator.register(a)
        XCTAssertFalse(coordinator.isEmpty)
        coordinator.deregister(a)
        XCTAssertTrue(coordinator.isEmpty)
    }
}
