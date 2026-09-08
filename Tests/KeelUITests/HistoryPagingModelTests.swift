import XCTest
@testable import KeelUI

final class HistoryPagingModelTests: XCTestCase {
    func testPagedModelReportsOlderSessionsWithoutHoldingThem() {
        let model = KeelHistoryModel(
            visits: [visit(hostname: "docs.test", at: 0)],
            hasOlderSessions: true,
            hasAnyHistory: true
        )

        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertTrue(model.hasOlderSessions)
        XCTAssertFalse(model.isLoadingOlderSessions)
        XCTAssertFalse(model.isSearchActive)
        XCTAssertTrue(model.hasAnyHistory)
    }

    func testSearchResultsReplaceTheBrowseListWithoutClaimingHistoryIsEmpty() {
        let empty = KeelHistoryModel(sessions: [], searchQuery: "gardening", hasAnyHistory: true)

        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(empty.isSearchActive)
        XCTAssertTrue(empty.hasAnyHistory)

        let found = KeelHistoryModel(
            visits: [visit(hostname: "archive.test", at: 0, title: "Gardening notes")],
            searchQuery: "gardening",
            searchReachedLimit: true,
            hasAnyHistory: true
        )
        XCTAssertEqual(found.allVisitIDs.count, 1)
        XCTAssertTrue(found.searchReachedLimit)
    }

    func testWhitespaceOnlyQueryIsNotASearch() {
        XCTAssertFalse(KeelHistoryModel(sessions: [], searchQuery: "   ").isSearchActive)
    }

    func testSelectionSurvivesPagingAndClearsWhenTheDeletionIsConfirmed() {
        let onPageOne = UUID()
        let onPageTwo = UUID()
        var state = KeelHistoryInteractionState()
        state.toggleVisit(onPageOne, isSelected: true)
        state.toggleVisit(onPageTwo, isSelected: true)

        // A later page replaces the loaded visits. A selection made earlier is
        // still what the reader meant.
        XCTAssertEqual(state.selectedVisitIDs, [onPageOne, onPageTwo])

        state.requestSelectedDeletion()
        XCTAssertEqual(state.confirmPendingDeletion(), .deleteVisits([onPageOne, onPageTwo]))
        XCTAssertTrue(state.selectedVisitIDs.isEmpty)
    }

    func testPruningKeepsOnlyIdentifiersTheStoreStillHolds() {
        let kept = UUID()
        let gone = UUID()
        var state = KeelHistoryInteractionState(selectedVisitIDs: [kept, gone])

        state.pruneSelection(to: [kept])

        XCTAssertEqual(state.selectedVisitIDs, [kept])
    }

    private func visit(hostname: String, at offset: TimeInterval, title: String? = nil) -> KeelHistoryVisit {
        KeelHistoryVisit(
            id: UUID(),
            sessionID: UUID(),
            hostname: hostname,
            displayURL: "https://\(hostname)/page",
            title: title,
            visitedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset)
        )
    }
}
