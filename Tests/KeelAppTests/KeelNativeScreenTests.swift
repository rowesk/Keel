import AppKit
import Foundation
@testable import KeelCoordinator
@testable import KeelStore
import KeelUI
import KeelWeb
import XCTest
@testable import KeelApp

@MainActor
final class KeelNativeScreenTests: XCTestCase {
    func testNativeHostKeepsOneSwiftUIHostAndContainsNoWebView() {
        let host = KeelNativeScreenHost()
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 480)

        host.showHome(model: KeelHomeModel.fixture(count: 2), actions: KeelHomeActions())
        XCTAssertEqual(host.screen, .home)
        host.showHistory(model: KeelHistoryModel.fixture(sessionCount: 1, visitsPerSession: 2), actions: KeelHistoryActions())
        XCTAssertEqual(host.screen, .history)
        host.showDownloads(model: KeelDownloadModel.fixture(count: 2), actions: KeelDownloadActions())
        XCTAssertEqual(host.screen, .downloads)
        host.showSettings(model: KeelSettingsModel(), actions: KeelSettingsActions())
        XCTAssertEqual(host.screen, .settings)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(host.subviews.filter { $0 === host.hostedViewForTesting }.count, 1)
        XCTAssertFalse(containsWebView(in: host))
    }

    func testHomeCapsuleAnchorFollowsTheWindowWhenItResizes() {
        let shell = KeelShellView()
        let controller = KeelWindowController(shellView: shell, permitsWindowPresentation: false)
        let window = try! XCTUnwrap(controller.window)
        let host = KeelNativeScreenHost()
        shell.addSubview(host)
        shell.pinToContentArea(host)
        window.layoutIfNeeded() // Keep unattended tests offscreen.
        window.setFrame(NSRect(x: 100, y: 100, width: 1_120, height: 760), display: true)
        host.showHome(model: KeelHomeModel(), actions: KeelHomeActions())
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let before = try! XCTUnwrap(host.homeCapsuleFrame)

        // Going full screen moved the capsule 570pt down the window and the
        // palette kept docking where it used to be.
        window.setFrame(NSRect(x: 0, y: 0, width: 1_920, height: 1_400), display: true)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let after = try! XCTUnwrap(host.homeCapsuleFrame)
        XCTAssertGreaterThan(after.minY, before.minY + 200, "Anchor still reports the old window's layout")
        XCTAssertEqual(after.midX, host.bounds.midX, accuracy: 1)

        controller.removeHiddenChromeDragMonitor()
        window.orderOut(nil)
    }

    func testTheCapsuleHoldsStillWhenWorkArrivesBelowIt() {
        let shell = KeelShellView()
        let controller = KeelWindowController(shellView: shell, permitsWindowPresentation: false)
        let window = try! XCTUnwrap(controller.window)
        let host = KeelNativeScreenHost()
        shell.addSubview(host)
        shell.pinToContentArea(host)
        window.layoutIfNeeded() // Keep unattended tests offscreen.
        window.setFrame(NSRect(x: 100, y: 100, width: 1_120, height: 760), display: true)

        host.showHome(model: KeelHomeModel(), actions: KeelHomeActions())
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let empty = try! XCTUnwrap(host.homeCapsuleFrame)

        // Resume, reopen and a long queue all stack beneath the field. None of
        // it may move the field: it used to jump up to make room.
        host.showHome(
            model: KeelHomeModel(
                resume: KeelResumeItem(displayURL: "a.test/x", hostname: "a.test", title: "A", savedAt: .now),
                undo: KeelUndoItem(displayURL: "b.test/y", hostname: "b.test", title: "B", deadline: .now.addingTimeInterval(600)),
                queue: KeelHomeModel.fixture(count: 30).queue
            ),
            actions: KeelHomeActions()
        )
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let busy = try! XCTUnwrap(host.homeCapsuleFrame)

        XCTAssertEqual(busy.minY, empty.minY, accuracy: 0.5)
        XCTAssertEqual(empty.minY, host.bounds.height * HomeView.capsuleTopFraction, accuracy: 1)

        controller.removeHiddenChromeDragMonitor()
        window.orderOut(nil)
    }

    func testDelegateHidesOldScreenBeforeManagementLoad() {
        let host = KeelNativeScreenHost()
        let delegate = KeelApplicationDelegate(nativeScreenHost: host)
        let runtimeState = KeelRuntimeState(
            queue: [],
            resumeCheckpoint: nil,
            closeUndo: nil,
            queueDeletionUndo: nil,
            activeSession: nil,
            downloads: [],
            settings: KeelSettings()
        )
        let homeState = KeelCoordinatorState(
            surface: .home,
            activePage: nil,
            detour: nil,
            undoPage: nil,
            runtimeState: runtimeState
        )
        delegate.updateNativeScreens(for: homeState)
        XCTAssertEqual(host.screen, .home)
        XCTAssertFalse(host.isHidden)

        let managementState = KeelCoordinatorState(
            surface: .management(.history),
            activePage: nil,
            detour: nil,
            undoPage: nil,
            runtimeState: runtimeState,
            managementUnderlyingSurface: .home
        )
        // The delegate must hide Home synchronously before it starts the async
        // Store load for History, so Home controls cannot fire during the gap.
        delegate.updateNativeScreens(for: managementState)
        XCTAssertNil(host.screen)
        XCTAssertTrue(host.isHidden)
    }

    func testDelegateRestoresPageFocusOnlyAfterManagementDismissal() {
        let host = KeelNativeScreenHost()
        var focusCount = 0
        let delegate = KeelApplicationDelegate(
            nativeScreenHost: host,
            focusVisiblePage: { focusCount += 1 }
        )
        let runtimeState = KeelRuntimeState(
            queue: [],
            resumeCheckpoint: nil,
            closeUndo: nil,
            queueDeletionUndo: nil,
            activeSession: nil,
            downloads: [],
            settings: KeelSettings()
        )
        let homeState = KeelCoordinatorState(
            surface: .home,
            activePage: nil,
            detour: nil,
            undoPage: nil,
            runtimeState: runtimeState
        )
        let managementState = KeelCoordinatorState(
            surface: .management(.settings),
            activePage: nil,
            detour: nil,
            undoPage: nil,
            runtimeState: runtimeState,
            managementUnderlyingSurface: .home
        )
        let pageState = KeelCoordinatorState(
            surface: .page,
            activePage: nil,
            detour: nil,
            undoPage: nil,
            runtimeState: runtimeState
        )

        delegate.updateNativeScreens(for: homeState)
        delegate.updateNativeScreens(for: managementState)
        delegate.updateNativeScreens(for: pageState)

        XCTAssertTrue(host.isHidden)
        XCTAssertEqual(focusCount, 1)

        // Repeated page updates and a Home-to-page transition must not steal focus.
        delegate.updateNativeScreens(for: pageState)
        XCTAssertEqual(focusCount, 1)
        delegate.updateNativeScreens(for: homeState)
        delegate.updateNativeScreens(for: pageState)
        XCTAssertEqual(focusCount, 1)
    }

    func testHistoryMappingPreservesExactStoreGroupAndBranchIdentity() {
        let sessionID = UUID()
        let visitID = UUID()
        let groupID = UUID()
        let branchID = HistoryBranchID(rawValue: "detour:\(sessionID.uuidString):branch")
        let url = URL(string: "https://example.test/item")!
        let visit = HistoryVisit(
            id: visitID,
            url: url,
            title: "Item",
            visitedAt: Date(timeIntervalSince1970: 1_700_000_000),
            browsingSessionID: sessionID,
            branchID: branchID,
            navigationKind: .document,
            source: .history,
            hostnameGroupID: groupID
        )
        let result = KeelAppPresentationMapper.historyModel(
            activeSession: BrowsingSession(id: sessionID, startedAt: visit.visitedAt),
            endedSessions: [],
            visitsBySession: [sessionID: [visit]]
        )

        let mapped = try! XCTUnwrap(result.model.sessions.first?.groups.first?.visits.first)
        XCTAssertEqual(mapped.hostnameGroupID, groupID)
        XCTAssertEqual(mapped.branchID, branchID.rawValue)
        XCTAssertEqual(result.visitURLs[visitID], url)
    }

    func testDownloadMappingUsesLiveProgressWithoutPolling() {
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let record = DownloadRecord(
            id: id,
            hostname: "files.test",
            filename: "report.pdf",
            pathReference: "/tmp/report.pdf",
            byteCount: 2,
            state: .inProgress,
            createdAt: createdAt
        )
        let snapshot = KeelDownloadSnapshot(
            id: id,
            sourceHostname: "files.test",
            filename: "report.pdf",
            destinationURL: URL(fileURLWithPath: "/tmp/report.pdf"),
            receivedBytes: 5,
            expectedBytes: 10,
            state: .inProgress,
            createdAt: createdAt
        )

        let item = try! XCTUnwrap(KeelAppPresentationMapper.downloadModel(records: [record], liveSnapshots: [snapshot]).items.first)
        XCTAssertEqual(item.receivedBytes, 5)
        XCTAssertEqual(item.expectedBytes, 10)
        XCTAssertEqual(item.progress, 0.5)
    }

    func testInterruptedDownloadUsesReadableFailureMessage() {
        let record = DownloadRecord(
            id: UUID(),
            hostname: "files.test",
            filename: "report.pdf",
            byteCount: 2,
            state: .failed,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_001),
            errorCode: KeelDownloadErrorCode.interruptedAfterRestart
        )

        let item = try! XCTUnwrap(
            KeelAppPresentationMapper.downloadModel(records: [record], liveSnapshots: []).items.first
        )
        XCTAssertEqual(item.status, .failed(message: "Keel quit before this download finished."))
    }

    func testDownloadManagementModelIsBoundedAfterLiveSnapshotMerge() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let records = (0..<200).map { index in
            DownloadRecord(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                hostname: "files.test",
                filename: "record-\(index).bin",
                byteCount: 1,
                state: .completed,
                createdAt: baseDate
            )
        }
        let newest = KeelDownloadSnapshot(
            id: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
            sourceHostname: "files.test",
            filename: "newest.bin",
            receivedBytes: 1,
            state: .completed,
            createdAt: baseDate.addingTimeInterval(1)
        )
        let oldest = KeelDownloadSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            sourceHostname: "files.test",
            filename: "oldest.bin",
            receivedBytes: 1,
            state: .completed,
            createdAt: baseDate.addingTimeInterval(-1)
        )

        let model = KeelApplicationDelegate.downloadManagementModel(
            records: records,
            liveSnapshots: [newest, oldest]
        )

        XCTAssertEqual(model.items.count, 200)
        XCTAssertEqual(model.items.first?.id, newest.id)
        XCTAssertFalse(model.itemIDs.contains(oldest.id))
        XCTAssertEqual(model.itemIDs.last, records[1].id)
    }

    func testSettingsMappingCoversCustomProviderAndQueueExpiry() {
        let settings = KeelSettings(
            queueRetention: .days7,
            keepsClosedPageReady: false,
            searchProvider: .custom(template: "https://search.test/?q={query}")
        )
        let model = KeelAppPresentationMapper.settingsModel(from: settings, hasDiagnostics: true)

        XCTAssertEqual(model.searchProvider, .custom)
        XCTAssertEqual(model.customSearchTemplate, "https://search.test/?q={query}")
        XCTAssertEqual(model.queueExpiry, .days7)
        XCTAssertFalse(model.keepsClosedPageReady)
        XCTAssertTrue(model.hasDiagnostics)

        XCTAssertEqual(KeelAppPresentationMapper.settings(from: model, current: settings), settings)
    }

    func testDiagnosticsPresenceSurvivesSettingsUpdatesAndClearsAfterRefresh() {
        let cache = KeelDiagnosticsPresenceCache(hasDiagnostics: true)
        let settings = KeelSettings()

        _ = KeelAppPresentationMapper.settingsModel(
            from: settings,
            hasDiagnostics: cache.hasDiagnostics
        )
        XCTAssertTrue(cache.hasDiagnostics)

        // A settings mutation does not answer the diagnostics query, so it must
        // leave the last confirmed presence value intact.
        let changedSettings = KeelSettings(queueRetention: .days7, keepsClosedPageReady: false)
        _ = KeelAppPresentationMapper.settingsModel(
            from: changedSettings,
            hasDiagnostics: cache.hasDiagnostics
        )
        XCTAssertTrue(cache.hasDiagnostics)

        // The explicit management refresh supplies the new Store truth after
        // diagnostics deletion.
        cache.update(hasDiagnostics: false)
        _ = KeelAppPresentationMapper.settingsModel(
            from: changedSettings,
            hasDiagnostics: cache.hasDiagnostics
        )
        XCTAssertFalse(cache.hasDiagnostics)
    }

    func testQueueUndoExpiryReplacesAndCancelsPreviousTask() async {
        let expiry = KeelQueueDeletionUndoExpiryController { _ in
            try await Task.sleep(for: .seconds(60))
        }
        expiry.update(deadline: Date.now.addingTimeInterval(60))
        let replacement = Date.now.addingTimeInterval(120)
        expiry.update(deadline: replacement)
        XCTAssertEqual(expiry.deadline, replacement)
        expiry.cancel()
        XCTAssertNil(expiry.deadline)
    }

    func testDiagnosticsBytesUseInjectedOffscreenSavePanel() {
        let panel = SavePanelSpy()
        let delegate = KeelApplicationDelegate(diagnosticsSavePanel: panel)
        let bytes = Data("diagnostics".utf8)

        delegate.presentDiagnosticsExport(bytes)

        XCTAssertEqual(panel.savedData, bytes)
        XCTAssertNil(panel.requestedWindow)
    }

    private func containsWebView(in view: NSView) -> Bool {
        view.subviews.contains(where: containsWebView)
    }
}

@MainActor
private final class SavePanelSpy: KeelDiagnosticsSavePanelPresenting {
    private(set) var savedData: Data?
    private(set) var requestedWindow: NSWindow?

    func save(
        data: Data,
        suggestedFileName: String,
        in window: NSWindow?,
        completion: @escaping @MainActor (Result<URL, KeelDiagnosticsSaveError>) -> Void
    ) {
        savedData = data
        requestedWindow = window
        completion(.success(URL(fileURLWithPath: "/tmp/keel-diagnostics.json")))
    }
}
