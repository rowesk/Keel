import XCTest
@testable import KeelUI

final class ManagementModelTests: XCTestCase {
    func testHistoryGroupsOnlyConsecutiveHostnamesWithinSessions() {
        let sessionID = UUID()
        let docsGroupID = UUID()
        let mailGroupID = UUID()
        let secondDocsGroupID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let visits = [
            KeelHistoryVisit(id: UUID(), sessionID: sessionID, hostname: "docs.test", displayURL: "https://docs.test/a", visitedAt: base, hostnameGroupID: docsGroupID),
            KeelHistoryVisit(id: UUID(), sessionID: sessionID, hostname: "docs.test", displayURL: "https://docs.test/b", visitedAt: base.addingTimeInterval(1), hostnameGroupID: docsGroupID),
            KeelHistoryVisit(id: UUID(), sessionID: sessionID, hostname: "mail.test", displayURL: "https://mail.test", visitedAt: base.addingTimeInterval(2), hostnameGroupID: mailGroupID),
            KeelHistoryVisit(id: UUID(), sessionID: sessionID, hostname: "docs.test", displayURL: "https://docs.test/c", visitedAt: base.addingTimeInterval(3), hostnameGroupID: secondDocsGroupID)
        ]

        let model = KeelHistoryModel(visits: visits)

        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.sessions[0].groups.map(\.hostname), ["docs.test", "mail.test", "docs.test"])
        XCTAssertEqual(model.sessions[0].groups.map(\.id), [docsGroupID, mailGroupID, secondDocsGroupID])
        XCTAssertEqual(model.sessions[0].groups.map { $0.visits.count }, [2, 1, 1])
    }

    func testHistoryGroupIDsStayStableWhenTheModelRefreshes() {
        let sessionID = UUID()
        let firstVisitID = UUID()
        let secondVisitID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let visits = [
            KeelHistoryVisit(id: firstVisitID, sessionID: sessionID, hostname: "docs.test", displayURL: "https://docs.test/a", visitedAt: base),
            KeelHistoryVisit(id: secondVisitID, sessionID: sessionID, hostname: "docs.test", displayURL: "https://docs.test/b", visitedAt: base.addingTimeInterval(1))
        ]

        let firstModel = KeelHistoryModel(visits: visits)
        let refreshedModel = KeelHistoryModel(visits: visits)

        XCTAssertEqual(firstModel.sessions[0].groups.map(\.id), refreshedModel.sessions[0].groups.map(\.id))
        XCTAssertEqual(firstModel.sessions[0].groups[0].id, firstVisitID)
    }

    func testHistoryPreservesStoreHostnameGroupIdentity() {
        let sessionID = UUID()
        let firstVisitID = UUID()
        let secondVisitID = UUID()
        let storeGroupID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let visits = [
            KeelHistoryVisit(
                id: firstVisitID,
                sessionID: sessionID,
                hostname: "docs.test",
                displayURL: "https://docs.test/a",
                visitedAt: base,
                hostnameGroupID: storeGroupID
            ),
            KeelHistoryVisit(
                id: secondVisitID,
                sessionID: sessionID,
                hostname: "docs.test",
                displayURL: "https://docs.test/b",
                visitedAt: base.addingTimeInterval(1),
                hostnameGroupID: storeGroupID
            )
        ]

        let model = KeelHistoryModel(visits: visits)

        XCTAssertEqual(model.sessions[0].groups.count, 1)
        XCTAssertEqual(model.sessions[0].groups[0].id, storeGroupID)
        XCTAssertEqual(model.sessions[0].groups[0].visits.map(\.hostnameGroupID), [storeGroupID, storeGroupID])
    }

    func testHistoryKeyboardMovementReturnAndLayeredEscape() {
        let first = UUID()
        let second = UUID()
        var state = KeelHistoryInteractionState(selectedVisitIDs: [first], focusedVisitID: first)

        _ = state.handle(.moveDown, visitIDs: [first, second])
        XCTAssertEqual(state.focusedVisitID, second)
        XCTAssertEqual(state.handle(.submit, visitIDs: [first, second]), .openVisit(second))

        state.requestSelectedDeletion()
        XCTAssertNil(state.escape())
        XCTAssertNil(state.pendingDeletion)
        XCTAssertNil(state.escape())
        XCTAssertTrue(state.selectedVisitIDs.isEmpty)
        XCTAssertEqual(state.escape(), .dismiss)
    }

    func testHistoryDeletionScopesRemainDistinctAndEscapeIsLayered() {
        let id = UUID()
        var state = KeelHistoryInteractionState(selectedVisitIDs: [id])
        state.requestSelectedDeletion()
        XCTAssertEqual(state.confirmPendingDeletion(), .deleteVisits([id]))

        state.requestAllDeletion()
        state.escape()
        XCTAssertNil(state.pendingDeletion)
        state.escape()
        XCTAssertTrue(state.selectedVisitIDs.isEmpty)
    }

    func testEmptyHistoryModelIsExplicit() {
        let model = KeelHistoryModel()

        XCTAssertTrue(model.isEmpty)
        XCTAssertTrue(model.allVisits.isEmpty)
    }

    func testLargeHistoryFixtureBuildsWithinOneSecond() {
        let started = ContinuousClock.now
        let model = KeelHistoryModel.fixture(sessionCount: 100, visitsPerSession: 100)
        let elapsed = started.duration(to: .now)

        XCTAssertEqual(model.allVisits.count, 10_000)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testDownloadProgressIsBoundedAndDeletionIsConfirmed() {
        let item = KeelDownloadItem(
            id: UUID(),
            hostname: "files.test",
            filename: "report.pdf",
            receivedBytes: 150,
            expectedBytes: 100,
            status: .inProgress,
            createdAt: Date.now
        )
        XCTAssertEqual(item.progress, 1)

        var state = KeelDownloadInteractionState()
        state.requestRecordDeletion(item.id)
        XCTAssertEqual(state.confirmPendingDeletion(), .deleteRecords([item.id]))
    }

    func testDownloadKeyboardMovementReturnAndLayeredEscape() {
        let first = UUID()
        let second = UUID()
        var state = KeelDownloadInteractionState(selectedIDs: [first], focusedID: first)

        _ = state.handle(.moveDown, itemIDs: [first, second])
        XCTAssertEqual(state.focusedID, second)
        XCTAssertEqual(state.handle(.submit, itemIDs: [first, second]), .open(second))

        state.requestSelectedDeletion()
        XCTAssertNil(state.escape())
        XCTAssertNil(state.pendingDeletion)
        XCTAssertNil(state.escape())
        XCTAssertTrue(state.selectedIDs.isEmpty)
        XCTAssertEqual(state.escape(), .dismiss)
    }

    func testEmptyDownloadsModelAndDownloadFixture() {
        XCTAssertTrue(KeelDownloadModel().isEmpty)
        XCTAssertEqual(KeelDownloadModel.fixture(count: 2).items.count, 2)
    }

    func testSettingsTemplateValidationAndExpiryOptions() {
        XCTAssertTrue(KeelSettingsModel.isValidSearchTemplate("https://search.test/?q={query}"))
        XCTAssertFalse(KeelSettingsModel.isValidSearchTemplate("https://search.test/?q={query}&x={query}"))
        XCTAssertEqual(KeelQueueExpiry.allCases.map(\.label), ["24 hours", "72 hours", "7 days"])
    }

    func testSettingsEscapeClearsTransientFocusBeforeDismiss() {
        var state = KeelSettingsInteractionState(hasTransientFocus: true)

        XCTAssertNil(state.handle(.escape))
        XCTAssertEqual(state.handle(.escape), .dismiss)
    }

    func testSettingsHomeSceneRemovalConfirmsAndCancels() {
        let id = KeelHomeSceneID.user(UUID())
        var state = KeelSettingsInteractionState()

        state.requestHomeSceneRemoval(id, name: "Lake dusk")
        XCTAssertEqual(state.pendingDeletion, .removeHomeScene(id, "Lake dusk"))
        XCTAssertEqual(state.pendingDeletion?.confirmationTitle, "Remove \u{201C}Lake dusk\u{201D} from Home?")
        XCTAssertEqual(
            state.pendingDeletion?.confirmationMessage,
            "Keel deletes its copy. Your original file is untouched."
        )
        XCTAssertEqual(state.pendingDeletion?.confirmTitle, "Remove")
        XCTAssertEqual(state.confirmPendingDeletion(), .removeHomeScene(id))
        XCTAssertNil(state.pendingDeletion)

        state.requestHomeSceneRemoval(id, name: "Lake dusk")
        state.cancelPendingDeletion()
        XCTAssertNil(state.pendingDeletion)
        XCTAssertNil(state.confirmPendingDeletion())
    }

    func testSettingsDiagnosticsDeletionRequiresConfirmationAndSupportsKeyboardActions() {
        var state = KeelSettingsInteractionState()

        state.markTransientFocus()
        state.requestDiagnosticsDeletion()
        XCTAssertEqual(state.pendingDeletion, .diagnostics)
        XCTAssertNil(state.handle(.escape))
        XCTAssertNil(state.pendingDeletion)
        XCTAssertTrue(state.hasTransientFocus)
        XCTAssertNil(state.handle(.escape))
        XCTAssertFalse(state.hasTransientFocus)
        XCTAssertEqual(state.handle(.escape), .dismiss)

        state.requestDiagnosticsDeletion()
        XCTAssertEqual(state.handle(.submit), .deleteDiagnostics)
        XCTAssertNil(state.pendingDeletion)
    }
}
