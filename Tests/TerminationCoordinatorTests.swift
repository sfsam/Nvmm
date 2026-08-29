//
//  NvmmTests
//  TerminationCoordinatorTests.swift
//
//  Coverage for the app-shutdown drain: detecting unsaved buffers across
//  windows, quitting all sessions, reporting success only when they all exit,
//  the non-forced quit blocked by unsaved buffers, the forced quit, and the
//  empty registry. Uses a fake `QuitSession` so no Neovim or window is
//  involved.
//

import XCTest
@testable import Nvmm

@MainActor
final class TerminationCoordinatorTests: XCTestCase {

    /// A stand-in window: reports its unsaved state, records the quit request,
    /// and exits when told to, so a test can drive the coordinator's poll
    /// deterministically.
    private final class FakeSession: QuitSession {
        var hasExited = false
        var quitCount = 0
        var lastForce = false
        let unsaved: Bool
        /// Whether the session's Neovim is blocked awaiting input.
        let awaitingInput: Bool
        /// Whether a forced quit makes it exit.
        let exitsOnForce: Bool
        /// Whether an orderly quit request receives any response.
        let respondsToQuit: Bool
        var forceTerminateCount = 0
        var unsavedQueryCount = 0
        var awaitingQueryCount = 0
        var reportCount = 0

        /// A clean session (`unsaved: false`) exits on any quit; an unsaved one
        /// exits only when forced (unless `exitsOnForce` is overridden).
        init(unsaved: Bool, exitsOnForce: Bool = true,
             respondsToQuit: Bool = true, awaitingInput: Bool = false) {
            self.unsaved = unsaved
            self.exitsOnForce = exitsOnForce
            self.respondsToQuit = respondsToQuit
            self.awaitingInput = awaitingInput
        }

        func hasUnsavedBuffers() async -> Bool {
            unsavedQueryCount += 1
            return unsaved
        }

        func isAwaitingInput() async -> Bool {
            awaitingQueryCount += 1
            return awaitingInput
        }

        func presentAwaitingInputReport() async {
            reportCount += 1
        }

        func beginQuit(force: Bool) {
            quitCount += 1
            lastForce = force
            if respondsToQuit && (force ? exitsOnForce : !unsaved) {
                hasExited = true
            }
        }

        func forceTerminate() async {
            forceTerminateCount += 1
            hasExited = true
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
        let a = FakeSession(unsaved: false)
        let b = FakeSession(unsaved: false)
        coordinator.register(a)
        coordinator.register(b)

        let exited = await coordinator.requestQuitAll(force: false)
        XCTAssertTrue(exited)
        XCTAssertEqual(a.quitCount, 1)
        XCTAssertEqual(b.quitCount, 1)
        XCTAssertFalse(a.lastForce)
    }

    func testAnyUnsavedBuffersReflectsSessions() async {
        let coordinator = TerminationCoordinator()
        var unsaved = await coordinator.anyUnsavedBuffers()
        XCTAssertFalse(unsaved)

        let clean = FakeSession(unsaved: false)
        let dirty = FakeSession(unsaved: true)
        coordinator.register(clean)
        unsaved = await coordinator.anyUnsavedBuffers()
        XCTAssertFalse(unsaved)
        coordinator.register(dirty)
        unsaved = await coordinator.anyUnsavedBuffers()
        XCTAssertTrue(unsaved)
    }

    func testAnyUnsavedBuffersSkipsExitedSessions() async {
        let coordinator = TerminationCoordinator()
        let exited = FakeSession(unsaved: true)
        exited.hasExited = true
        let live = FakeSession(unsaved: false)
        coordinator.register(exited)
        coordinator.register(live)

        let unsaved = await coordinator.anyUnsavedBuffers()

        XCTAssertFalse(unsaved)
        XCTAssertEqual(exited.unsavedQueryCount, 0)
        XCTAssertEqual(live.unsavedQueryCount, 1)
    }

    func testNonForcedQuitDoesNotExitUnsavedSession() async {
        let coordinator = TerminationCoordinator()
        let clean = FakeSession(unsaved: false)
        let dirty = FakeSession(unsaved: true)
        coordinator.register(clean)
        coordinator.register(dirty)

        // Without force, an unsaved window does not exit, so the drain waits
        // out the (short, for the test) timeout and reports failure. The caller
        // is expected to check `anyUnsavedBuffers` and force first.
        let exited = await coordinator.requestQuitAll(force: false,
                                                      timeout: .milliseconds(100))
        XCTAssertFalse(exited)
        XCTAssertTrue(clean.hasExited)
        XCTAssertFalse(dirty.hasExited)
    }

    func testForcedQuitExitsUnsavedSession() async {
        let coordinator = TerminationCoordinator()
        let dirty = FakeSession(unsaved: true, exitsOnForce: true)
        coordinator.register(dirty)

        let exited = await coordinator.requestQuitAll(force: true)
        XCTAssertTrue(exited)
        XCTAssertTrue(dirty.lastForce)
    }

    func testTimedOutApplicationQuitCanBeCancelled() async {
        let coordinator = TerminationCoordinator()
        let hung = FakeSession(unsaved: false, respondsToQuit: false)
        coordinator.register(hung)
        var forceConfirmationCount = 0

        let exited = await coordinator.requestApplicationQuit(
            timeout: .milliseconds(25),
            confirmDiscard: {
                XCTFail("clean session must not ask to discard")
                return false
            },
            confirmForceTermination: {
                forceConfirmationCount += 1
                return false
            })

        XCTAssertFalse(exited)
        XCTAssertEqual(forceConfirmationCount, 1)
        XCTAssertEqual(hung.forceTerminateCount, 0)
        XCTAssertFalse(hung.hasExited)
    }

    func testTimedOutApplicationQuitCanForceTermination() async {
        let coordinator = TerminationCoordinator()
        let exitedNormally = FakeSession(unsaved: false)
        let hung = FakeSession(unsaved: false, respondsToQuit: false)
        coordinator.register(exitedNormally)
        coordinator.register(hung)

        let exited = await coordinator.requestApplicationQuit(
            timeout: .milliseconds(25),
            confirmDiscard: {
                XCTFail("clean session must not ask to discard")
                return false
            },
            confirmForceTermination: { true })

        XCTAssertTrue(exited)
        XCTAssertEqual(exitedNormally.forceTerminateCount, 0)
        XCTAssertEqual(hung.forceTerminateCount, 1)
        XCTAssertTrue(hung.hasExited)
    }

    func testAwaitingInputSessionDefersQuit() async {
        let coordinator = TerminationCoordinator()
        let blocked = FakeSession(unsaved: false, awaitingInput: true)
        coordinator.register(blocked)
        // A blocked session answers no requests, so the unsaved check would
        // time out into a false "unsaved". The quit is deferred instead: the
        // session is told to report the block, and no prompt or quit follows.
        let exited = await coordinator.requestApplicationQuit(
            timeout: .milliseconds(25),
            confirmDiscard: {
                XCTFail("blocked session must not ask to discard")
                return false
            },
            confirmForceTermination: {
                XCTFail("blocked session must not be force-terminated")
                return false
            })

        XCTAssertFalse(exited)
        XCTAssertEqual(blocked.reportCount, 1)
        XCTAssertEqual(blocked.awaitingQueryCount, 1)
        XCTAssertEqual(blocked.unsavedQueryCount, 0)
        XCTAssertEqual(blocked.quitCount, 0)
        XCTAssertFalse(blocked.hasExited)
    }

    func testDeregisterRemovesSession() async {
        let coordinator = TerminationCoordinator()
        let a = FakeSession(unsaved: false)
        coordinator.register(a)
        XCTAssertFalse(coordinator.isEmpty)
        coordinator.deregister(a)
        XCTAssertTrue(coordinator.isEmpty)
    }
}
