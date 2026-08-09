//
//  NvmmTests
//  CompositionTests.swift
//
//  Composition coverage: grapheme display widths against Neovim's width
//  policies, single-row preedit layout (Insert-mode displacement, stale-geometry
//  overwrite fallback, right-to-left clipping), committed-text transport
//  selection, the Cocoa handle-event transaction resolution, the composition
//  kind predicates, the geometry parser, and the marked-text coordinator's
//  lifecycle driven with an injected kind resolver. All value logic with no
//  Metal, so it is exempt from the RenderTests teardown crash.
//

import AppKit
import XCTest
@testable import Nvmm

final class CompositionTests: XCTestCase {

    // MARK: Grapheme width

    func testCompositionWidthMatchesNeovimPolicies() {
        var policy = CompositionWidthPolicy()

        XCTAssertEqual(compositionGraphemeWidth("a", policy), 1)
        XCTAssertEqual(compositionGraphemeWidth("日", policy), 2)
        XCTAssertEqual(compositionGraphemeWidth("·", policy), 1)

        policy.ambiguousIsDouble = true
        XCTAssertEqual(compositionGraphemeWidth("·", policy), 2)

        XCTAssertEqual(compositionGraphemeWidth("✈", policy), 1)
        XCTAssertEqual(compositionGraphemeWidth("✈️", policy), 2)
        XCTAssertEqual(compositionGraphemeWidth("🙂", policy), 2)
        // A base letter plus a combining accent is one narrow grapheme; only the
        // first scalar (the ASCII base) decides its width.
        XCTAssertEqual(compositionGraphemeWidth("e\u{0301}", policy), 1)
        XCTAssertEqual(compositionGraphemeWidth("👨‍👩‍👧", policy), 2)

        policy.overrides = [CellwidthOverride(first: 0x61, last: 0x61, width: 2)]
        XCTAssertEqual(compositionGraphemeWidth("a", policy), 2)

        XCTAssertEqual(compositionGraphemeWidth("", policy), 1)
    }

    // MARK: Layout

    func testLayoutDisplacesInsertModeCellsWithinTextArea() {
        var input = CompositionLayoutInput()
        input.gridWidth = 20
        input.gridHeight = 4
        input.anchorRow = 1
        input.anchorColumn = 8
        input.textLeft = 5
        input.textWidth = 10
        input.geometryValid = true
        input.insertMode = true
        input.selectionLocation = 1
        input.graphemes = [CompositionGrapheme(width: 2, utf16Location: 0,
                                               utf16Length: 1)]
        input.sourceCells = [
            CompositionSourceCell(column: 8, width: 1),
            CompositionSourceCell(column: 9, width: 1),
            CompositionSourceCell(column: 10, width: 2),
            CompositionSourceCell(column: 12, width: 1),
        ]

        let output = layoutComposition(input)
        XCTAssertTrue(output.valid)
        XCTAssertTrue(output.displaced)
        XCTAssertEqual(output.row, 1)
        XCTAssertEqual(output.placements[0].column, 8)
        XCTAssertEqual(output.placements[1].column, 10)
        XCTAssertEqual(output.clearEnd, 15)
    }

    func testLayoutOverwritesWhenGeometryIsStale() {
        var input = CompositionLayoutInput()
        input.gridWidth = 12
        input.gridHeight = 3
        input.anchorRow = 1
        input.anchorColumn = 7
        input.textLeft = 3
        input.textWidth = 6
        input.geometryValid = false
        input.insertMode = true
        input.selectionLocation = 1
        input.graphemes = [CompositionGrapheme(width: 1, utf16Location: 0,
                                               utf16Length: 1)]
        input.sourceCells = [CompositionSourceCell(column: 7, width: 1)]

        let output = layoutComposition(input)
        XCTAssertFalse(output.displaced)
        XCTAssertEqual(output.placements.count, 1)
        XCTAssertEqual(output.placements[0].column, 7)
    }

    func testLayoutMirrorsRightToLeftAndClipsWholeGraphemes() {
        var input = CompositionLayoutInput()
        input.gridWidth = 12
        input.gridHeight = 3
        input.anchorRow = 1
        input.anchorColumn = 7
        input.textLeft = 3
        input.textWidth = 5
        input.geometryValid = true
        input.rightToLeft = true
        input.insertMode = true
        input.selectionLocation = 3
        input.graphemes = [
            CompositionGrapheme(width: 2, utf16Location: 0, utf16Length: 1),
            CompositionGrapheme(width: 2, utf16Location: 1, utf16Length: 1),
            CompositionGrapheme(width: 2, utf16Location: 2, utf16Length: 1),
        ]

        let output = layoutComposition(input)
        XCTAssertFalse(output.displaced)
        XCTAssertEqual(output.placements.count, 2)
        XCTAssertEqual(output.placements[0].column, 6)
        XCTAssertEqual(output.placements[1].column, 4)
    }

    func testLayoutRejectsEmptyGrid() {
        var input = CompositionLayoutInput()
        input.gridWidth = 0
        input.gridHeight = 0
        XCTAssertFalse(layoutComposition(input).valid)
    }

    // MARK: Committed-text transport

    func testRoutesShortCommittedTextThroughInput() {
        let text = routeCommittedText("a<🙂")
        XCTAssertEqual(text.transport, .input)
        XCTAssertEqual(text.utf8, "a<lt>🙂")
        XCTAssertEqual(routeCommittedText("").transport, .none)
    }

    func testRoutesMultilineAndLargeCommittedTextThroughPaste() {
        for text in ["a\nb", "a\rb", "a\r\nb"] {
            let operation = routeCommittedText(text)
            XCTAssertEqual(operation.transport, .paste)
            XCTAssertEqual(operation.utf8, text)
        }

        let boundary = String(repeating: "x", count: committedTextInputLimit)
        XCTAssertEqual(routeCommittedText(boundary).transport, .input)
        XCTAssertEqual(routeCommittedText(boundary + "x").transport, .paste)

        // Escaping is an nvim_input-only concern; nvim_paste sees a literal '<'.
        let multiline = routeCommittedText("a<b\nc<d")
        XCTAssertEqual(multiline.transport, .paste)
        XCTAssertEqual(multiline.utf8, "a<b\nc<d")
    }

    func testRoutesCommittedTextByEscapedSizeNotRawSize() {
        // Each '<' expands to 4 bytes ("<lt>"), so a raw payload at the input
        // limit can still need a paste once escaping is accounted for.
        let manyLessThans = String(repeating: "<", count: committedTextInputLimit)
        let operation = routeCommittedText(manyLessThans)
        XCTAssertEqual(operation.transport, .paste)
        XCTAssertEqual(operation.utf8, manyLessThans)
    }

    func testCommittedTextPreservesCompleteUnicodePayloads() {
        for value in ["é", "☺️", "👍🏽", "👩‍💻", "🇨🇦"] {
            let operation = routeCommittedText(value)
            XCTAssertEqual(operation.transport, .input)
            XCTAssertEqual(operation.utf8, value)
        }
    }

    // MARK: Cocoa event transaction

    func testResolvesCocoaEventTransactionsExactlyOnce() {
        func resolve(_ handled: Bool, _ effect: CocoaCallbackEffect,
                     _ remains: Bool, _ escape: Bool,
                     _ deleteKey: Bool = false) -> CocoaEventResult {
            resolveCocoaEventTransaction(
                CocoaEventTransaction(handleEventReturned: handled,
                                      callbackEffect: effect,
                                      markedTextRemains: remains),
                escape: escape, deleteKey: deleteKey)
        }

        XCTAssertEqual(resolve(true, .none, true, false), .consume)
        XCTAssertEqual(resolve(false, .text, true, false), .consume)
        XCTAssertEqual(resolve(false, .editingCommand, true, false), .routeToNeovim)
        XCTAssertEqual(resolve(true, .editingCommand, true, false), .routeToNeovim)
        XCTAssertEqual(resolve(false, .none, false, false), .routeToNeovim)
        XCTAssertEqual(resolve(false, .none, true, true), .commitAndConsume)
        XCTAssertEqual(resolve(false, .none, true, false), .commitAndRouteToNeovim)
        XCTAssertEqual(resolve(false, .none, true, false, true), .cancelAndConsume)
    }

    func testCompositionKindControlsEscapeAndDeletionPolicy() {
        XCTAssertTrue(deadKeyEscapeCommits(.deadKey))
        XCTAssertFalse(deadKeyEscapeCommits(.ime))
        XCTAssertFalse(deadKeyEscapeCommits(.unknown))
        XCTAssertTrue(deleteCancelsBeforeCocoa(.deadKey))
        XCTAssertFalse(deleteCancelsBeforeCocoa(.ime))
        XCTAssertFalse(deleteCancelsBeforeCocoa(.unknown))
        XCTAssertTrue(focusLossSuspends(.ime))
        XCTAssertFalse(focusLossSuspends(.deadKey))
        XCTAssertFalse(focusLossSuspends(.unknown))
    }

    func testExtractsCommittedCocoaText() {
        XCTAssertEqual(committedString("plain"), "plain")
        let attributed = NSAttributedString(
            string: "attributed",
            attributes: [.foregroundColor: NSColor.red])
        XCTAssertEqual(committedString(attributed), "attributed")
        XCTAssertNil(committedString(42))
    }

    // MARK: Geometry parser

    func testGeometryParserReturnsAtomicTextAreaSnapshot() {
        let widths: MPValue = .array([.array([0x00B7, 0x00B7, 2])])
        let result: MPValue = .array([17, 2, 11, 20, 8, 3, false, widths])

        let geometry = parseCompositionGeometry(result)
        XCTAssertNotNil(geometry)
        XCTAssertEqual(geometry?.windowID, 17)
        XCTAssertEqual(geometry?.textRow, 1)
        XCTAssertEqual(geometry?.textCol, 13)
        XCTAssertEqual(geometry?.textWidth, 17)
        XCTAssertEqual(geometry?.textHeight, 8)
        XCTAssertEqual(geometry?.rightToLeft, false)
        XCTAssertEqual(geometry?.cellwidthOverrides.count, 1)
    }

    func testGeometryParserRejectsMalformedShapes() {
        XCTAssertNil(parseCompositionGeometry(.array([17, 2, 11])))
        // width must exceed textoff.
        XCTAssertNil(parseCompositionGeometry(
            .array([17, 2, 11, 3, 8, 3, false, .array([])])))
        // window id must be positive.
        XCTAssertNil(parseCompositionGeometry(
            .array([0, 2, 11, 20, 8, 3, false, .array([])])))
        // an override width other than 1 or 2 is invalid.
        XCTAssertNil(parseCompositionGeometry(
            .array([17, 2, 11, 20, 8, 3, false,
                    .array([.array([0x61, 0x61, 3])])])))
    }

    // MARK: Coordinator lifecycle

    @MainActor
    private final class RecordingDelegate: TextInputCoordinatorDelegate {
        var commits: [String] = []
        func commitCompositionString(_ text: String) { commits.append(text) }
        // See TextInputCoordinator: avoid the isolated-deinit teardown crash.
        nonisolated deinit {}
    }

    @MainActor
    private final class CompositionKindState {
        var value: CompositionKind

        init(_ value: CompositionKind) {
            self.value = value
        }
    }

    @MainActor
    private func makeCoordinator(kind: CompositionKind)
        -> (TextInputCoordinator, RecordingDelegate) {
        let delegate = RecordingDelegate()
        let coordinator = TextInputCoordinator(delegate: delegate,
                                               kindResolver: { kind })
        return (coordinator, delegate)
    }

    @MainActor
    func testDeadKeyDeleteCommandCancelsComposition() {
        let (coordinator, delegate) = makeCoordinator(kind: .deadKey)
        coordinator.setMarkedText("preedit", selectedRange: NSRange(location: 3, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))

        coordinator.beginInputContextEvent()
        coordinator.doCommandBySelector(
            #selector(NSStandardKeyBindingResponding.deleteBackward(_:)),
            inputContext: nil)
        let result = coordinator.finishInputContextEvent(handled: true, escape: false,
                                                         deleteKey: true)
        XCTAssertEqual(result, .consume)
        XCTAssertFalse(coordinator.isActive)
        XCTAssertEqual(delegate.commits.count, 0)
    }

    @MainActor
    func testImeDeleteCommandDefersToCocoaEventResult() {
        let (coordinator, delegate) = makeCoordinator(kind: .ime)
        coordinator.setMarkedText("preedit", selectedRange: NSRange(location: 3, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))

        coordinator.beginInputContextEvent()
        coordinator.doCommandBySelector(
            #selector(NSStandardKeyBindingResponding.deleteBackward(_:)),
            inputContext: nil)
        let handled = coordinator.finishInputContextEvent(handled: true, escape: false,
                                                          deleteKey: true)
        XCTAssertEqual(handled, .consume)
        XCTAssertTrue(coordinator.isActive)

        coordinator.beginInputContextEvent()
        coordinator.doCommandBySelector(
            #selector(NSStandardKeyBindingResponding.deleteForward(_:)),
            inputContext: nil)
        let declined = coordinator.finishInputContextEvent(handled: false, escape: false,
                                                           deleteKey: true)
        XCTAssertEqual(declined, .cancelAndConsume)
        XCTAssertTrue(coordinator.isActive)
        coordinator.cancel(inputContext: nil)
        XCTAssertFalse(coordinator.isActive)
        XCTAssertEqual(delegate.commits.count, 0)
    }

    @MainActor
    func testCancelsWhenInputSourceChanges() {
        let delegate = RecordingDelegate()
        let kind = CompositionKindState(.ime)
        let coordinator = TextInputCoordinator(delegate: delegate,
                                               kindResolver: { kind.value })
        coordinator.setMarkedText("preedit", selectedRange: NSRange(location: 3, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))

        kind.value = .deadKey
        coordinator.cancelIfInputSourceChanged(inputContext: nil)
        XCTAssertFalse(coordinator.isActive)
        XCTAssertEqual(delegate.commits.count, 0)
    }

    @MainActor
    func testResumesOnlyWhenInputSourceMatches() {
        let delegate = RecordingDelegate()
        let kind = CompositionKindState(.ime)
        let coordinator = TextInputCoordinator(delegate: delegate,
                                               kindResolver: { kind.value })
        coordinator.setMarkedText("preedit", selectedRange: NSRange(location: 3, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.suspendOrCancel(inputContext: nil)

        coordinator.resume(inputContext: nil)
        XCTAssertTrue(coordinator.isActive)

        coordinator.suspendOrCancel(inputContext: nil)
        kind.value = .deadKey
        coordinator.resume(inputContext: nil)
        XCTAssertFalse(coordinator.isActive)
        XCTAssertEqual(delegate.commits.count, 0)
    }

    @MainActor
    func testDoesNotSuppressNvimCursorWhileSuspended() {
        let (coordinator, _) = makeCoordinator(kind: .ime)
        coordinator.setMarkedText("preedit", selectedRange: NSRange(location: 3, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(coordinator.suppressesNvimCursor)

        coordinator.suspendOrCancel(inputContext: nil)
        XCTAssertTrue(coordinator.isActive)
        XCTAssertFalse(coordinator.suppressesNvimCursor)

        coordinator.resume(inputContext: nil)
        XCTAssertTrue(coordinator.suppressesNvimCursor)
    }

    @MainActor
    func testMarkedTextClientState() {
        let (coordinator, _) = makeCoordinator(kind: .ime)
        XCTAssertFalse(coordinator.hasMarkedText())
        XCTAssertTrue(NSEqualRanges(coordinator.markedRange(),
                                    NSRange(location: NSNotFound, length: 0)))
        XCTAssertTrue(NSEqualRanges(coordinator.selectedRange(),
                                    NSRange(location: 0, length: 0)))

        var actual = NSRange(location: 1, length: 1)
        XCTAssertNil(coordinator.attributedSubstring(
            forProposedRange: NSRange(location: 0, length: 0), actualRange: &actual))
        XCTAssertTrue(NSEqualRanges(actual, NSRange(location: NSNotFound, length: 0)))

        // A selection past the string end clamps to its length.
        coordinator.setMarkedText("unsupported", selectedRange: NSRange(location: 99, length: 4),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(coordinator.hasMarkedText())
        XCTAssertTrue(NSEqualRanges(coordinator.markedRange(), NSRange(location: 0, length: 11)))
        XCTAssertTrue(NSEqualRanges(coordinator.selectedRange(), NSRange(location: 11, length: 0)))

        var markedActual = NSRange(location: 0, length: 0)
        let marked = coordinator.attributedSubstring(
            forProposedRange: NSRange(location: 2, length: 4), actualRange: &markedActual)
        XCTAssertEqual(marked?.string, "supp")
        XCTAssertTrue(NSEqualRanges(markedActual, NSRange(location: 2, length: 4)))

        // Committing an empty marked string ends the session.
        coordinator.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(coordinator.hasMarkedText())
        XCTAssertTrue(NSEqualRanges(coordinator.markedRange(),
                                    NSRange(location: NSNotFound, length: 0)))
    }
}
