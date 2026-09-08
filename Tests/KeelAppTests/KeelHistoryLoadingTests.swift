import Foundation
import KeelStore
import XCTest
@testable import KeelApp

/// A page of History holds ended sessions only, but the screen also shows the
/// session the user is in right now. Getting that wrong rendered the current
/// session as "No visits" while the page it was on was plainly loaded.
@MainActor
final class KeelHistoryLoadingTests: XCTestCase {
    func testTheActiveSessionIsFetchedEvenThoughItIsNeverInAPage() {
        let ended = [summary(), summary()]
        let activeID = UUID()

        let ids = KeelApplicationDelegate.historySessionIDsToLoad(
            page: ended,
            activeSessionID: activeID
        )

        XCTAssertEqual(ids, ended.map(\.id) + [activeID])
    }

    func testAnActiveSessionAlreadyInThePageIsNotFetchedTwice() {
        let ended = [summary(), summary()]

        let ids = KeelApplicationDelegate.historySessionIDsToLoad(
            page: ended,
            activeSessionID: ended[0].id
        )

        XCTAssertEqual(ids, ended.map(\.id))
    }

    func testNoActiveSessionLoadsExactlyThePage() {
        let ended = [summary()]

        XCTAssertEqual(
            KeelApplicationDelegate.historySessionIDsToLoad(page: ended, activeSessionID: nil),
            ended.map(\.id)
        )
        XCTAssertTrue(
            KeelApplicationDelegate.historySessionIDsToLoad(page: [], activeSessionID: nil).isEmpty
        )
    }

    private func summary(id: UUID = UUID()) -> HistorySessionSummary {
        HistorySessionSummary(
            id: id,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 2_000),
            firstVisitedAt: Date(timeIntervalSince1970: 1_000),
            lastVisitedAt: Date(timeIntervalSince1970: 2_000),
            visitCount: 1,
            hostname: "example.test",
            title: "Example",
            displayURL: "https://example.test/",
            faviconReferenceKey: nil
        )
    }
}
