@testable import KeelCoordinator
@testable import KeelStore
import Foundation
import KeelFoundation
import Testing

@Suite("Keel coordinator")
struct KeelCoordinatorTests {
    @Test("capture receipts report durable insertion and duplicates without moving the active page")
    func durableCaptureReceipts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let faults = StoreFaultControl()
        let store = try fixture.store(clock: clock, faultInjector: faults.inject)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let url = URL(string: "https://capture.example/path")!
        let opened = try await coordinator.handle(.openTypedURL(URL(string: "https://active.example")!))
        let added = try await coordinator.handle(.addURLToQueue(url))
        #expect(added.effects == [.captureReceipt(url: url, added: true)])
        #expect(added.state?.activePage == opened.state?.activePage)
        let repeated = try await coordinator.handle(.addURLToQueue(url))
        #expect(repeated.effects == [.captureReceipt(url: url, added: false)])
        #expect(repeated.state?.runtimeState.queue == added.state?.runtimeState.queue)
        let before = await coordinator.state()
        faults.failingChangeIndex = 0
        await #expect(throws: CoordinatorStoreFault.injected) {
            try await coordinator.handle(.addURLToQueue(URL(string: "https://failed.example")!))
        }
        #expect(await coordinator.state() == before)
    }

    @Test("failed resume fallback preserves original URL exactly once before target load", arguments: [false, true])
    func resumeFallbackPreservesDestination(alreadyQueued: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let original = URL(string: "https://unfinished.example/form")!
        let waiting = URL(string: "https://waiting.example")!
        let target = URL(string: "https://requested.example")!
        let session = BrowsingSession(id: UUID(), startedAt: clock.value)
        let checkpoint = ResumeCheckpoint(url: original, sessionID: session.id, savedAt: clock.value)
        _ = try await store.apply([.upsertSession(session), .replaceResumeCheckpoint(checkpoint), .captureQueuedDestination(waiting)])
        if alreadyQueued { _ = try await store.apply([.captureQueuedDestination(original)]) }
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let opened = try await coordinator.handle(.openTypedURL(target))
        let page = try #require(opened.state?.activePage)
        let before = await coordinator.state()
        for event in [
            KeelCoordinatorEvent.preserveFailedResumeBeforeOpen(pageID: UUID(), navigationID: page.currentNavigationID, checkpoint: checkpoint),
            .preserveFailedResumeBeforeOpen(pageID: page.id, navigationID: UUID(), checkpoint: checkpoint),
            .preserveFailedResumeBeforeOpen(pageID: page.id, navigationID: page.currentNavigationID, checkpoint: ResumeCheckpoint(url: original, sessionID: session.id, savedAt: clock.value.addingTimeInterval(1))),
        ] {
            #expect(try await coordinator.handle(event).disposition == .ignored)
            #expect(await coordinator.state() == before)
        }
        let event = KeelCoordinatorEvent.preserveFailedResumeBeforeOpen(pageID: page.id, navigationID: page.currentNavigationID, checkpoint: checkpoint)
        let result = try await coordinator.handle(event)
        #expect(result.disposition == .applied)
        #expect(result.state?.activePage == page)
        #expect(result.state?.runtimeState.activeSession == session)
        #expect(result.state?.runtimeState.resumeCheckpoint == nil)
        #expect(result.state?.runtimeState.queue.map(\.url) == (alreadyQueued ? [waiting, original] : [original, waiting]))
        #expect(result.effects.isEmpty)
        #expect(try await coordinator.handle(event).disposition == .ignored)
    }

    @Test("failed resume fallback transaction retains checkpoint and queue", arguments: [0, 1])
    func resumeFallbackRollback(failingChange: Int) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let faults = StoreFaultControl()
        let store = try fixture.store(clock: clock, faultInjector: faults.inject)
        let session = BrowsingSession(id: UUID(), startedAt: clock.value)
        let checkpoint = ResumeCheckpoint(url: URL(string: "https://unfinished.example")!, sessionID: session.id, savedAt: clock.value)
        _ = try await store.apply([.upsertSession(session), .replaceResumeCheckpoint(checkpoint), .captureQueuedDestination(URL(string: "https://waiting.example")!)])
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let result = try await coordinator.handle(.openTypedURL(URL(string: "https://requested.example")!))
        let page = try #require(result.state?.activePage)
        let before = await coordinator.state()
        faults.failingChangeIndex = failingChange
        await #expect(throws: CoordinatorStoreFault.injected) {
            _ = try await coordinator.handle(.preserveFailedResumeBeforeOpen(pageID: page.id, navigationID: page.currentNavigationID, checkpoint: checkpoint))
        }
        #expect(await coordinator.state() == before)
        #expect(try await store.runtimeState() == before?.runtimeState)
    }

    @Test("explicit Open and enqueue preserve intent across Home and active states", arguments: ["empty", "queued", "resume", "parked", "active"], ["typed", "suggestion", "history", "enqueue", "suggestionQueue", "external"])
    func explicitIntentMatrix(surface: String, action: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let target = URL(string: "https://selected.example/destination")!
        let original = URL(string: "https://unfinished.example/form")!
        let queued = URL(string: "https://waiting.example/first")!
        let suggestion = try await recordSuggestion(url: target, input: "selected", store: store, clock: clock)
        let sessionID = UUID()
        let checkpoint = ResumeCheckpoint(url: original, sessionID: sessionID, savedAt: clock.value, interactionState: Data([7, 9]))
        if surface == "resume" {
            _ = try await store.apply([.upsertSession(BrowsingSession(id: sessionID, startedAt: clock.value, hostname: original.host)), .replaceResumeCheckpoint(checkpoint)])
        }
        if surface != "empty" {
            _ = try await store.apply([.captureQueuedDestination(queued)])
        }
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        if surface == "active" || surface == "parked" {
            _ = try await coordinator.handle(.openTypedURL(original))
            if surface == "parked" { _ = try await coordinator.handle(.showHome) }
        }
        let before = try #require(await coordinator.state())
        let result: KeelCoordinatorResult
        switch action {
        case "typed": result = try await coordinator.handle(.openTypedURL(target))
        case "history": result = try await coordinator.handle(.openHistoryURL(target))
        case "suggestion": result = try await coordinator.handle(.selectHistorySuggestion(historyURLID: suggestion.historyURLID, typedInput: "selected", disposition: .open))
        case "enqueue": result = try await coordinator.handle(.addURLToQueue(target))
        case "suggestionQueue": result = try await coordinator.handle(.selectHistorySuggestion(historyURLID: suggestion.historyURLID, typedInput: "selected", disposition: .enqueue))
        default: result = try await coordinator.handle(.receiveExternalURL(target))
        }
        let after = try #require(result.state)
        let queues = action == "enqueue" || action == "suggestionQueue" || action == "external" && surface != "empty"
        if queues {
            #expect(after.activePage == before.activePage)
            #expect(after.surface == before.surface)
            #expect(after.runtimeState.queue.map(\.url) == before.runtimeState.queue.map(\.url) + [target])
        } else {
            #expect(after.surface == .page)
            #expect(after.activePage?.url == target)
            #expect(after.runtimeState.queue == before.runtimeState.queue)
            if let originalPage = before.activePage {
                #expect(after.activePage?.id == originalPage.id)
                #expect(after.activePage?.sessionID == originalPage.sessionID)
            }
            if surface == "resume" {
                let page = try #require(after.activePage)
                #expect(page.sessionID == sessionID)
                let source: HistoryVisitSource = action == "typed" ? .typedAddress : action == "history" ? .history : .suggestion
                #expect(result.effects == [.restorePageThenNavigate(page: page, checkpoint: checkpoint, source: source), .showActivePage(page)])
            }
        }
        #expect(after.runtimeState.resumeCheckpoint == before.runtimeState.resumeCheckpoint)
    }

    @Test("failed resume suggestion choice preserves checkpoint, FIFO and Home")
    func failedResumeOpenRollsBack() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let faults = StoreFaultControl()
        let store = try fixture.store(clock: clock, faultInjector: faults.inject)
        let target = URL(string: "https://selected.example/destination")!
        let suggestion = try await recordSuggestion(url: target, input: "selected", store: store, clock: clock)
        let sessionID = UUID()
        _ = try await store.apply([
            .upsertSession(BrowsingSession(id: sessionID, startedAt: clock.value)),
            .replaceResumeCheckpoint(ResumeCheckpoint(url: URL(string: "https://unfinished.example")!, sessionID: sessionID, savedAt: clock.value, interactionState: Data([1]))),
            .captureQueuedDestination(URL(string: "https://queued.example")!),
        ])
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let before = await coordinator.state()
        faults.failingChangeIndex = 0
        await #expect(throws: CoordinatorStoreFault.injected) {
            _ = try await coordinator.handle(.selectHistorySuggestion(historyURLID: suggestion.historyURLID, typedInput: "selected", disposition: .open))
        }
        #expect(await coordinator.state() == before)
        #expect(try await store.runtimeState() == before?.runtimeState)
    }

    @Test("launch shows Home, removes persisted close Undo, and keeps Queue plus resume")
    func launchClearsOnlyCloseUndo() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let queued = try #require(URL(string: "https://queued.example"))
        let resumeURL = try #require(URL(string: "https://resume.example"))
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        _ = try await store.apply([
            .captureQueuedDestination(queued),
            .upsertSession(BrowsingSession(id: sessionID, startedAt: clock.value, hostname: "resume.example")),
            .replaceResumeCheckpoint(ResumeCheckpoint(url: resumeURL, sessionID: sessionID, savedAt: clock.value)),
            .replaceCloseUndo(CloseUndoRecord(url: resumeURL, sessionID: sessionID, closedAt: clock.value, deadline: clock.value.addingTimeInterval(600))),
        ])

        let coordinator = coordinator(store: store, clock: clock)
        let result = try await coordinator.start()

        #expect(result.disposition == .applied)
        #expect(result.effects == [.showHome])
        #expect(result.state?.surface == .home)
        #expect(result.state?.activePage == nil)
        #expect(result.state?.runtimeState.queue.map(\.url) == [queued])
        #expect(result.state?.runtimeState.resumeCheckpoint?.url == resumeURL)
        #expect(result.state?.runtimeState.closeUndo == nil)
    }

    @Test("launch reconciles persisted in-progress downloads before publishing Home")
    func launchReconcilesPersistedDownloads() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let id = UUID()
        let persisted = DownloadRecord(
            id: id,
            hostname: "downloads.example",
            filename: "pending.pdf",
            byteCount: 128,
            state: .inProgress,
            createdAt: clock.value
        )
        _ = try await store.apply([.updateDownload(persisted)])

        clock.value = clock.value.addingTimeInterval(5)
        let coordinator = coordinator(store: store, clock: clock)
        let result = try await coordinator.start()

        let expected = DownloadRecord(
            id: persisted.id,
            hostname: persisted.hostname,
            filename: persisted.filename,
            pathReference: persisted.pathReference,
            byteCount: persisted.byteCount,
            state: .failed,
            createdAt: persisted.createdAt,
            completedAt: clock.value,
            errorCode: KeelDownloadErrorCode.interruptedAfterRestart
        )
        #expect(result.effects == [.showHome])
        #expect(result.state?.runtimeState.downloads == [expected])
        #expect(try await store.runtimeState().downloads == [expected])
    }

    @Test("Home covers and returns to the same active page without store writes")
    func homeCoverDoesNotSuspendOrQueue() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let url = try #require(URL(string: "https://active.example"))
        let opened = try await coordinator.handle(.openTypedURL(url))
        let page = try #require(opened.state?.activePage)

        let home = try await coordinator.handle(.showHome)
        let returned = try await coordinator.handle(.returnToActivePage)

        #expect(home.state?.isHomeCoveringActivePage == true)
        #expect(home.state?.activePage == page)
        #expect(home.state?.runtimeState.queue.isEmpty == true)
        #expect(returned.state?.surface == .page)
        #expect(returned.state?.activePage == page)
        #expect(returned.effects == [.showActivePage(page)])

        let typedURL = try #require(URL(string: "https://typed.example"))
        let typedNavigation = try await coordinator.handle(.openTypedURL(typedURL))
        let typedPage = try #require(typedNavigation.state?.activePage)
        #expect(typedNavigation.effects == [.navigateActivePage(pageID: page.id, navigationID: typedPage.currentNavigationID, to: typedURL, source: .typedAddress)])
        let linkedURL = try #require(URL(string: "https://linked.example"))
        let linkNavigation = try await coordinator.handle(.navigated(pageID: page.id, navigationID: typedPage.currentNavigationID, to: linkedURL))
        #expect(linkNavigation.state?.activePage?.url == linkedURL)
        #expect(linkNavigation.effects.isEmpty)
    }

    @Test("closing consumes FIFO, ends the old session, and retains one close Undo")
    func closeAdvancesFIFOAndRetainsUndo() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let first = try #require(URL(string: "https://first.example"))
        let second = try #require(URL(string: "https://second.example"))
        let third = try #require(URL(string: "https://third.example"))
        let opened = try await coordinator.handle(.openTypedURL(first))
        let firstPage = try #require(opened.state?.activePage)
        #expect(opened.effects.first == .activatePage(firstPage, source: .typedAddress, interactionState: nil))
        _ = try await coordinator.handle(.addURLToQueue(second))
        _ = try await coordinator.handle(.addURLToQueue(third))

        let closed = try await coordinator.handle(.closePage(pageID: firstPage.id))
        let nextPage = try #require(closed.state?.activePage)
        let undo = try #require(closed.state?.undoPage)

        #expect(nextPage.url == second)
        #expect(closed.effects.contains(.finishReceipt(nextURL: second)))
        #expect(closed.state?.runtimeState.queue.map(\.url) == [third])
        #expect(undo.page == firstPage)
        #expect(closed.state?.runtimeState.closeUndo?.url == first)
        #expect(closed.state?.runtimeState.activeSession?.id == nextPage.sessionID)
        #expect(closed.effects.contains(.retainClosedPageForUndo(undo, keepsLiveWebView: true)))
        #expect(closed.effects.contains(.activatePage(nextPage, source: .queueConsumption, interactionState: nil)))
    }

    @Test("concurrent closes serialize so only one consumes FIFO")
    func concurrentClosesConsumeOneDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let first = try #require(URL(string: "https://first.example"))
        let second = try #require(URL(string: "https://second.example"))
        let third = try #require(URL(string: "https://third.example"))
        let opened = try await coordinator.handle(.openTypedURL(first))
        let page = try #require(opened.state?.activePage)
        _ = try await coordinator.handle(.addURLToQueue(second))
        _ = try await coordinator.handle(.addURLToQueue(third))

        async let firstClose = coordinator.handle(.closePage(pageID: page.id))
        async let secondClose = coordinator.handle(.closePage(pageID: page.id))
        let results = try await [firstClose, secondClose]

        #expect(results.filter { $0.disposition == .applied }.count == 1)
        #expect(results.filter { $0.disposition == .ignored }.count == 1)
        #expect(results.flatMap(\.effects).filter {
            if case .activatePage = $0 { return true }
            return false
        }.count == 1)
        let state = try #require(await coordinator.state())
        #expect(state.activePage?.url == second)
        #expect(state.runtimeState.queue.map(\.url) == [third])
    }

    @Test("closing with the low-memory setting asks the adapter not to retain a live web view")
    func closeRespectsLowMemoryUndoSetting() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        _ = try await store.apply([.replaceSettings(KeelSettings(keepsClosedPageReady: false))])
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let url = try #require(URL(string: "https://active.example"))
        let opened = try await coordinator.handle(.openTypedURL(url))
        let page = try #require(opened.state?.activePage)

        let closed = try await coordinator.handle(.closePage(pageID: page.id))
        let undo = try #require(closed.state?.undoPage)

        #expect(closed.effects.contains(.retainClosedPageForUndo(undo, keepsLiveWebView: false)))
    }

    @Test("a newer close discards the previous in-memory Undo page")
    func laterCloseReplacesUndo() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let first = try #require(URL(string: "https://first.example"))
        let second = try #require(URL(string: "https://second.example"))
        let third = try #require(URL(string: "https://third.example"))
        let opened = try await coordinator.handle(.openTypedURL(first))
        let firstPage = try #require(opened.state?.activePage)
        _ = try await coordinator.handle(.addURLToQueue(second))
        _ = try await coordinator.handle(.addURLToQueue(third))
        let firstClose = try await coordinator.handle(.closePage(pageID: firstPage.id))
        let firstUndo = try #require(firstClose.state?.undoPage)
        let secondPage = try #require(firstClose.state?.activePage)

        let secondClose = try await coordinator.handle(.closePage(pageID: secondPage.id))

        #expect(secondClose.effects.first == .discardUndoPage(firstUndo))
        #expect(secondClose.state?.undoPage?.page == secondPage)
        #expect(secondClose.state?.runtimeState.closeUndo?.url == second)
    }

    @Test("close Undo expires once and removes its retained page")
    func closeUndoExpires() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let first = try #require(URL(string: "https://first.example"))
        let opened = try await coordinator.handle(.openTypedURL(first))
        let page = try #require(opened.state?.activePage)
        let closed = try await coordinator.handle(.closePage(pageID: page.id))
        let undo = try #require(closed.state?.undoPage)
        clock.value = undo.deadline

        let expired = try await coordinator.handle(.closeUndoExpired(pageID: undo.page.id, deadline: undo.deadline))

        #expect(expired.state?.undoPage == nil)
        #expect(expired.state?.runtimeState.closeUndo == nil)
        #expect(expired.effects == [.discardUndoPage(undo)])
        let repeated = try await coordinator.handle(.closeUndoExpired(pageID: undo.page.id, deadline: undo.deadline))
        #expect(repeated.disposition == .ignored)
    }

    @Test("a stale close-Undo timer cannot discard a later Undo with the same deadline")
    func staleCloseUndoTimerIsIgnored() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let first = try #require(URL(string: "https://first.example"))
        let second = try #require(URL(string: "https://second.example"))
        let third = try #require(URL(string: "https://third.example"))
        let opened = try await coordinator.handle(.openTypedURL(first))
        let firstPage = try #require(opened.state?.activePage)
        _ = try await coordinator.handle(.addURLToQueue(second))
        _ = try await coordinator.handle(.addURLToQueue(third))
        let firstClose = try await coordinator.handle(.closePage(pageID: firstPage.id))
        let firstUndo = try #require(firstClose.state?.undoPage)
        let secondPage = try #require(firstClose.state?.activePage)
        let secondClose = try await coordinator.handle(.closePage(pageID: secondPage.id))
        let secondUndo = try #require(secondClose.state?.undoPage)
        #expect(firstUndo.deadline == secondUndo.deadline)

        clock.value = firstUndo.deadline
        let stale = try await coordinator.handle(.closeUndoExpired(pageID: firstUndo.page.id, deadline: firstUndo.deadline))

        #expect(stale.disposition == .ignored)
        #expect(stale.state?.undoPage == secondUndo)
        let fresh = try await coordinator.handle(.closeUndoExpired(pageID: secondUndo.page.id, deadline: secondUndo.deadline))
        #expect(fresh.effects == [.discardUndoPage(secondUndo)])
    }

    @Test("restoring Undo puts a newer active URL ahead of the FIFO Queue and consumes Undo")
    func restoreUndoPrependsNewerActivePage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let first = try #require(URL(string: "https://first.example"))
        let second = try #require(URL(string: "https://second.example"))
        let third = try #require(URL(string: "https://third.example"))
        let opened = try await coordinator.handle(.openTypedURL(first))
        let firstPage = try #require(opened.state?.activePage)
        _ = try await coordinator.handle(.addURLToQueue(second))
        _ = try await coordinator.handle(.addURLToQueue(third))
        let closed = try await coordinator.handle(.closePage(pageID: firstPage.id))
        let secondPage = try #require(closed.state?.activePage)
        let undo = try #require(closed.state?.undoPage)

        let restored = try await coordinator.handle(.restoreCloseUndo)

        #expect(restored.state?.activePage == firstPage)
        #expect(restored.state?.runtimeState.queue.map(\.url) == [second, third])
        #expect(restored.state?.undoPage == nil)
        #expect(restored.state?.runtimeState.closeUndo == nil)
        #expect(restored.state?.runtimeState.activeSession?.id == firstPage.sessionID)
        #expect(restored.state?.runtimeState.resumeCheckpoint?.url == first)
        #expect(Array(restored.effects.prefix(2)) == [.discardActivePage(secondPage), .restoreUndoPage(undo)])
    }

    @Test("a technical failure keeps the active position and Queue untouched")
    func technicalFailureDoesNotAdvanceQueue() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let active = try #require(URL(string: "https://active.example"))
        let queued = try #require(URL(string: "https://queued.example"))
        let opened = try await coordinator.handle(.openTypedURL(active))
        let page = try #require(opened.state?.activePage)
        _ = try await coordinator.handle(.addURLToQueue(queued))

        let failed = try await coordinator.handle(.technicalFailure(pageID: page.id, navigationID: page.currentNavigationID))

        #expect(failed.state?.activePage?.status == .technicalFailure)
        #expect(failed.state?.activePage?.url == active)
        #expect(failed.state?.runtimeState.queue.map(\.url) == [queued])
        #expect(failed.effects.isEmpty)
    }

    @Test("older callbacks cannot overwrite a newer navigation on the same page")
    func staleNavigationCallbacksAreIgnored() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let originalURL = try #require(URL(string: "https://original.example"))
        let freshURL = try #require(URL(string: "https://fresh.example"))
        let opened = try await coordinator.handle(.openTypedURL(originalURL))
        let page = try #require(opened.state?.activePage)
        let oldNavigationID = page.currentNavigationID
        let newNavigationID = UUID()

        let started = try await coordinator.handle(.navigationStarted(
            pageID: page.id,
            replacingNavigationID: oldNavigationID,
            navigationID: newNavigationID
        ))
        #expect(started.state?.activePage?.currentNavigationID == newNavigationID)
        let staleNavigation = try await coordinator.handle(.navigated(pageID: page.id, navigationID: oldNavigationID, to: originalURL))
        let staleFailure = try await coordinator.handle(.technicalFailure(pageID: page.id, navigationID: oldNavigationID))
        let staleCheckpoint = try await coordinator.handle(.saveResumeCheckpoint(pageID: page.id, navigationID: oldNavigationID, interactionState: Data([9])))

        #expect(staleNavigation.disposition == .ignored)
        #expect(staleFailure.disposition == .ignored)
        #expect(staleCheckpoint.disposition == .ignored)
        #expect(staleCheckpoint.state?.runtimeState.resumeCheckpoint == nil)

        let currentNavigation = try await coordinator.handle(.navigated(pageID: page.id, navigationID: newNavigationID, to: freshURL))
        #expect(currentNavigation.disposition == .applied)
        #expect(currentNavigation.state?.activePage?.url == freshURL)
        let currentCheckpoint = try await coordinator.handle(.saveResumeCheckpoint(pageID: page.id, navigationID: newNavigationID, interactionState: Data([1])))
        #expect(currentCheckpoint.disposition == .applied)
        #expect(currentCheckpoint.state?.runtimeState.resumeCheckpoint?.url == freshURL)
    }

    @Test("a stale navigation start cannot replace a newer coordinator-issued navigation")
    func staleNavigationStartIsIgnored() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let firstURL = try #require(URL(string: "https://first.example"))
        let newerURL = try #require(URL(string: "https://newer.example"))
        let opened = try await coordinator.handle(.openTypedURL(firstURL))
        let firstPage = try #require(opened.state?.activePage)
        let originalNavigationID = firstPage.currentNavigationID

        let issued = try await coordinator.handle(.openTypedURL(newerURL))
        let newerPage = try #require(issued.state?.activePage)
        #expect(newerPage.currentNavigationID != originalNavigationID)
        let staleStart = try await coordinator.handle(.navigationStarted(
            pageID: firstPage.id,
            replacingNavigationID: originalNavigationID,
            navigationID: UUID()
        ))

        #expect(staleStart.disposition == .ignored)
        #expect(staleStart.state?.activePage == newerPage)
        #expect(staleStart.effects.isEmpty)
    }

    @Test("requeue and close appends the current URL, then advances without retaining Undo")
    func requeueAndCloseAppendsThenAdvances() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let active = try #require(URL(string: "https://active.example"))
        let queued = try #require(URL(string: "https://queued.example"))
        let opened = try await coordinator.handle(.openTypedURL(active))
        let page = try #require(opened.state?.activePage)
        _ = try await coordinator.handle(.addURLToQueue(queued))

        let result = try await coordinator.handle(.requeueAndClose(pageID: page.id))

        #expect(result.state?.activePage?.url == queued)
        #expect(result.state?.runtimeState.queue.map(\.url) == [active])
        #expect(result.state?.undoPage == nil)
        #expect(result.state?.runtimeState.closeUndo == nil)
        let nextPage = try #require(result.state?.activePage)
        #expect(result.effects.contains(.activatePage(nextPage, source: .queueConsumption, interactionState: nil)))
    }

    @Test("resume restores the saved session, while requeueing resume advances FIFO in one action")
    func resumeAndRequeueResume() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let resumeURL = try #require(URL(string: "https://resume.example"))
        let queuedURL = try #require(URL(string: "https://queued.example"))
        let resumeSession = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        _ = try await store.apply([
            .upsertSession(BrowsingSession(id: resumeSession, startedAt: clock.value, hostname: "resume.example")),
            .replaceResumeCheckpoint(ResumeCheckpoint(url: resumeURL, sessionID: resumeSession, savedAt: clock.value, interactionState: Data([1]))),
            .captureQueuedDestination(queuedURL),
        ])
        let requeueCoordinator = coordinator(store: store, clock: clock)
        _ = try await requeueCoordinator.start()

        let requeued = try await requeueCoordinator.handle(.requeueResumeAndOpenNext)
        #expect(requeued.state?.activePage?.url == queuedURL)
        #expect(requeued.state?.runtimeState.resumeCheckpoint == nil)
        #expect(requeued.state?.runtimeState.queue.map(\.url) == [resumeURL])
        let requeuedPage = try #require(requeued.state?.activePage)
        #expect(requeued.effects.first == .activatePage(requeuedPage, source: .queueConsumption, interactionState: nil))

        let secondFixture = try Fixture()
        defer { secondFixture.remove() }
        let secondStore = try secondFixture.store(clock: clock)
        _ = try await secondStore.apply([
            .upsertSession(BrowsingSession(id: resumeSession, startedAt: clock.value, hostname: "resume.example")),
            .replaceResumeCheckpoint(ResumeCheckpoint(url: resumeURL, sessionID: resumeSession, savedAt: clock.value, interactionState: Data([7]))),
        ])
        let secondCoordinator = coordinator(store: secondStore, clock: clock)
        _ = try await secondCoordinator.start()
        let resumed = try await secondCoordinator.handle(.resumeCheckpoint)
        #expect(resumed.state?.activePage?.url == resumeURL)
        #expect(resumed.state?.activePage?.sessionID == resumeSession)
        #expect(resumed.state?.runtimeState.resumeCheckpoint == nil)
        let resumedPage = try #require(resumed.state?.activePage)
        #expect(resumed.effects.first == .activatePage(resumedPage, source: .resume, interactionState: Data([7])))
    }

    @Test("resume ignores a checkpoint whose session is not the active stored session, but discard clears it")
    func resumeIgnoresMismatchedSession() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let resumeURL = try #require(URL(string: "https://resume.example"))
        _ = try await store.apply([
            .upsertSession(BrowsingSession(id: UUID(), startedAt: clock.value, hostname: "other.example")),
            .replaceResumeCheckpoint(ResumeCheckpoint(url: resumeURL, sessionID: UUID(), savedAt: clock.value)),
        ])
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()

        let result = try await coordinator.handle(.resumeCheckpoint)

        #expect(result.disposition == .ignored)
        #expect(result.state?.surface == .home)
        #expect(result.state?.activePage == nil)
        #expect(result.state?.runtimeState.resumeCheckpoint?.url == resumeURL)

        let discarded = try await coordinator.handle(.discardResumeCheckpoint)
        #expect(discarded.disposition == .applied)
        #expect(discarded.state?.runtimeState.resumeCheckpoint == nil)
        clock.value = clock.value.addingTimeInterval(1)
        let usableURL = try #require(URL(string: "https://usable.example"))
        let opened = try await coordinator.handle(.openTypedURL(usableURL))
        #expect(opened.state?.activePage?.url == usableURL)
    }

    @Test("explicit typed Open preserves queued work and external URLs append")
    func homeDefersURLsBehindResumeOrQueue() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let queued = try #require(URL(string: "https://queued.example"))
        let typed = try #require(URL(string: "https://typed.example"))
        let external = try #require(URL(string: "https://external.example"))
        _ = try await store.apply([.captureQueuedDestination(queued)])
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()

        let typedResult = try await coordinator.handle(.openTypedURL(typed))
        let externalResult = try await coordinator.handle(.receiveExternalURL(external))

        #expect(typedResult.state?.surface == .page)
        #expect(externalResult.state?.runtimeState.queue.map(\.url) == [queued, external])
        #expect(externalResult.effects == [.captureReceipt(url: external, added: true)])
    }

    @Test("opening queued work stays on Home when Store prunes every expired destination")
    func openingExpiredQueueRefreshesHomeState() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let queued = try #require(URL(string: "https://expired.example"))
        _ = try await store.apply([.captureQueuedDestination(queued)])
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        clock.value = clock.value.addingTimeInterval(TimeInterval(QueueRetention.hours72.rawValue))

        let result = try await coordinator.handle(.openNextQueuedDestination)

        #expect(result.disposition == .applied)
        #expect(result.state?.surface == .home)
        #expect(result.state?.activePage == nil)
        #expect(result.state?.runtimeState.queue.isEmpty == true)
    }

    @Test("opening the FIFO head identifies it as queue consumption")
    func openingQueuedWorkCarriesQueueSource() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let queued = try #require(URL(string: "https://queued.example"))
        _ = try await store.apply([.captureQueuedDestination(queued)])
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()

        let opened = try await coordinator.handle(.openNextQueuedDestination)

        let page = try #require(opened.state?.activePage)
        #expect(page.url == queued)
        #expect(opened.effects.first == .activatePage(page, source: .queueConsumption, interactionState: nil))
    }

    @Test("History reopens in the active page, including when Home covers it")
    func historyReopensInActivePage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let activeURL = try #require(URL(string: "https://active.example"))
        let queuedURL = try #require(URL(string: "https://queued.example"))
        let historyURL = try #require(URL(string: "https://history.example"))
        let opened = try await coordinator.handle(.openTypedURL(activeURL))
        let page = try #require(opened.state?.activePage)
        _ = try await coordinator.handle(.addURLToQueue(queuedURL))

        let whileActive = try await coordinator.handle(.openHistoryURL(historyURL))
        #expect(whileActive.state?.activePage?.id == page.id)
        #expect(whileActive.state?.activePage?.url == historyURL)
        #expect(whileActive.state?.runtimeState.queue.map(\.url) == [queuedURL])

        _ = try await coordinator.handle(.showHome)
        let whileCovered = try await coordinator.handle(.openHistoryURL(activeURL))
        #expect(whileCovered.state?.surface == .page)
        #expect(whileCovered.state?.activePage?.id == page.id)
        #expect(whileCovered.state?.activePage?.url == activeURL)
        #expect(whileCovered.state?.runtimeState.queue.map(\.url) == [queuedURL])
        let coveredPage = try #require(whileCovered.state?.activePage)
        #expect(whileCovered.effects == [.navigateActivePage(pageID: page.id, navigationID: coveredPage.currentNavigationID, to: activeURL, source: .history), .showActivePage(coveredPage)])
    }

    @Test("History Open preserves FIFO and continues unfinished resume sessions")
    func historyRespectsHomeBacklog() async throws {
        let emptyFixture = try Fixture()
        defer { emptyFixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let emptyStore = try emptyFixture.store(clock: clock)
        let historyURL = try #require(URL(string: "https://history.example"))
        let emptyCoordinator = coordinator(store: emptyStore, clock: clock)
        _ = try await emptyCoordinator.start()
        let opened = try await emptyCoordinator.handle(.openHistoryURL(historyURL))
        #expect(opened.state?.surface == .page)
        #expect(opened.state?.activePage?.url == historyURL)
        let openedPage = try #require(opened.state?.activePage)
        #expect(opened.effects.first == .activatePage(openedPage, source: .history, interactionState: nil))

        let queuedFixture = try Fixture()
        defer { queuedFixture.remove() }
        let queuedStore = try queuedFixture.store(clock: clock)
        let queuedURL = try #require(URL(string: "https://queued.example"))
        _ = try await queuedStore.apply([.captureQueuedDestination(queuedURL)])
        let queuedCoordinator = coordinator(store: queuedStore, clock: clock)
        _ = try await queuedCoordinator.start()
        let deferredBehindQueue = try await queuedCoordinator.handle(.openHistoryURL(historyURL))
        #expect(deferredBehindQueue.state?.surface == .page)
        #expect(deferredBehindQueue.state?.activePage?.url == historyURL)
        #expect(deferredBehindQueue.state?.runtimeState.queue.map(\.url) == [queuedURL])

        let resumeFixture = try Fixture()
        defer { resumeFixture.remove() }
        let resumeStore = try resumeFixture.store(clock: clock)
        let resumeURL = try #require(URL(string: "https://resume.example"))
        let resumeSession = UUID()
        _ = try await resumeStore.apply([
            .upsertSession(BrowsingSession(id: resumeSession, startedAt: clock.value, hostname: "resume.example")),
            .replaceResumeCheckpoint(ResumeCheckpoint(url: resumeURL, sessionID: resumeSession, savedAt: clock.value)),
        ])
        let resumeCoordinator = coordinator(store: resumeStore, clock: clock)
        _ = try await resumeCoordinator.start()
        let deferredBehindResume = try await resumeCoordinator.handle(.openHistoryURL(historyURL))
        #expect(deferredBehindResume.state?.surface == .page)
        #expect(deferredBehindResume.state?.activePage?.url == historyURL)
        #expect(deferredBehindResume.state?.activePage?.sessionID == resumeSession)
        #expect(deferredBehindResume.state?.runtimeState.resumeCheckpoint?.url == resumeURL)
        #expect(deferredBehindResume.state?.runtimeState.queue.isEmpty == true)
    }

    @Test("an explicitly selected History suggestion records its stable URL choice and navigates the active page")
    func selectedHistorySuggestionOpensActivePage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let selectedURL = try #require(URL(string: "https://example-store.myshopify.test/admin"))
        let suggestion = try await recordSuggestion(url: selectedURL, input: "examp", store: store, clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let activeURL = try #require(URL(string: "https://active.example"))
        let queuedURL = try #require(URL(string: "https://queued.example"))
        let opened = try await coordinator.handle(.openTypedURL(activeURL))
        let activePage = try #require(opened.state?.activePage)
        _ = try await coordinator.handle(.addURLToQueue(queuedURL))

        let result = try await coordinator.handle(
            .selectHistorySuggestion(
                historyURLID: suggestion.historyURLID,
                typedInput: "examp",
                disposition: .open
            )
        )

        let updatedPage = try #require(result.state?.activePage)
        #expect(updatedPage.id == activePage.id)
        #expect(updatedPage.url == selectedURL)
        #expect(result.state?.runtimeState.queue.map(\.url) == [queuedURL])
        #expect(result.effects == [
            .navigateActivePage(
                pageID: activePage.id,
                navigationID: updatedPage.currentNavigationID,
                to: selectedURL,
                source: .suggestion
            ),
        ])
        let promoted = try await store.addressSuggestions(for: "examp")
        let selected = try #require(promoted.suggestions.first { $0.historyURLID == suggestion.historyURLID })
        #expect(selected.addressChoiceCount == 1)
    }

    @Test("Option-Return selection appends the History destination without opening it")
    func selectedHistorySuggestionQueuesAtFIFOEnd() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let selectedURL = try #require(URL(string: "https://example-store.myshopify.test/admin"))
        let suggestion = try await recordSuggestion(url: selectedURL, input: "examp", store: store, clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let activeURL = try #require(URL(string: "https://active.example"))
        let firstQueuedURL = try #require(URL(string: "https://first-queued.example"))
        let opened = try await coordinator.handle(.openTypedURL(activeURL))
        let activePage = try #require(opened.state?.activePage)
        _ = try await coordinator.handle(.addURLToQueue(firstQueuedURL))

        let result = try await coordinator.handle(
            .selectHistorySuggestion(
                historyURLID: suggestion.historyURLID,
                typedInput: "examp",
                disposition: .enqueue
            )
        )

        #expect(result.state?.surface == .page)
        #expect(result.state?.activePage == activePage)
        #expect(result.state?.runtimeState.queue.map(\.url) == [firstQueuedURL, selectedURL])
        #expect(result.effects == [.captureReceipt(url: selectedURL, added: true)])
        let promoted = try await store.addressSuggestions(for: "examp")
        let selected = try #require(promoted.suggestions.first { $0.historyURLID == suggestion.historyURLID })
        #expect(selected.addressChoiceCount == 1)
    }

    @Test("raw Open and Add to queue remain typed-address actions")
    func rawAddressActionsRemainTyped() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let searchURL = try #require(URL(string: "https://www.google.com/search?q=ordinary+phrase"))
        let queuedURL = try #require(URL(string: "https://raw-queue.example"))

        let opened = try await coordinator.handle(.openTypedURL(searchURL))
        let page = try #require(opened.state?.activePage)
        #expect(opened.effects == [.activatePage(page, source: .typedAddress, interactionState: nil), .showActivePage(page)])
        let queued = try await coordinator.handle(.addURLToQueue(queuedURL))

        #expect(queued.state?.activePage == page)
        #expect(queued.state?.runtimeState.queue.map(\.url) == [queuedURL])
        #expect(queued.effects == [.captureReceipt(url: queuedURL, added: true)])
    }

    @Test("a History suggestion returns from Home to the covered active page")
    func selectedHistorySuggestionReturnsFromHomeToActivePage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let selectedURL = try #require(URL(string: "https://example-store.myshopify.test/admin"))
        let suggestion = try await recordSuggestion(url: selectedURL, input: "examp", store: store, clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let activeURL = try #require(URL(string: "https://active.example"))
        let opened = try await coordinator.handle(.openTypedURL(activeURL))
        let activePage = try #require(opened.state?.activePage)
        _ = try await coordinator.handle(.showHome)

        let result = try await coordinator.handle(
            .selectHistorySuggestion(
                historyURLID: suggestion.historyURLID,
                typedInput: "examp",
                disposition: .open
            )
        )

        let updatedPage = try #require(result.state?.activePage)
        #expect(result.state?.surface == .page)
        #expect(updatedPage.id == activePage.id)
        #expect(updatedPage.url == selectedURL)
        #expect(result.effects == [
            .navigateActivePage(
                pageID: activePage.id,
                navigationID: updatedPage.currentNavigationID,
                to: selectedURL,
                source: .suggestion
            ),
            .showActivePage(updatedPage),
        ])
    }

    @Test("a detour dismisses before a History suggestion can consume the palette input")
    func detourRejectsHistorySuggestionWithoutRecordingChoice() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let selectedURL = try #require(URL(string: "https://example-store.myshopify.test/admin"))
        let suggestion = try await recordSuggestion(url: selectedURL, input: "examp", store: store, clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let activeURL = try #require(URL(string: "https://active.example"))
        let detourURL = try #require(URL(string: "https://checkout.example"))
        let opened = try await coordinator.handle(.openTypedURL(activeURL))
        let activePage = try #require(opened.state?.activePage)
        let detourID = UUID()
        let detoured = try await coordinator.handle(.requestTransactionalDetour(id: detourID, url: detourURL))
        let detour = try #require(detoured.state?.detour)

        let result = try await coordinator.handle(
            .selectHistorySuggestion(
                historyURLID: suggestion.historyURLID,
                typedInput: "examp",
                disposition: .open
            )
        )

        #expect(result.effects == [.dismissDetour(detour)])
        #expect(result.state?.activePage == activePage)
        let unchanged = try await store.addressSuggestions(for: "examp")
        let selected = try #require(unchanged.suggestions.first { $0.historyURLID == suggestion.historyURLID })
        #expect(selected.addressChoiceCount == 0)
    }

    @Test("a stale History ID cannot act on a palette URL that no longer has a stored destination")
    func staleHistorySuggestionIDIsIgnored() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let activeURL = try #require(URL(string: "https://active.example"))
        let opened = try await coordinator.handle(.openTypedURL(activeURL))
        let activePage = try #require(opened.state?.activePage)

        let result = try await coordinator.handle(
            .selectHistorySuggestion(
                historyURLID: Int64.max,
                typedInput: "examp",
                disposition: .open
            )
        )

        #expect(result.disposition == .ignored)
        #expect(result.state?.activePage == activePage)
        #expect(result.effects.isEmpty)
    }

    @Test("a failed choice write leaves active suggestion navigation untouched")
    func failedActiveSuggestionChoiceDoesNotNavigateOrPersist() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let faultControl = StoreFaultControl()
        let store = try fixture.store(clock: clock, faultInjector: faultControl.inject)
        let selectedURL = try #require(URL(string: "https://example-store.myshopify.test/admin"))
        let suggestion = try await recordSuggestion(url: selectedURL, input: "examp", store: store, clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let activeURL = try #require(URL(string: "https://active.example"))
        let opened = try await coordinator.handle(.openTypedURL(activeURL))
        let activePage = try #require(opened.state?.activePage)
        faultControl.failingChangeIndex = 0

        await #expect(throws: CoordinatorStoreFault.injected) {
            _ = try await coordinator.handle(
                .selectHistorySuggestion(
                    historyURLID: suggestion.historyURLID,
                    typedInput: "examp",
                    disposition: .open
                )
            )
        }

        #expect((await coordinator.state())?.activePage == activePage)
        let unchanged = try await store.addressSuggestions(for: "examp")
        let selected = try #require(unchanged.suggestions.first { $0.historyURLID == suggestion.historyURLID })
        #expect(selected.addressChoiceCount == 0)
    }

    @Test("a failed queue write rolls back the adaptive choice with the queue action")
    func failedQueuedSuggestionChoiceRollsBackEverything() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let faultControl = StoreFaultControl()
        let store = try fixture.store(clock: clock, faultInjector: faultControl.inject)
        let selectedURL = try #require(URL(string: "https://example-store.myshopify.test/admin"))
        let suggestion = try await recordSuggestion(url: selectedURL, input: "examp", store: store, clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        faultControl.failingChangeIndex = 1

        await #expect(throws: CoordinatorStoreFault.injected) {
            _ = try await coordinator.handle(
                .selectHistorySuggestion(
                    historyURLID: suggestion.historyURLID,
                    typedInput: "examp",
                    disposition: .enqueue
                )
            )
        }

        let state = try #require(await coordinator.state())
        #expect(state.activePage == nil)
        #expect(state.runtimeState.queue.isEmpty)
        let unchanged = try await store.addressSuggestions(for: "examp")
        let selected = try #require(unchanged.suggestions.first { $0.historyURLID == suggestion.historyURLID })
        #expect(selected.addressChoiceCount == 0)
    }

    @Test("a failed new-page session write rolls back the adaptive choice")
    func failedNewPageSuggestionChoiceRollsBackSessionAndChoice() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let faultControl = StoreFaultControl()
        let store = try fixture.store(clock: clock, faultInjector: faultControl.inject)
        let selectedURL = try #require(URL(string: "https://example-store.myshopify.test/admin"))
        let suggestion = try await recordSuggestion(url: selectedURL, input: "examp", store: store, clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        faultControl.failingChangeIndex = 1

        await #expect(throws: CoordinatorStoreFault.injected) {
            _ = try await coordinator.handle(
                .selectHistorySuggestion(
                    historyURLID: suggestion.historyURLID,
                    typedInput: "examp",
                    disposition: .open
                )
            )
        }

        let state = try #require(await coordinator.state())
        #expect(state.activePage == nil)
        #expect(state.runtimeState.activeSession == nil)
        let unchanged = try await store.addressSuggestions(for: "examp")
        let selected = try #require(unchanged.suggestions.first { $0.historyURLID == suggestion.historyURLID })
        #expect(selected.addressChoiceCount == 0)
    }

    @Test("an empty Home can accept an external URL without revealing the window")
    func externalURLDoesNotRevealWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let url = try #require(URL(string: "https://external.example"))

        let result = try await coordinator.handle(.receiveExternalURL(url))

        #expect(result.state?.activePage?.url == url)
        #expect(result.effects.count == 1)
        let page = try #require(result.state?.activePage)
        #expect(result.effects.first == .activatePage(page, source: .external, interactionState: nil))
        #expect(!result.effects.contains(.revealSoleWindow))
    }

    @Test("a detour blocks page-level actions until it closes")
    func detourDismissesBeforePageAction() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let active = try #require(URL(string: "https://active.example"))
        let detourURL = try #require(URL(string: "https://pay.example"))
        let opened = try await coordinator.handle(.openTypedURL(active))
        let page = try #require(opened.state?.activePage)
        let detourID = UUID()
        let detoured = try await coordinator.handle(.requestTransactionalDetour(id: detourID, url: detourURL))
        let detour = try #require(detoured.state?.detour)
        #expect(detour.id == detourID)
        #expect(detoured.effects == [.presentDetour(detour)])
        let duplicate = try await coordinator.handle(.requestTransactionalDetour(id: detourID, url: detourURL))
        #expect(duplicate.disposition == .ignored)
        let staleClose = try await coordinator.handle(.closeTransactionalDetour(detourID: UUID()))
        #expect(staleClose.disposition == .ignored)

        let firstClose = try await coordinator.handle(.closePage(pageID: page.id))
        let secondClose = try await coordinator.handle(.closePage(pageID: page.id))

        #expect(firstClose.effects == [.dismissDetour(detour)])
        #expect(firstClose.state?.activePage == page)
        #expect(secondClose.state?.undoPage?.page == page)
    }

    @Test("stale callbacks and sole-window recovery never create another page or window")
    func ignoresStaleCallbacksAndRecoversSoleWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let url = try #require(URL(string: "https://active.example"))
        let opened = try await coordinator.handle(.openTypedURL(url))
        let page = try #require(opened.state?.activePage)

        let ignored = try await coordinator.handle(.technicalFailure(pageID: UUID(), navigationID: UUID()))
        let recovered = try await coordinator.handle(.recoverSoleWindow)

        #expect(ignored.disposition == .ignored)
        #expect(ignored.state?.activePage == page)
        #expect(recovered.effects == [.revealSoleWindow])
        #expect(recovered.state?.activePage == page)
    }

    @Test("management covers Home or the active page and dismisses without changing the queue")
    func managementCoversAndDismissesWithoutCreatingPage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let activeURL = try #require(URL(string: "https://active.example"))
        let queuedURL = try #require(URL(string: "https://queued.example"))
        let opened = try await coordinator.handle(.openTypedURL(activeURL))
        let page = try #require(opened.state?.activePage)
        _ = try await coordinator.handle(.addURLToQueue(queuedURL))

        let covered = try await coordinator.handle(.showManagement(.history))
        #expect(covered.state?.surface == .management(.history))
        #expect(covered.state?.managementUnderlyingSurface == .page)
        #expect(covered.state?.activePage == page)
        #expect(covered.effects == [.showManagement(.history)])
        #expect(covered.state?.runtimeState.queue.map(\.url) == [queuedURL])

        let switched = try await coordinator.handle(.showManagement(.settings))
        #expect(switched.state?.surface == .management(.settings))
        #expect(switched.state?.managementUnderlyingSurface == .page)
        #expect(switched.state?.activePage == page)

        let dismissed = try await coordinator.handle(.dismissManagement)
        #expect(dismissed.state?.surface == .page)
        #expect(dismissed.state?.activePage == page)
        #expect(dismissed.state?.managementUnderlyingSurface == nil)
        #expect(dismissed.effects == [.showActivePage(page)])
        #expect(dismissed.state?.runtimeState.queue.map(\.url) == [queuedURL])

        let home = try await coordinator.handle(.showHome)
        let homeManagement = try await coordinator.handle(.showManagement(.downloads))
        #expect(home.state?.isHomeCoveringActivePage == true)
        #expect(homeManagement.state?.surface == .management(.downloads))
        #expect(homeManagement.state?.managementUnderlyingSurface == .home)
        #expect(homeManagement.state?.activePage == page)
        let homeDismissed = try await coordinator.handle(.dismissManagement)
        #expect(homeDismissed.state?.surface == .home)
        #expect(homeDismissed.state?.activePage == page)
        #expect(homeDismissed.effects == [.showHome])
    }

    @Test("management waits for a transactional detour to close")
    func managementDismissesDetourBeforeOpening() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let activeURL = try #require(URL(string: "https://active.example"))
        let detourURL = try #require(URL(string: "https://checkout.example"))
        _ = try await coordinator.handle(.openTypedURL(activeURL))
        let detoured = try await coordinator.handle(.requestTransactionalDetour(id: UUID(), url: detourURL))
        let detour = try #require(detoured.state?.detour)

        let first = try await coordinator.handle(.showManagement(.history))
        #expect(first.state?.surface == .page)
        #expect(first.state?.detour == nil)
        #expect(first.effects == [.dismissDetour(detour)])

        let second = try await coordinator.handle(.showManagement(.history))
        #expect(second.state?.surface == .management(.history))
        #expect(second.effects == [.showManagement(.history)])
    }

    @Test("queue deletion uses one Store-backed 60-second undo for selected rows and clear")
    func queueDeletionUndoRoundTripsThroughCoordinator() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let first = try #require(URL(string: "https://first.example"))
        let second = try #require(URL(string: "https://second.example"))
        _ = try await coordinator.handle(.addURLToQueue(first))
        _ = try await coordinator.handle(.addURLToQueue(second))
        let state = try #require(await coordinator.state())
        let firstID = try #require(state.runtimeState.queue.first?.id)
        let secondID = try #require(state.runtimeState.queue.last?.id)

        let removed = try await coordinator.handle(.removeQueuedDestinations(ids: [firstID]))
        let undo = try #require(removed.state?.runtimeState.queueDeletionUndo)
        #expect(removed.state?.runtimeState.queue.map(\.url) == [second])
        #expect(removed.effects == [.refreshManagementData])

        let restored = try await coordinator.handle(.restoreQueueDeletionUndo)
        #expect(restored.state?.runtimeState.queue.map(\.url) == [first, second])
        #expect(restored.state?.runtimeState.queueDeletionUndo == nil)

        clock.value = clock.value.addingTimeInterval(1)
        let cleared = try await coordinator.handle(.clearQueuedDestinations)
        #expect(cleared.state?.runtimeState.queue.isEmpty == true)
        #expect(cleared.state?.runtimeState.queueDeletionUndo?.destinations.map(\.id) == [firstID, secondID])
        clock.value = undo.deadline
        let expired = try await coordinator.handle(.queueDeletionUndoExpired(deadline: undo.deadline))
        #expect(expired.disposition == .ignored)
        let clearUndo = try #require(cleared.state?.runtimeState.queueDeletionUndo)
        clock.value = clearUndo.deadline
        let expiredClear = try await coordinator.handle(.queueDeletionUndoExpired(deadline: clearUndo.deadline))
        #expect(expiredClear.state?.runtimeState.queueDeletionUndo == nil)
        #expect(expiredClear.effects == [.refreshManagementData])
    }

    @Test("History deletion stays in the local History Store and preserves runtime work")
    func historyDeletionUsesRequestedScopeOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let sessionID = UUID()
        _ = try await store.apply([
            .upsertSession(BrowsingSession(id: sessionID, startedAt: clock.value, endedAt: clock.value, hostname: "history.example")),
        ])
        let first = try await store.recordHistoryVisit(HistoryVisitEvent(url: URL(string: "https://history.example/first")!, visitedAt: clock.value, browsingSessionID: sessionID, source: .typedAddress))
        _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: URL(string: "https://history.example/second")!, visitedAt: clock.value.addingTimeInterval(1), browsingSessionID: sessionID, source: .link))
        let queued = try #require(URL(string: "https://queued.example"))
        _ = try await coordinator.handle(.addURLToQueue(queued))

        let result = try await coordinator.handle(.deleteHistory(.visits([first.id])))
        #expect(result.effects == [.refreshManagementData])
        #expect(result.state?.runtimeState.queue.map(\.url) == [queued])
        #expect(try await store.historyVisits(in: sessionID).count == 1)
    }

    @Test("settings, downloads, and diagnostics use Store state plus explicit AppKit effects")
    func managementActionsUseStoreAndEffects() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let activeID = UUID()
        let completedID = UUID()
        let completed = DownloadRecord(id: completedID, hostname: "downloads.example", filename: "invoice.pdf", pathReference: "/tmp/invoice.pdf", byteCount: 42, state: .completed, createdAt: clock.value, completedAt: clock.value)
        let active = DownloadRecord(id: activeID, hostname: "downloads.example", filename: "pending.pdf", byteCount: 1, state: .inProgress, createdAt: clock.value)
        let hostname = try DiagnosticHostname("downloads.example")
        _ = try await store.apply([
            .updateDownload(completed),
            .replaceSettings(KeelSettings(diagnosticModeExpiresAt: clock.value.addingTimeInterval(60))),
            .recordDiagnostic(DiagnosticRecord(timestamp: clock.value, eventType: .download, hostname: hostname, result: .succeeded)),
        ])
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        _ = try await coordinator.handle(.updateDownload(active))

        let settings = KeelSettings(queueRetention: .days7, keepsClosedPageReady: false, searchProvider: .kagi, diagnosticModeExpiresAt: clock.value.addingTimeInterval(60))
        let changed = try await coordinator.handle(.replaceSettings(settings))
        #expect(changed.state?.runtimeState.settings == settings)
        #expect(changed.effects == [.refreshManagementData])

        let opened = try await coordinator.handle(.openDownload(id: completedID))
        #expect(opened.effects == [.openDownload(completed)])
        let revealed = try await coordinator.handle(.revealDownload(id: completedID))
        #expect(revealed.effects == [.revealDownload(completed)])
        let cancelled = try await coordinator.handle(.cancelDownload(id: activeID))
        #expect(cancelled.effects == [.cancelDownload(activeID)])
        let removed = try await coordinator.handle(.removeDownloads(ids: [completedID]))
        #expect(removed.state?.runtimeState.downloads.map(\.id) == [activeID])
        #expect(removed.effects == [.refreshManagementData])

        let exported = try await coordinator.handle(.exportDiagnostics)
        guard case let .exportDiagnostics(data)? = exported.effects.first else {
            Issue.record("expected an explicit diagnostics export effect")
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(DiagnosticExport.self, from: data).records.count == 1)
        let deleted = try await coordinator.handle(.deleteDiagnostics)
        #expect(deleted.effects == [.refreshManagementData])
        #expect(try await store.diagnostics().isEmpty)
    }

    @Test("download lifecycle commits runtime records for management actions")
    func downloadLifecycleUpdatesRuntimeForManagementActions() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()

        let id = UUID()
        let started = DownloadRecord(
            id: id,
            hostname: "downloads.example",
            filename: "pending.pdf",
            byteCount: 12,
            state: .inProgress,
            createdAt: clock.value
        )
        let startedResult = try await coordinator.handle(.updateDownload(started))
        #expect(startedResult.state?.runtimeState.downloads == [started])
        #expect(startedResult.effects.isEmpty)

        let cancelled = try await coordinator.handle(.cancelDownload(id: id))
        #expect(cancelled.effects == [.cancelDownload(id)])

        let destination = "/tmp/pending.pdf"
        let finished = DownloadRecord(
            id: id,
            hostname: started.hostname,
            filename: started.filename,
            pathReference: destination,
            byteCount: 128,
            state: .completed,
            createdAt: started.createdAt,
            completedAt: clock.value.addingTimeInterval(1)
        )
        let finishedResult = try await coordinator.handle(.updateDownload(finished))
        #expect(finishedResult.state?.runtimeState.downloads == [finished])
        #expect(try await store.runtimeState().downloads == [finished])

        let opened = try await coordinator.handle(.openDownload(id: id))
        #expect(opened.effects == [.openDownload(finished)])
    }

    @Test("download deletion ignores in-progress records and still removes terminal records")
    func downloadDeletionProtectsInProgressRecords() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()

        let active = DownloadRecord(
            id: UUID(),
            hostname: "downloads.example",
            filename: "pending.pdf",
            byteCount: 12,
            state: .inProgress,
            createdAt: clock.value
        )
        let completed = DownloadRecord(
            id: UUID(),
            hostname: "downloads.example",
            filename: "done.pdf",
            byteCount: 42,
            state: .completed,
            createdAt: clock.value,
            completedAt: clock.value
        )
        _ = try await coordinator.handle(.updateDownload(active))
        _ = try await coordinator.handle(.updateDownload(completed))

        let result = try await coordinator.handle(.removeDownloads(ids: [active.id, completed.id]))

        #expect(result.disposition == .applied)
        #expect(result.state?.runtimeState.downloads == [active])
        #expect(try await store.runtimeState().downloads == [active])
    }

    @Test("opening History from management reuses the active page and leaves FIFO work in place")
    func openingHistoryFromManagementPreservesOnePageRules() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try fixture.store(clock: clock)
        let coordinator = coordinator(store: store, clock: clock)
        _ = try await coordinator.start()
        let activeURL = try #require(URL(string: "https://active.example"))
        let historyURL = try #require(URL(string: "https://history.example"))
        let queuedURL = try #require(URL(string: "https://queued.example"))
        let opened = try await coordinator.handle(.openTypedURL(activeURL))
        let page = try #require(opened.state?.activePage)
        _ = try await coordinator.handle(.addURLToQueue(queuedURL))
        _ = try await coordinator.handle(.showManagement(.history))

        let result = try await coordinator.handle(.openHistoryURL(historyURL))
        let updated = try #require(result.state?.activePage)
        #expect(result.state?.surface == .page)
        #expect(updated.id == page.id)
        #expect(updated.url == historyURL)
        #expect(result.state?.runtimeState.queue.map(\.url) == [queuedURL])
        #expect(result.effects == [
            .navigateActivePage(pageID: page.id, navigationID: updated.currentNavigationID, to: historyURL, source: .history),
            .showActivePage(updated),
        ])
    }
}

private func coordinator(store: KeelStore, clock: FixtureClock) -> KeelCoordinator {
    let ids = DeterministicIDs()
    return KeelCoordinator(store: store, now: { clock.value }, makeID: { ids.next() })
}

private func recordSuggestion(
    url: URL,
    input: String,
    store: KeelStore,
    clock: FixtureClock
) async throws -> HistorySuggestion {
    let sessionID = UUID()
    _ = try await store.apply([
        .upsertSession(BrowsingSession(
            id: sessionID,
            startedAt: clock.value.addingTimeInterval(-1),
            endedAt: clock.value,
            hostname: url.host?.lowercased()
        )),
    ])
    _ = try await store.recordHistoryVisit(HistoryVisitEvent(
        url: url,
        visitedAt: clock.value,
        browsingSessionID: sessionID,
        source: .typedAddress
    ))
    let result = try await store.addressSuggestions(for: input)
    return try #require(result.suggestions.first { $0.url == url })
}

private final class FixtureClock: @unchecked Sendable {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

private final class DeterministicIDs: @unchecked Sendable {
    private var index: UInt64 = 1

    func next() -> UUID {
        defer { index += 1 }
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llu", index))!
    }
}

private enum CoordinatorStoreFault: Error, Equatable, Sendable {
    case injected
}

private final class StoreFaultControl: @unchecked Sendable {
    var failingChangeIndex: Int?

    func inject(_ changeIndex: Int) throws {
        if failingChangeIndex == changeIndex {
            throw CoordinatorStoreFault.injected
        }
    }
}

private final class Fixture {
    let directory: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "KeelCoordinatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        databaseURL = directory.appending(path: "Keel.sqlite3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func store(
        clock: FixtureClock,
        faultInjector: @escaping @Sendable (Int) throws -> Void = { _ in }
    ) throws -> KeelStore {
        try KeelStore(databaseURL: databaseURL, now: { clock.value }, faultInjector: faultInjector)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
