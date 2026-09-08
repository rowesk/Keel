import AppKit
import Foundation
@testable import KeelCoordinator
@testable import KeelStore
@testable import KeelWeb
import WebKit
import XCTest

@MainActor
final class KeelBrowserControllerTests: XCTestCase {
    func testCoordinatorManagementEffectsDetachButRetainWebViewAndNotifyAppKit() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "KeelBrowserManagementEffectsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = try KeelStore(databaseURL: directory.appending(path: "Keel.sqlite3"))
        let existingFile = directory.appending(path: "existing.pdf")
        try Data([1, 2, 3]).write(to: existingFile)
        let validCompleted = DownloadRecord(
            id: UUID(),
            hostname: "downloads.example",
            filename: "existing.pdf",
            pathReference: existingFile.path,
            byteCount: 3,
            state: .completed,
            createdAt: .now,
            completedAt: .now
        )
        let invalidCompleted = DownloadRecord(
            id: UUID(),
            hostname: "downloads.example",
            filename: "missing.pdf",
            pathReference: directory.appending(path: "missing.pdf").path,
            byteCount: 0,
            state: .completed,
            createdAt: .now,
            completedAt: .now
        )
        let invalidActive = DownloadRecord(
            id: UUID(),
            hostname: "downloads.example",
            filename: "pending.pdf",
            pathReference: directory.appending(path: "pending.pdf").path,
            byteCount: 0,
            state: .inProgress,
            createdAt: .now
        )
        _ = try await store.apply([
            .updateDownload(validCompleted),
            .updateDownload(invalidCompleted),
            .updateDownload(invalidActive),
        ])

        let coordinator = KeelCoordinator(store: store)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        var openedURLs: [URL] = []
        var revealedURLs: [URL] = []
        let browser = KeelBrowserController(
            contentView: host,
            coordinator: coordinator,
            store: store,
            webViewFactory: { configuration in
                KeelWebViewFactory.make(configuration: configuration, websiteDataStore: .nonPersistent())
            },
            media: ImmediateMediaController(),
            uploadPresenter: EmptyUploadPresenter(),
            openLocalFile: { openedURLs.append($0) },
            revealLocalFile: { revealedURLs.append($0) }
        )
        var requestedScreens: [KeelManagementScreen] = []
        var refreshCount = 0
        var exportedData: [Data] = []
        browser.onManagementRequested = { requestedScreens.append($0) }
        browser.onManagementDataRefreshRequested = { refreshCount += 1 }
        browser.onDiagnosticsExportRequested = { exportedData.append($0) }

        browser.start()
        await browser.waitForIdleForTesting()
        browser.handle(.openTypedURL(try XCTUnwrap(URL(string: "https://example.invalid/management"))))
        await browser.waitForIdleForTesting()
        let activePageID = try XCTUnwrap(browser.debugSnapshotForTesting().activePageID)
        XCTAssertTrue(containsWebView(host))

        browser.showManagement(.history)
        await browser.waitForIdleForTesting()
        XCTAssertEqual(requestedScreens, [.history])
        XCTAssertEqual(browser.liveWebViewCount, 1)
        XCTAssertFalse(containsWebView(host))
        XCTAssertEqual(browser.debugSnapshotForTesting().activePageID, activePageID)
        XCTAssertNil(browser.debugSnapshotForTesting().visiblePageID)

        browser.showManagement(.downloads)
        await browser.waitForIdleForTesting()
        XCTAssertEqual(requestedScreens, [.history, .downloads])
        XCTAssertEqual(browser.liveWebViewCount, 1)
        XCTAssertFalse(containsWebView(host))

        browser.dismissManagement()
        await browser.waitForIdleForTesting()
        XCTAssertEqual(browser.liveWebViewCount, 1)
        XCTAssertTrue(containsWebView(host))

        browser.showManagement(.settings)
        await browser.waitForIdleForTesting()
        browser.handle(.addURLToQueue(try XCTUnwrap(URL(string: "https://example.invalid/queued"))))
        await browser.waitForIdleForTesting()
        let stateAfterQueue = await coordinator.state()
        let queuedID = try XCTUnwrap(stateAfterQueue?.runtimeState.queue.first?.id)
        browser.handle(.removeQueuedDestinations(ids: [queuedID]))
        await browser.waitForIdleForTesting()
        XCTAssertEqual(refreshCount, 1)

        browser.showManagement(.settings)
        await browser.waitForIdleForTesting()
        browser.exportDiagnostics()
        await browser.waitForIdleForTesting()
        XCTAssertEqual(exportedData.count, 1)
        XCTAssertFalse(exportedData[0].isEmpty)

        var unavailableCount = 0
        browser.onDownloadFileUnavailable = { unavailableCount += 1 }
        browser.handle(.openDownload(id: invalidCompleted.id))
        browser.handle(.revealDownload(id: invalidCompleted.id))
        browser.handle(.cancelDownload(id: invalidActive.id))
        await browser.waitForIdleForTesting()
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertTrue(revealedURLs.isEmpty)
        XCTAssertEqual(unavailableCount, 2)

        browser.handle(.openDownload(id: validCompleted.id))
        browser.handle(.revealDownload(id: validCompleted.id))
        await browser.waitForIdleForTesting()
        XCTAssertEqual(openedURLs, [existingFile.standardizedFileURL])
        XCTAssertEqual(revealedURLs, [existingFile.standardizedFileURL])
        XCTAssertEqual(unavailableCount, 2)
    }

    func testDownloadLifecycleUpdatesCoordinatorWhileDownloadsIsOpenAndSurvivesSnapshotDismissal() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "KeelBrowserDownloadLifecycleTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = try KeelStore(databaseURL: directory.appending(path: "Keel.sqlite3"))
        let coordinator = KeelCoordinator(store: store)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        var openedURLs: [URL] = []
        var stateChanges: [KeelCoordinatorState] = []
        let browser = KeelBrowserController(
            contentView: host,
            coordinator: coordinator,
            store: store,
            webViewFactory: { configuration in
                KeelWebViewFactory.make(configuration: configuration, websiteDataStore: .nonPersistent())
            },
            media: ImmediateMediaController(),
            uploadPresenter: EmptyUploadPresenter(),
            downloadDestinationDirectory: directory,
            openLocalFile: { openedURLs.append($0) }
        )
        browser.onStateChanged = { stateChanges.append($0) }

        browser.start()
        await browser.waitForIdleForTesting()
        browser.showManagement(.downloads)
        await browser.waitForIdleForTesting()

        let id = UUID()
        let started = KeelDownloadSnapshot(
            id: id,
            sourceHostname: "downloads.example",
            filename: "pending.pdf",
            receivedBytes: 12,
            state: .inProgress,
            createdAt: .now
        )
        browser.receiveDownloadLifecycleForTesting(.started(started))
        await browser.waitForIdleForTesting()

        let startedCoordinatorState = await coordinator.state()
        let startedState = try XCTUnwrap(startedCoordinatorState)
        XCTAssertEqual(startedState.surface, .management(.downloads))
        XCTAssertEqual(startedState.runtimeState.downloads.map(\.id), [id])
        XCTAssertEqual(startedState.runtimeState.downloads.first?.state, .inProgress)
        XCTAssertEqual(stateChanges.last?.runtimeState.downloads.map(\.id), [id])

        let destination = directory.appendingPathComponent("pending.pdf")
        try Data([1, 2, 3]).write(to: destination)
        let finished = KeelDownloadSnapshot(
            id: id,
            sourceHostname: started.sourceHostname,
            filename: started.filename,
            destinationURL: destination,
            receivedBytes: 3,
            state: .completed,
            createdAt: started.createdAt,
            completedAt: .now
        )
        browser.receiveDownloadLifecycleForTesting(.finished(finished))
        await browser.waitForIdleForTesting()
        let finishedCoordinatorState = await coordinator.state()
        XCTAssertEqual(finishedCoordinatorState?.runtimeState.downloads.first?.state, .completed)

        browser.dismissDownload(id: id)
        XCTAssertTrue(browser.downloads.isEmpty)
        let dismissedCoordinatorState = await coordinator.state()
        XCTAssertEqual(dismissedCoordinatorState?.runtimeState.downloads.map(\.id), [id])

        browser.handle(.openDownload(id: id))
        await browser.waitForIdleForTesting()
        XCTAssertEqual(openedURLs, [destination.standardizedFileURL])
    }

    func testDismissDownloadCannotDropAnInProgressSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "KeelBrowserActiveDownloadDismissTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = try KeelStore(databaseURL: directory.appending(path: "Keel.sqlite3"))
        let coordinator = KeelCoordinator(store: store)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let browser = KeelBrowserController(
            contentView: host,
            coordinator: coordinator,
            store: store,
            webViewFactory: { configuration in
                KeelWebViewFactory.make(configuration: configuration, websiteDataStore: .nonPersistent())
            },
            media: ImmediateMediaController(),
            uploadPresenter: EmptyUploadPresenter(),
            downloadDestinationDirectory: directory
        )

        browser.start()
        await browser.waitForIdleForTesting()
        let snapshot = KeelDownloadSnapshot(
            id: UUID(),
            sourceHostname: "downloads.example",
            filename: "pending.pdf",
            receivedBytes: 12,
            state: .inProgress,
            createdAt: .now
        )
        browser.receiveDownloadLifecycleForTesting(.started(snapshot))
        await browser.waitForIdleForTesting()

        browser.dismissDownload(id: snapshot.id)

        XCTAssertEqual(browser.downloads, [snapshot])
        let coordinatorState = await coordinator.state()
        XCTAssertEqual(coordinatorState?.runtimeState.downloads.map(\.id), [snapshot.id])
    }

    func testHomeContainsNoVisibleWebViewWhileRetainingAnActivePage() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "KeelBrowserControllerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = try KeelStore(databaseURL: directory.appending(path: "Keel.sqlite3"))
        let coordinator = KeelCoordinator(store: store)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let browser = KeelBrowserController(contentView: host, coordinator: coordinator, store: store)

        browser.start()
        await browser.waitForIdleForTesting()
        XCTAssertEqual(browser.liveWebViewCount, 0)
        XCTAssertFalse(containsWebView(host))

        browser.handle(.openTypedURL(try XCTUnwrap(URL(string: "https://example.invalid"))))
        await browser.waitForIdleForTesting()
        XCTAssertEqual(browser.liveWebViewCount, 1)
        XCTAssertTrue(containsWebView(host))

        browser.handle(.showHome)
        await browser.waitForIdleForTesting()
        XCTAssertEqual(browser.liveWebViewCount, 1)
        XCTAssertFalse(containsWebView(host))
    }

    func testCloseRetainsOneUndoViewAndRestoresItWithoutMakingAThirdView() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "KeelBrowserUndoTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = try KeelStore(databaseURL: directory.appending(path: "Keel.sqlite3"))
        let coordinator = KeelCoordinator(store: store)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let browser = KeelBrowserController(contentView: host, coordinator: coordinator, store: store)
        browser.start()
        await browser.waitForIdleForTesting()

        browser.handle(.openTypedURL(try XCTUnwrap(URL(string: "https://example.invalid/undo"))))
        await browser.waitForIdleForTesting()
        browser.closeActivePage()
        await browser.waitForIdleForTesting()

        XCTAssertEqual(browser.liveWebViewCount, 1)
        XCTAssertFalse(containsWebView(host))

        browser.handle(.restoreCloseUndo)
        await browser.waitForIdleForTesting()
        XCTAssertEqual(browser.liveWebViewCount, 1)
        XCTAssertTrue(containsWebView(host))
    }

    func testChromeCallbacksAndZoomFollowTheVisiblePage() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "KeelBrowserChromeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = try KeelStore(databaseURL: directory.appending(path: "Keel.sqlite3"))
        let coordinator = KeelCoordinator(store: store)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let browser = KeelBrowserController(contentView: host, coordinator: coordinator, store: store)
        var states: [KeelCoordinatorState] = []
        var availability: [KeelNavigationAvailability] = []
        browser.onStateChanged = { states.append($0) }
        browser.onNavigationAvailabilityChanged = { availability.append($0) }

        browser.start()
        await browser.waitForIdleForTesting()
        XCTAssertEqual(states.last?.surface, .home)
        XCTAssertEqual(availability.last, .unavailable)

        browser.handle(.openTypedURL(try XCTUnwrap(URL(string: "https://example.invalid/zoom"))))
        await browser.waitForIdleForTesting()
        XCTAssertEqual(states.last?.surface, .page)
        XCTAssertEqual(availability.last?.hasVisiblePage, true)

        for _ in 0 ..< 40 { _ = browser.increasePageZoom() }
        XCTAssertEqual(browser.pageZoom, 3)
        for _ in 0 ..< 40 { _ = browser.decreasePageZoom() }
        XCTAssertEqual(browser.pageZoom, 0.5)
        XCTAssertEqual(browser.resetPageZoom(), 1)

        browser.showHome()
        await browser.waitForIdleForTesting()
        XCTAssertEqual(availability.last, .unavailable)
    }

    func testUnavailableBackDoesNotCreateACommandedNavigation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "KeelBrowserUnavailableBackTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = try KeelStore(databaseURL: directory.appending(path: "Keel.sqlite3"))
        let coordinator = KeelCoordinator(store: store)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let browser = KeelBrowserController(contentView: host, coordinator: coordinator, store: store)
        browser.start()
        await browser.waitForIdleForTesting()
        browser.handle(.openTypedURL(try XCTUnwrap(URL(string: "https://example.invalid/no-back"))))
        await browser.waitForIdleForTesting()

        let beforeState = await coordinator.state()
        let before = try XCTUnwrap(beforeState?.activePage?.currentNavigationID)
        browser.goBack()
        await browser.waitForIdleForTesting()
        let afterState = await coordinator.state()
        let after = try XCTUnwrap(afterState?.activePage?.currentNavigationID)

        XCTAssertEqual(after, before)
    }

    func testUndoExpiryDiscardsTheRetainedViewAtItsCoordinatorDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "KeelBrowserUndoExpiryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let closedAt = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let coordinatorClock = DeadlineTestClock(closedAt)
        let store = try KeelStore(databaseURL: directory.appending(path: "Keel.sqlite3"))
        let coordinator = KeelCoordinator(store: store, now: coordinatorClock.read, makeID: UUID.init)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let browser = KeelBrowserController(
            contentView: host,
            coordinator: coordinator,
            store: store,
            webViewFactory: { configuration in
                KeelWebViewFactory.make(configuration: configuration, websiteDataStore: .nonPersistent())
            },
            media: ImmediateMediaController(),
            uploadPresenter: EmptyUploadPresenter(),
            now: { closedAt.addingTimeInterval(86_400) }
        )

        browser.start()
        await browser.waitForIdleForTesting()
        browser.handle(.openTypedURL(try XCTUnwrap(URL(string: "https://example.invalid/expiry"))))
        await browser.waitForIdleForTesting()
        coordinatorClock.advanceAfterNextRead(to: closedAt.addingTimeInterval(86_400))
        browser.closeActivePage()

        for _ in 0 ..< 10 {
            await Task.yield()
            await browser.waitForIdleForTesting()
        }

        let stateAfterExpiry = await coordinator.state()
        XCTAssertNil(stateAfterExpiry?.undoPage)
        XCTAssertEqual(browser.liveWebViewCount, 0)
    }

    func testDetourEscapeDecisionBlursEditorsBeforeClosingTheDetour() {
        XCTAssertEqual(
            KeelBrowserController.detourEscapeAction(activeElementIsEditable: true),
            .blurFocusedEditor
        )
        XCTAssertEqual(
            KeelBrowserController.detourEscapeAction(activeElementIsEditable: false),
            .closeDetour
        )
    }

    func testExternalFormSubmissionKeepsExplicitUserActivationAndAvoidsAutomaticSuppression() throws {
        XCTAssertEqual(
            KeelBrowserController.externalApplicationTrigger(for: .formSubmitted),
            .userActivatedPage
        )
        XCTAssertEqual(
            KeelBrowserController.externalApplicationTrigger(for: .formResubmitted),
            .automaticPage
        )

        let url = try XCTUnwrap(URL(string: "mailto:orders@example.com"))
        let source = try XCTUnwrap(URL(string: "https://shop.example/checkout"))
        let decision = KeelNavigationPolicy.decision(
            for: KeelNavigationRequest(
                url: url,
                sourceURL: source,
                externalApplicationTrigger: KeelBrowserController.externalApplicationTrigger(for: .formSubmitted),
                sourcePageID: UUID()
            )
        )
        guard case let .requestExternalApplicationApproval(approval) = decision else {
            return XCTFail("Expected external application approval")
        }
        XCTAssertEqual(approval.trigger, .userActivatedPage)
        XCTAssertNotNil(approval.sourcePageID)
    }

    func testDetourPresentationIdentityRejectsStaleDismissalBeforeRestoringParent() {
        let detourID = UUID()
        let parentPageID = UUID()
        let identity = KeelDetourPresentationIdentity(detourID: detourID, parentPageID: parentPageID)

        XCTAssertTrue(identity.matchesDismissal(.init(id: detourID, parentPageID: parentPageID, url: URL(string: "https://checkout.example")!)))
        XCTAssertFalse(identity.matchesDismissal(.init(id: UUID(), parentPageID: parentPageID, url: URL(string: "https://checkout.example")!)))
        XCTAssertFalse(identity.matchesDismissal(.init(id: detourID, parentPageID: UUID(), url: URL(string: "https://checkout.example")!)))
    }

    func testImmediateDetourCloseConsumesOneResumeAndRejectsLatePresentation() {
        let detourID = UUID()
        var tracker = KeelDetourSuspensionTracker()
        tracker.begin(detourID)

        XCTAssertTrue(tracker.allowsPresentation(detourID))
        XCTAssertTrue(tracker.consumeResume(detourID))
        XCTAssertFalse(tracker.allowsPresentation(detourID))
        XCTAssertFalse(tracker.consumeResume(detourID))
    }

    func testDelayedActivationReplaysLatestNavigationInsteadOfCapturedURL() {
        let pageID = UUID()
        let stale = KeelPendingNavigation(
            navigationID: UUID(),
            url: URL(string: "https://example.invalid/first")!,
            source: .typedAddress
        )
        let latest = KeelPendingNavigation(
            navigationID: UUID(),
            url: URL(string: "https://example.invalid/latest")!,
            source: .link
        )
        var queue = KeelDelayedNavigationQueue()
        queue.replace(pageID: pageID, with: stale)
        queue.replace(pageID: pageID, with: latest)

        XCTAssertEqual(queue.take(pageID: pageID), latest)
        XCTAssertNil(queue.take(pageID: pageID))
    }

    func testReloadBindingUpdatesThePriorHistoryVisitAfterTheTailSettles() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "KeelBrowserReloadHistoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = try KeelStore(databaseURL: directory.appending(path: "Keel.sqlite3"))
        let session = BrowsingSession(id: UUID(), startedAt: .now)
        _ = try await store.apply([.upsertSession(session)])
        let context = PageContext(pageID: UUID(), sessionID: session.id, detourID: nil)
        let initialNavigationID = UUID()
        let initialURL = try XCTUnwrap(URL(string: "https://reload.example/initial"))
        let initial = try await store.recordHistoryVisit(
            HistoryVisitEvent(url: initialURL, visitedAt: .now, browsingSessionID: session.id, source: .link)
        )
        context.visitIDs[initialNavigationID] = initial.id

        let reload = NavigationBinding(
            pageID: context.pageID,
            navigationID: UUID(),
            source: .link,
            kind: .reload,
            detourID: nil,
            currentVisitNavigationID: initialNavigationID
        )
        let currentVisitID = try XCTUnwrap(
            reload.currentVisitNavigationID.flatMap { context.visitIDs[$0] }
        )
        let reloadedURL = try XCTUnwrap(URL(string: "https://reload.example/after"))
        _ = try await store.recordHistoryVisit(
            HistoryVisitEvent(
                url: reloadedURL,
                visitedAt: .now,
                browsingSessionID: session.id,
                navigationKind: .reload,
                source: .link,
                currentVisitID: currentVisitID
            )
        )

        let visits = try await store.historyVisits(in: session.id)
        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits.first?.id, initial.id)
        XCTAssertEqual(visits.first?.url, reloadedURL)
        XCTAssertEqual(visits.first?.navigationKind, .reload)
    }

    private func containsWebView(_ view: NSView) -> Bool {
        view is WKWebView || view.subviews.contains(where: containsWebView)
    }
}

private final class DeadlineTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    private var nextDate: Date?

    init(_ date: Date) {
        self.date = date
    }

    func advanceAfterNextRead(to date: Date) {
        lock.withLock { nextDate = date }
    }

    func read() -> Date {
        lock.withLock {
            defer {
                if let nextDate {
                    date = nextDate
                    self.nextDate = nil
                }
            }
            return date
        }
    }
}

@MainActor
private final class ImmediateMediaController: KeelMediaControlling {
    func pauseBeforeDetour(in webView: WKWebView, performDetour: @escaping @MainActor @Sendable () -> Void) {
        performDetour()
    }

    func pauseBeforeDiscard(in webView: WKWebView, performDiscard: @escaping @MainActor @Sendable () -> Void) {
        performDiscard()
    }

    func resumeAfterDetour(in webView: WKWebView, completion: (@MainActor @Sendable () -> Void)?) {
        completion?()
    }
}

@MainActor
private final class EmptyUploadPresenter: KeelUploadPresenting {
    func present(
        parameters: WKOpenPanelParameters,
        in window: NSWindow?,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        completionHandler(nil)
    }
}
