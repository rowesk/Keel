import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import KeelUI

@MainActor
final class HomeViewTests: XCTestCase {
    func testQueueCountExcludesUndoAndResumeAndStartKeepsPriority() {
        let undo = KeelUndoItem(displayURL: "https://closed.test", hostname: "closed.test", deadline: .now)
        let queue = KeelHomeModel.fixture(count: 3).queue
        let ready = KeelHomeModel(undo: undo, queue: queue)
        XCTAssertEqual(ready.queueCountDescription, "3 queued")
        XCTAssertEqual(ready.primaryAction, .startQueue)
        XCTAssertTrue(ready.canStartQueue)
        let resume = KeelResumeItem(displayURL: "https://unfinished.test", hostname: "unfinished.test", savedAt: .now)
        let held = KeelHomeModel(resume: resume, undo: undo, queue: queue)
        XCTAssertEqual(held.queueCountDescription, "3 queued")
        XCTAssertEqual(held.primaryAction, .resume)
        XCTAssertFalse(held.canStartQueue)
        XCTAssertEqual(KeelHomeModel(undo: undo).primaryAction, .restoreClosedPage)
        XCTAssertNil(KeelHomeModel(undo: undo).queueCountDescription)
    }

    func testExpandingQueueKeepsCapsuleAtTheSamePositionAtMinimumSize() {
        for expanded in [false, true] {
            let anchor = KeelHomeCapsuleAnchor()
            let view = NSHostingView(rootView: HomeView(model: .fixture(count: 30), capsuleAnchor: anchor,
                                                       queueInitiallyExpanded: expanded))
            view.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(anchor.frame?.minY ?? -1, 480 * HomeView.capsuleTopFraction, accuracy: 1)
            XCTAssertEqual(anchor.frame?.height ?? -1, KeelDesign.capsuleHeight, accuracy: 1)
        }
    }

    func testRenderedHomeContainsNoWebViews() {
        let homeView = NSHostingView(rootView: HomeView())
        homeView.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        homeView.layoutSubtreeIfNeeded()

        XCTAssertFalse(containsWebView(in: homeView))
    }

    private func containsWebView(in view: NSView) -> Bool {
        view is WKWebView || view.subviews.contains(where: containsWebView)
    }

    func testHomeSortsQueueByFIFOSequenceBeforeRendering() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = KeelQueueItem(id: UUID(), displayURL: "https://first.test", hostname: "first.test", capturedAt: now, sequence: 1)
        let oldest = KeelQueueItem(id: UUID(), displayURL: "https://oldest.test", hostname: "oldest.test", capturedAt: now, sequence: 0)

        let model = KeelHomeModel(queue: [first, oldest])

        XCTAssertEqual(model.queue.map(\.id), [oldest.id, first.id])
    }

    func testQueueSelectionReturnEscapeAndConfirmation() {
        let first = UUID()
        let second = UUID()
        var state = KeelHomeInteractionState()

        state.selectQueueItem(first)
        state.selectQueueItem(second, extendsSelection: true)
        XCTAssertEqual(state.selectedQueueIDs, [first, second])

        XCTAssertEqual(state.handle(.submit, queueIDs: [first, second]), .selectQueueItem(second))

        _ = state.handle(.deleteSelection, queueIDs: [first, second])
        XCTAssertEqual(state.pendingDeletion, .selected([first, second]))
        XCTAssertEqual(state.confirmPendingDeletion(), .deleteQueueItems([first, second]))
        XCTAssertTrue(state.selectedQueueIDs.isEmpty)

        state.selectQueueItem(first)
        state.escape()
        XCTAssertTrue(state.selectedQueueIDs.isEmpty)
    }

    func testEscapeCancelsConfirmationBeforeSelection() {
        let id = UUID()
        var state = KeelHomeInteractionState(selectedQueueIDs: [id], focusedQueueID: id)
        _ = state.handle(.deleteSelection, queueIDs: [id])

        state.escape()
        XCTAssertNil(state.pendingDeletion)
        XCTAssertEqual(state.selectedQueueIDs, [id])
    }

    func testQueueClearConfirmationAndEmptyQueueDoNotEmitAction() {
        var state = KeelHomeInteractionState()
        XCTAssertNil(state.handle(.clearQueue, queueIDs: []))

        let id = UUID()
        XCTAssertNil(state.handle(.clearQueue, queueIDs: [id]))
        XCTAssertEqual(state.pendingDeletion, .all)
        XCTAssertEqual(state.confirmPendingDeletion(), .clearQueue)
    }

    func testQueueArrowMovementKeepsReturnOnTheFocusedItem() {
        let first = UUID()
        let second = UUID()
        var state = KeelHomeInteractionState()

        _ = state.handle(.moveDown, queueIDs: [first, second])
        XCTAssertEqual(state.focusedQueueID, first)
        _ = state.handle(.moveDown, queueIDs: [first, second])
        XCTAssertEqual(state.focusedQueueID, second)
        XCTAssertEqual(state.handle(.submit, queueIDs: [first, second]), .selectQueueItem(second))

        _ = state.handle(.moveUp, queueIDs: [first, second])
        XCTAssertEqual(state.focusedQueueID, first)
    }

    func testLargeHomeFixtureBuildsWithinOneSecond() {
        let started = ContinuousClock.now
        let model = KeelHomeModel.fixture(count: 10_000)
        let elapsed = started.duration(to: .now)

        XCTAssertEqual(model.queue.count, 10_000)
        XCTAssertLessThan(elapsed, .seconds(1))
    }
}
