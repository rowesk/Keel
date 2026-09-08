import Foundation
import XCTest
@testable import KeelUI

/// The wave-2 build could fill the queue and never empty it: nothing sent
/// `openNextQueuedDestination`, and typing an address on Home enqueued instead
/// of opening. These pin the way out.
@MainActor
final class HomeQueueDrainTests: XCTestCase {
    func testHomeCanAskToStartTheQueue() {
        var performed: [KeelHomeAction] = []
        let actions = KeelHomeActions { performed.append($0) }

        actions.perform(.startQueue)

        XCTAssertEqual(performed, [.startQueue])
    }

    func testStartIsOfferedOnlyWhenTheCoordinatorWouldActuallyAdvance() {
        let ready = KeelHomeModel(queue: KeelHomeModel.fixture(count: 2).queue)
        XCTAssertTrue(ready.canStartQueue)

        let empty = KeelHomeModel(queue: [])
        XCTAssertFalse(empty.canStartQueue, "Nothing to start")

        let checkpointFirst = KeelHomeModel(
            resume: KeelResumeItem(
                displayURL: "https://example.test/a",
                hostname: "example.test",
                savedAt: .now
            ),
            queue: KeelHomeModel.fixture(count: 2).queue
        )
        XCTAssertFalse(
            checkpointFirst.canStartQueue,
            "An unfinished page is ahead of the queue, so Start must not jump it"
        )

        let pageActive = KeelHomeModel(
            queue: KeelHomeModel.fixture(count: 2).queue,
            canStartQueue: false
        )
        XCTAssertFalse(pageActive.canStartQueue, "A page is already active")
    }

    func testHomeSaysWhenATypedAddressWillJoinTheQueue() {
        XCTAssertFalse(KeelHomeModel().queueIsHolding)
        XCTAssertTrue(KeelHomeModel(queue: KeelHomeModel.fixture(count: 1).queue).queueIsHolding)
        XCTAssertTrue(
            KeelHomeModel(
                resume: KeelResumeItem(
                    displayURL: "https://example.test/a",
                    hostname: "example.test",
                    savedAt: .now
                )
            ).queueIsHolding
        )
    }

    func testHomeReachesTheScreensThatWerePreviouslyShortcutOnly() {
        var performed: [KeelHomeAction] = []
        let actions = KeelHomeActions { performed.append($0) }

        actions.perform(.showHistory)
        actions.perform(.showDownloads)
        actions.perform(.showSettings)

        XCTAssertEqual(performed, [.showHistory, .showDownloads, .showSettings])
    }

    func testQueueRowsAreNamedByPageRatherThanByRawURL() {
        let titled = KeelQueueItem(
            id: UUID(),
            displayURL: "https://news.ycombinator.com/item?id=1",
            hostname: "news.ycombinator.com",
            title: "Hacker News",
            capturedAt: .now,
            sequence: 0
        )
        XCTAssertEqual(titled.primaryText, "Hacker News")
        XCTAssertEqual(titled.secondaryText, "news.ycombinator.com/item?id=1")

        let untitled = KeelQueueItem(
            id: UUID(),
            displayURL: "https://www.example.com/",
            hostname: "www.example.com",
            capturedAt: .now,
            sequence: 0
        )
        XCTAssertEqual(untitled.primaryText, "www.example.com")
        XCTAssertEqual(untitled.secondaryText, "example.com", "Scheme, www and a bare slash are noise")
    }

    func testRelativeTimesReplaceWallClockDeadlines() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(now.addingTimeInterval(-10).keelRelativeDescription(from: now), "just now")
        XCTAssertEqual(now.addingTimeInterval(-600).keelRelativeDescription(from: now), "10 min ago")
        XCTAssertEqual(now.addingTimeInterval(-7200).keelRelativeDescription(from: now), "2 hr ago")

        XCTAssertEqual(now.addingTimeInterval(45).keelCountdownDescription(from: now), "45s left")
        XCTAssertEqual(now.addingTimeInterval(300).keelCountdownDescription(from: now), "5 min left")
        XCTAssertNil(now.addingTimeInterval(-1).keelCountdownDescription(from: now))
    }
}

@MainActor
extension HomeQueueDrainTests {
    func testHomeExplainsWhyStartIsUnavailable() {
        let blockedByCheckpoint = KeelHomeModel(
            resume: KeelResumeItem(
                displayURL: "https://example.test/a",
                hostname: "example.test",
                savedAt: .now
            ),
            queue: KeelHomeModel.fixture(count: 2).queue
        )
        XCTAssertEqual(
            blockedByCheckpoint.startBlockedReason,
            "Resume or discard the unfinished page first"
        )

        let blockedByPage = KeelHomeModel(
            queue: KeelHomeModel.fixture(count: 2).queue,
            canStartQueue: false
        )
        XCTAssertEqual(blockedByPage.startBlockedReason, "Close the active page first")

        let ready = KeelHomeModel(queue: KeelHomeModel.fixture(count: 2).queue)
        XCTAssertNil(ready.startBlockedReason, "Start works, so there is nothing to explain")

        XCTAssertNil(KeelHomeModel().startBlockedReason, "No queue, no Start, nothing to explain")
    }
}
