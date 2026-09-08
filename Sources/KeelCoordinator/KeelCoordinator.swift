import Foundation
import KeelFoundation
import KeelStore

/// Coordinates Keel's logical browsing state. The app and WebKit adapters execute the
/// returned effects only after this actor has committed the matching durable state.
public actor KeelCoordinator {
    private let store: KeelStore
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    private var currentState: KeelCoordinatorState?
    private var transitionInProgress = false
    private var transitionWaiters: [CheckedContinuation<Void, Never>] = []

    public init(store: KeelStore) {
        self.init(store: store, now: Date.init, makeID: UUID.init)
    }

    init(
        store: KeelStore,
        now: @escaping @Sendable () -> Date,
        makeID: @escaping @Sendable () -> UUID
    ) {
        self.store = store
        self.now = now
        self.makeID = makeID
    }

    public func state() -> KeelCoordinatorState? {
        currentState
    }

    /// Launch always opens Home. Close Undo describes a retained in-memory web view, so
    /// it cannot survive a process launch even if its database deadline has not passed.
    public func start() async throws -> KeelCoordinatorResult {
        await acquireTransition()
        defer { releaseTransition() }
        guard currentState == nil else { return ignored() }
        // A WebKit download is process-local. Persisted in-progress rows cannot be
        // resumed because their WKDownload no longer exists after relaunch. Repair
        // them in the same transaction that clears close Undo, before publishing the
        // first state that can drive a management screen.
        let persistedRuntimeState = try await store.runtimeState()
        let launchDate = now()
        var launchChanges: [StoreChange] = [.replaceCloseUndo(nil)]
        launchChanges.append(contentsOf: persistedRuntimeState.downloads.compactMap { download in
            guard download.state == .inProgress else { return nil }
            return .updateDownload(
                DownloadRecord(
                    id: download.id,
                    hostname: download.hostname,
                    filename: download.filename,
                    pathReference: download.pathReference,
                    byteCount: download.byteCount,
                    state: .failed,
                    createdAt: download.createdAt,
                    completedAt: launchDate,
                    errorCode: KeelDownloadErrorCode.interruptedAfterRestart
                )
            )
        })
        let commit = try await store.apply(launchChanges)
        let state = KeelCoordinatorState(
            surface: .home,
            activePage: nil,
            detour: nil,
            undoPage: nil,
            runtimeState: commit.runtimeState
        )
        currentState = state
        return applied(state, effects: [.showHome])
    }

    public func handle(_ event: KeelCoordinatorEvent) async throws -> KeelCoordinatorResult {
        await acquireTransition()
        defer { releaseTransition() }
        guard let state = currentState else { return ignored() }

        switch event {
        case .showHome:
            return dismissDetourBeforePageAction(state) ?? showHome(from: state)
        case .returnToActivePage:
            return returnToActivePage(from: state)
        case let .showManagement(screen):
            return dismissDetourBeforePageAction(state) ?? showManagement(screen, from: state)
        case .dismissManagement:
            return dismissManagement(from: state)
        case let .closePage(pageID):
            return try await closePage(pageID: pageID, from: state)
        case .restoreCloseUndo:
            return try await restoreCloseUndo(from: state)
        case .discardCloseUndo:
            return try await discardCloseUndo(from: state)
        case let .closeUndoExpired(pageID, deadline):
            return try await expireCloseUndo(pageID: pageID, deadline: deadline, from: state)
        case .resumeCheckpoint:
            return try await resumeCheckpoint(from: state)
        case let .preserveFailedResumeBeforeOpen(pageID, navigationID, checkpoint):
            return try await preserveFailedResumeBeforeOpen(pageID: pageID, navigationID: navigationID, checkpoint: checkpoint, from: state)
        case .discardResumeCheckpoint:
            return try await discardResumeCheckpoint(from: state)
        case .requeueResumeAndOpenNext:
            return try await requeueResumeAndOpenNext(from: state)
        case .openNextQueuedDestination:
            return try await openNextQueuedDestination(from: state)
        case let .openTypedURL(url):
            return try await openTypedURL(url, from: state)
        case let .openHistoryURL(url):
            return try await openHistoryURL(url, from: state)
        case let .selectHistorySuggestion(historyURLID, typedInput, disposition):
            return try await selectHistorySuggestion(
                historyURLID: historyURLID,
                typedInput: typedInput,
                disposition: disposition,
                from: state
            )
        case let .addURLToQueue(url):
            return try await addURLToQueue(url, from: state)
        case let .removeQueuedDestinations(ids):
            return try await removeQueuedDestinations(ids, from: state)
        case .clearQueuedDestinations:
            return try await clearQueuedDestinations(from: state)
        case .restoreQueueDeletionUndo:
            return try await restoreQueueDeletionUndo(from: state)
        case let .queueDeletionUndoExpired(deadline):
            return try await expireQueueDeletionUndo(deadline: deadline, from: state)
        case let .deleteHistory(request):
            return try await deleteHistory(request, from: state)
        case let .replaceSettings(settings):
            return try await replaceSettings(settings, from: state)
        case let .updateDownload(download):
            return try await updateDownload(download, from: state)
        case let .removeDownloads(ids):
            return try await removeDownloads(ids, from: state)
        case let .openDownload(id):
            return openDownload(id: id, from: state)
        case let .revealDownload(id):
            return revealDownload(id: id, from: state)
        case let .cancelDownload(id):
            return cancelDownload(id: id, from: state)
        case .exportDiagnostics:
            return try await exportDiagnostics(from: state)
        case .deleteDiagnostics:
            return try await deleteDiagnostics(from: state)
        case let .receiveExternalURL(url):
            return try await receiveExternalURL(url, from: state)
        case let .navigationStarted(pageID, replacingNavigationID, navigationID):
            return navigationStarted(
                pageID: pageID,
                replacingNavigationID: replacingNavigationID,
                navigationID: navigationID,
                from: state
            )
        case let .navigated(pageID, navigationID, url):
            return navigated(pageID: pageID, navigationID: navigationID, to: url, from: state)
        case let .saveResumeCheckpoint(pageID, navigationID, interactionState):
            return try await saveResumeCheckpoint(pageID: pageID, navigationID: navigationID, interactionState: interactionState, from: state)
        case let .technicalFailure(pageID, navigationID):
            return technicalFailure(pageID: pageID, navigationID: navigationID, from: state)
        case let .requeueAndClose(pageID):
            return try await requeueAndClose(pageID: pageID, from: state)
        case let .requestTransactionalDetour(id, url):
            return requestTransactionalDetour(id: id, url: url, from: state)
        case let .closeTransactionalDetour(detourID):
            return closeTransactionalDetour(detourID: detourID, from: state)
        case .recoverSoleWindow:
            return applied(state, effects: [.revealSoleWindow])
        }
    }
}

private extension KeelCoordinator {
    func acquireTransition() async {
        guard transitionInProgress else {
            transitionInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            transitionWaiters.append(continuation)
        }
    }

    func releaseTransition() {
        if transitionWaiters.isEmpty {
            transitionInProgress = false
        } else {
            transitionWaiters.removeFirst().resume()
        }
    }

    func showManagement(_ screen: KeelManagementScreen, from state: KeelCoordinatorState) -> KeelCoordinatorResult {
        let underlying: KeelSurface
        switch state.surface {
        case .home, .page:
            underlying = state.surface
        case .management:
            underlying = state.managementUnderlyingSurface ?? (state.activePage == nil ? .home : .page)
        }

        let next = state.replacing(
            surface: .management(screen),
            managementUnderlyingSurface: .set(underlying)
        )
        currentState = next
        return applied(next, effects: [.showManagement(screen)])
    }

    func dismissManagement(from state: KeelCoordinatorState) -> KeelCoordinatorResult {
        guard case .management = state.surface else { return ignored() }
        let underlying = state.managementUnderlyingSurface ?? (state.activePage == nil ? .home : .page)
        let restoredSurface: KeelSurface
        switch underlying {
        case .page where state.activePage != nil:
            restoredSurface = .page
        case .management:
            restoredSurface = state.activePage == nil ? .home : .page
        default:
            restoredSurface = .home
        }
        let next = state.replacing(
            surface: restoredSurface,
            managementUnderlyingSurface: .set(nil)
        )
        currentState = next
        let effects: [KeelCoordinatorEffect]
        if restoredSurface == .page, let page = next.activePage {
            effects = [.showActivePage(page)]
        } else {
            effects = [.showHome]
        }
        return applied(next, effects: effects)
    }

    /// Returns the state below a management screen. Page actions use this only when
    /// the action itself should also dismiss the management screen, such as opening a
    /// History result. Ordinary management mutations leave the screen in place.
    func stateBelowManagement(_ state: KeelCoordinatorState) -> KeelCoordinatorState {
        guard case .management = state.surface else { return state }
        let underlying = state.managementUnderlyingSurface ?? (state.activePage == nil ? .home : .page)
        let surface: KeelSurface = underlying == .page && state.activePage != nil ? .page : .home
        return state.replacing(surface: surface, managementUnderlyingSurface: .set(nil))
    }

    func dismissManagementBeforePageAction(_ state: KeelCoordinatorState) -> KeelCoordinatorResult? {
        guard case .management = state.surface else { return nil }
        let next = stateBelowManagement(state)
        currentState = next
        let effects: [KeelCoordinatorEffect]
        if next.surface == .page, let page = next.activePage {
            effects = [.showActivePage(page)]
        } else {
            effects = [.showHome]
        }
        return applied(next, effects: effects)
    }

    func showHome(from state: KeelCoordinatorState) -> KeelCoordinatorResult {
        if case .management = state.surface {
            let dismissed = dismissManagement(from: state)
            guard let next = dismissed.state else { return dismissed }
            if next.surface == .page {
                return showHome(from: next)
            }
            return dismissed
        }
        guard state.surface == .page else { return ignored() }
        let next = state.replacing(surface: .home, managementUnderlyingSurface: .set(nil), detour: .set(nil))
        currentState = next
        return applied(next, effects: [.showHome])
    }

    func returnToActivePage(from state: KeelCoordinatorState) -> KeelCoordinatorResult {
        if case .management = state.surface {
            let dismissed = dismissManagement(from: state)
            guard dismissed.disposition == .applied,
                  let next = dismissed.state,
                  next.surface == .home,
                  let page = next.activePage
            else { return dismissed }
            let pageState = next.replacing(surface: .page)
            currentState = pageState
            return applied(pageState, effects: [.showActivePage(page)])
        }
        guard state.surface == .home, let page = state.activePage else { return ignored() }
        let next = state.replacing(surface: .page)
        currentState = next
        return applied(next, effects: [.showActivePage(page)])
    }

    func closePage(pageID: UUID, from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        guard let page = state.activePage, page.id == pageID else { return ignored() }
        if let managementResult = dismissManagementBeforePageAction(state) { return managementResult }
        if let detourResult = dismissDetourBeforePageAction(state) { return detourResult }

        let closedAt = now()
        let endingSession = endedSession(for: page, runtimeState: state.runtimeState, at: closedAt)
        let undo = KeelUndoPage(
            page: page,
            sessionStartedAt: endingSession.startedAt,
            sessionHostname: endingSession.hostname,
            deadline: closedAt.addingTimeInterval(10 * 60)
        )
        let nextSession = newSession(hostname: nil, at: closedAt)
        let commit = try await store.apply([
            .replaceCloseUndo(CloseUndoRecord(url: page.url, sessionID: page.sessionID, closedAt: closedAt, deadline: undo.deadline)),
            .upsertSession(endingSession),
            .replaceResumeCheckpoint(nil),
            .advanceToOldestQueuedDestination(startingSession: nextSession),
        ])
        let destination = consumedDestination(from: commit.outcomes.last)
        let nextPage = destination.map { makePage(url: $0.url, sessionID: nextSession.id) }
        var effects: [KeelCoordinatorEffect] = []
        if let previousUndo = state.undoPage { effects.append(.discardUndoPage(previousUndo)) }
        effects.append(.retainClosedPageForUndo(undo, keepsLiveWebView: commit.runtimeState.settings.keepsClosedPageReady))
        if let nextPage {
            effects.append(.activatePage(nextPage, source: .queueConsumption, interactionState: nil))
            effects.append(.showActivePage(nextPage))
        } else {
            effects.append(.showHome)
        }
        let next = KeelCoordinatorState(
            surface: nextPage == nil ? .home : .page,
            activePage: nextPage,
            detour: nil,
            undoPage: undo,
            runtimeState: commit.runtimeState
        )
        currentState = next
        effects.append(.finishReceipt(nextURL: nextPage?.url))
        return applied(next, effects: effects)
    }

    func restoreCloseUndo(from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        if let managementResult = dismissManagementBeforePageAction(state) { return managementResult }
        guard let undo = state.undoPage else { return ignored() }
        guard undo.deadline > now() else {
            return try await expireCloseUndo(pageID: undo.page.id, deadline: undo.deadline, from: state)
        }
        guard state.detour == nil else { return ignored() }

        var changes: [StoreChange] = []
        var effects: [KeelCoordinatorEffect] = []
        if let activePage = state.activePage {
            let endingSession = endedSession(for: activePage, runtimeState: state.runtimeState, at: now())
            changes.append(.prependQueuedDestination(activePage.url))
            changes.append(.upsertSession(endingSession))
            changes.append(.replaceResumeCheckpoint(nil))
            effects.append(.discardActivePage(activePage))
        }
        changes.append(.upsertSession(undo.reopenedSession))
        changes.append(.replaceResumeCheckpoint(ResumeCheckpoint(
            url: undo.page.url,
            sessionID: undo.page.sessionID,
            savedAt: now()
        )))
        changes.append(.replaceCloseUndo(nil))
        let commit = try await store.apply(changes)
        let next = KeelCoordinatorState(
            surface: .page,
            activePage: undo.page,
            detour: nil,
            undoPage: nil,
            runtimeState: commit.runtimeState
        )
        effects.append(.restoreUndoPage(undo))
        effects.append(.showActivePage(undo.page))
        currentState = next
        return applied(next, effects: effects)
    }

    func discardCloseUndo(from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        guard let undo = state.undoPage else { return ignored() }
        let commit = try await store.apply([.replaceCloseUndo(nil)])
        let next = state.replacing(undoPage: .set(nil), runtimeState: commit.runtimeState)
        currentState = next
        return applied(next, effects: [.discardUndoPage(undo)])
    }

    func expireCloseUndo(
        pageID: UUID,
        deadline: Date,
        from state: KeelCoordinatorState
    ) async throws -> KeelCoordinatorResult {
        guard let undo = state.undoPage,
              undo.page.id == pageID,
              undo.deadline == deadline,
              deadline <= now()
        else { return ignored() }
        let commit = try await store.apply([.replaceCloseUndo(nil)])
        let next = state.replacing(undoPage: .set(nil), runtimeState: commit.runtimeState)
        currentState = next
        return applied(next, effects: [.discardUndoPage(undo)])
    }

    func resumeCheckpoint(from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        guard state.surface == .home,
              state.activePage == nil,
              let checkpoint = state.runtimeState.resumeCheckpoint,
              state.runtimeState.activeSession?.id == checkpoint.sessionID
        else { return ignored() }
        let commit = try await store.apply([.replaceResumeCheckpoint(nil)])
        let page = makePage(url: checkpoint.url, sessionID: checkpoint.sessionID)
        let next = state.replacing(surface: .page, activePage: page, runtimeState: commit.runtimeState)
        currentState = next
        return applied(next, effects: [.activatePage(page, source: .resume, interactionState: checkpoint.interactionState), .showActivePage(page)])
    }

    /// A failed restore must preserve its destination before the browser loads the
    /// explicit Open target. The checkpoint guard makes duplicate callbacks harmless.
    func preserveFailedResumeBeforeOpen(
        pageID: UUID,
        navigationID: UUID,
        checkpoint: ResumeCheckpoint,
        from state: KeelCoordinatorState
    ) async throws -> KeelCoordinatorResult {
        guard let page = state.activePage,
              page.id == pageID,
              page.currentNavigationID == navigationID,
              page.sessionID == checkpoint.sessionID,
              state.runtimeState.activeSession?.id == checkpoint.sessionID,
              state.runtimeState.resumeCheckpoint == checkpoint
        else { return ignored() }
        let commit = try await store.apply([
            .prependQueuedDestination(checkpoint.url),
            .replaceResumeCheckpoint(nil),
        ])
        let next = state.replacing(runtimeState: commit.runtimeState)
        currentState = next
        return applied(next, effects: [])
    }

    func discardResumeCheckpoint(from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        guard state.surface == .home,
              state.activePage == nil,
              let checkpoint = state.runtimeState.resumeCheckpoint
        else { return ignored() }
        var changes: [StoreChange] = [.replaceResumeCheckpoint(nil)]
        if state.runtimeState.activeSession?.id == checkpoint.sessionID {
            changes.append(.upsertSession(endedSession(id: checkpoint.sessionID, runtimeState: state.runtimeState, at: now())))
        }
        let commit = try await store.apply(changes)
        let next = state.replacing(runtimeState: commit.runtimeState)
        currentState = next
        return applied(next, effects: [])
    }

    func requeueResumeAndOpenNext(from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        guard state.surface == .home,
              state.activePage == nil,
              let checkpoint = state.runtimeState.resumeCheckpoint,
              state.runtimeState.activeSession?.id == checkpoint.sessionID
        else { return ignored() }
        let startedAt = now()
        let nextSession = newSession(hostname: nil, at: startedAt)
        let commit = try await store.apply([
            .captureQueuedDestination(checkpoint.url),
            .replaceResumeCheckpoint(nil),
            .upsertSession(endedSession(id: checkpoint.sessionID, runtimeState: state.runtimeState, at: startedAt)),
            .advanceToOldestQueuedDestination(startingSession: nextSession),
        ])
        let destination = consumedDestination(from: commit.outcomes.last)
        guard let destination else {
            let next = state.replacing(runtimeState: commit.runtimeState)
            currentState = next
            return applied(next, effects: [])
        }
        let page = makePage(url: destination.url, sessionID: nextSession.id)
        let next = state.replacing(surface: .page, activePage: page, runtimeState: commit.runtimeState)
        currentState = next
        return applied(next, effects: [.activatePage(page, source: .queueConsumption, interactionState: nil), .showActivePage(page)])
    }

    func openNextQueuedDestination(from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        guard state.surface == .home,
              state.activePage == nil,
              state.runtimeState.resumeCheckpoint == nil,
              !state.runtimeState.queue.isEmpty
        else { return ignored() }
        let startedAt = now()
        let nextSession = newSession(hostname: nil, at: startedAt)
        let commit = try await store.apply([.advanceToOldestQueuedDestination(startingSession: nextSession)])
        guard let destination = consumedDestination(from: commit.outcomes.first) else {
            let next = state.replacing(runtimeState: commit.runtimeState)
            currentState = next
            return applied(next, effects: [])
        }
        let page = makePage(url: destination.url, sessionID: nextSession.id)
        let next = state.replacing(surface: .page, activePage: page, runtimeState: commit.runtimeState)
        currentState = next
        return applied(next, effects: [.activatePage(page, source: .queueConsumption, interactionState: nil), .showActivePage(page)])
    }

    func openTypedURL(_ url: URL, from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        let actionState = stateBelowManagement(state)
        if let detourResult = dismissDetourBeforePageAction(actionState) { return detourResult }
        if let page = actionState.activePage {
            let updated = page.navigating(to: url, navigationID: makeID())
            let next = actionState.replacing(surface: .page, managementUnderlyingSurface: .set(nil), activePage: updated)
            currentState = next
            var effects: [KeelCoordinatorEffect] = [.navigateActivePage(pageID: page.id, navigationID: updated.currentNavigationID, to: url, source: .typedAddress)]
            if actionState.surface == .home || state.surface != actionState.surface { effects.append(.showActivePage(updated)) }
            return applied(next, effects: effects)
        }
        guard actionState.surface == .home else { return ignored() }
        return try await openFromHome(url, source: .typedAddress, from: actionState)
    }

    func addURLToQueue(_ url: URL, from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        let actionState = stateBelowManagement(state)
        let result = try await capture(url, from: actionState)
        guard state.surface != actionState.surface else { return result }
        let effects: [KeelCoordinatorEffect]
        if actionState.surface == .page, let page = actionState.activePage {
            effects = [.showActivePage(page)]
        } else {
            effects = [.showHome]
        }
        return applied(result.state ?? actionState, effects: result.effects + effects)
    }

    func removeQueuedDestinations(_ ids: Set<UUID>, from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        let existingIDs = Set(state.runtimeState.queue.map(\.id))
        let requestedIDs = ids.intersection(existingIDs)
        guard !requestedIDs.isEmpty else { return ignored() }
        let commit = try await store.apply([
            .removeQueuedDestinations(ids: requestedIDs.sorted { $0.uuidString < $1.uuidString }),
        ])
        let next = state.replacing(runtimeState: commit.runtimeState)
        currentState = next
        return applied(next, effects: [.refreshManagementData])
    }

    func clearQueuedDestinations(from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        guard !state.runtimeState.queue.isEmpty else { return ignored() }
        let commit = try await store.apply([.clearQueuedDestinations])
        let next = state.replacing(runtimeState: commit.runtimeState)
        currentState = next
        return applied(next, effects: [.refreshManagementData])
    }

    func restoreQueueDeletionUndo(from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        guard let undo = state.runtimeState.queueDeletionUndo else { return ignored() }
        guard undo.deadline > now() else {
            return try await expireQueueDeletionUndo(deadline: undo.deadline, from: state)
        }
        let commit = try await store.apply([.restoreLatestQueueDeletionUndo])
        let next = state.replacing(runtimeState: commit.runtimeState)
        currentState = next
        return applied(next, effects: [.refreshManagementData])
    }

    func expireQueueDeletionUndo(deadline: Date, from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        guard let undo = state.runtimeState.queueDeletionUndo,
              undo.deadline == deadline,
              deadline <= now()
        else { return ignored() }
        // `runtimeState()` performs the Store's expiry cleanup. This timer is kept
        // separate from automatic queue retention, which the Store prunes on reads.
        let runtimeState = try await store.runtimeState()
        let next = state.replacing(runtimeState: runtimeState)
        currentState = next
        return applied(next, effects: [.refreshManagementData])
    }

    func deleteHistory(_ request: KeelHistoryDeletionRequest, from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        // History deletion is deliberately a local Store operation. There is no
        // WebKit website-data effect here, so cookies and site storage survive.
        try await store.deleteHistory(request.storeScope)
        let runtimeState = try await store.runtimeState()
        let next = state.replacing(runtimeState: runtimeState)
        currentState = next
        return applied(next, effects: [.refreshManagementData])
    }

    func replaceSettings(_ settings: KeelSettings, from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        let commit = try await store.apply([.replaceSettings(settings)])
        let next = state.replacing(runtimeState: commit.runtimeState)
        currentState = next
        return applied(next, effects: [.refreshManagementData])
    }

    func updateDownload(_ download: DownloadRecord, from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        let commit = try await store.apply([.updateDownload(download)])
        let next = state.replacing(runtimeState: commit.runtimeState)
        currentState = next
        return applied(next, effects: [])
    }

    func removeDownloads(_ ids: Set<UUID>, from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        // Active transfers remain owned by WebKit until they publish a terminal
        // event. Deleting their durable rows would let that event recreate the row.
        let existingIDs = Set(
            state.runtimeState.downloads
                .filter { $0.state != .inProgress }
                .map(\.id)
        )
        let requestedIDs = ids.intersection(existingIDs)
        guard !requestedIDs.isEmpty else { return ignored() }
        let commit = try await store.apply([
            .removeDownloads(ids: requestedIDs.sorted { $0.uuidString < $1.uuidString }),
        ])
        let next = state.replacing(runtimeState: commit.runtimeState)
        currentState = next
        return applied(next, effects: [.refreshManagementData])
    }

    func openDownload(id: UUID, from state: KeelCoordinatorState) -> KeelCoordinatorResult {
        guard let download = state.runtimeState.downloads.first(where: { $0.id == id }) else {
            return ignored()
        }
        return applied(state, effects: [.openDownload(download)])
    }

    func revealDownload(id: UUID, from state: KeelCoordinatorState) -> KeelCoordinatorResult {
        guard let download = state.runtimeState.downloads.first(where: { $0.id == id }) else {
            return ignored()
        }
        return applied(state, effects: [.revealDownload(download)])
    }

    func cancelDownload(id: UUID, from state: KeelCoordinatorState) -> KeelCoordinatorResult {
        guard let download = state.runtimeState.downloads.first(where: { $0.id == id }),
              download.state == .inProgress
        else { return ignored() }
        return applied(state, effects: [.cancelDownload(id)])
    }

    func exportDiagnostics(from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        let data = try await store.diagnosticExportData()
        return applied(state, effects: [.exportDiagnostics(data)])
    }

    func deleteDiagnostics(from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        let commit = try await store.apply([.deleteDiagnostics])
        let next = state.replacing(runtimeState: commit.runtimeState)
        currentState = next
        return applied(next, effects: [.refreshManagementData])
    }

    func openHistoryURL(_ url: URL, from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        let actionState = stateBelowManagement(state)
        if let detourResult = dismissDetourBeforePageAction(actionState) { return detourResult }
        if let page = actionState.activePage {
            let updated = page.navigating(to: url, navigationID: makeID())
            let next = actionState.replacing(surface: .page, managementUnderlyingSurface: .set(nil), activePage: updated)
            currentState = next
            var effects: [KeelCoordinatorEffect] = [.navigateActivePage(pageID: page.id, navigationID: updated.currentNavigationID, to: url, source: .history)]
            if actionState.surface == .home || state.surface != actionState.surface { effects.append(.showActivePage(updated)) }
            return applied(next, effects: effects)
        }
        guard actionState.surface == .home else { return ignored() }
        return try await openFromHome(url, source: .history, from: actionState)
    }

    func selectHistorySuggestion(
        historyURLID: Int64,
        typedInput: String,
        disposition: KeelHistorySuggestionDisposition,
        from state: KeelCoordinatorState
    ) async throws -> KeelCoordinatorResult {
        let actionState = stateBelowManagement(state)
        // A detour owns interaction until it has been dismissed. Do not consume the
        // typed input or promote a result that the person could not actually open.
        if let detourResult = dismissDetourBeforePageAction(actionState) { return detourResult }

        // A palette row can become stale while it is visible. The Store is the sole
        // authority for both the stable ID and its canonical navigation URL.
        guard let selectedURL = try await store.historyURL(forID: historyURLID) else {
            return ignored()
        }

        switch disposition {
        case .open:
            let result = try await openSelectedHistorySuggestion(
                selectedURL,
                choiceInput: typedInput,
                historyURLID: historyURLID,
                from: actionState
            )
            guard state.surface != actionState.surface,
                  let next = result.state
            else { return result }
            if next.surface == .page,
               let page = next.activePage,
               !result.effects.contains(where: {
                   if case .showActivePage = $0 { return true }
                   return false
               }) {
                return applied(next, effects: result.effects + [.showActivePage(page)])
            }
            if next.surface == .home {
                return applied(next, effects: result.effects + [.showHome])
            }
            return result
        case .enqueue:
            let commit = try await store.apply([
                .recordAddressChoice(input: typedInput, historyURLID: historyURLID),
                .captureQueuedDestination(selectedURL),
            ])
            let next = state.replacing(runtimeState: commit.runtimeState)
            currentState = next
            return applied(next, effects: captureReceiptEffects(url: selectedURL, commit: commit))
        }
    }

    func openSelectedHistorySuggestion(
        _ url: URL,
        choiceInput: String,
        historyURLID: Int64,
        from state: KeelCoordinatorState
    ) async throws -> KeelCoordinatorResult {
        if let page = state.activePage {
            let commit = try await store.apply([
                .recordAddressChoice(input: choiceInput, historyURLID: historyURLID),
            ])
            let updated = page.navigating(to: url, navigationID: makeID())
            let next = state.replacing(surface: .page, activePage: updated, runtimeState: commit.runtimeState)
            currentState = next
            var effects: [KeelCoordinatorEffect] = [
                .navigateActivePage(
                    pageID: page.id,
                    navigationID: updated.currentNavigationID,
                    to: url,
                    source: .suggestion
                ),
            ]
            if state.surface == .home { effects.append(.showActivePage(updated)) }
            return applied(next, effects: effects)
        }
        guard state.surface == .home else { return ignored() }
        return try await openFromHome(url, source: .suggestion, from: state, changes: [
            .recordAddressChoice(input: choiceInput, historyURLID: historyURLID),
        ])
    }

    /// Explicit Open never consumes or appends to the queue. A relaunch checkpoint
    /// continues its session and remains durable until the browser saves fresh state.
    func openFromHome(
        _ url: URL,
        source: HistoryVisitSource,
        from state: KeelCoordinatorState,
        changes: [StoreChange] = []
    ) async throws -> KeelCoordinatorResult {
        if let checkpoint = state.runtimeState.resumeCheckpoint {
            guard state.runtimeState.activeSession?.id == checkpoint.sessionID else { return ignored() }
            let commit = try await store.apply(changes)
            let page = makePage(url: url, sessionID: checkpoint.sessionID)
            let next = state.replacing(surface: .page, activePage: page, runtimeState: commit.runtimeState)
            currentState = next
            return applied(next, effects: [
                .restorePageThenNavigate(page: page, checkpoint: checkpoint, source: source),
                .showActivePage(page),
            ])
        }
        let session = newSession(hostname: url.host?.lowercased(), at: now())
        let commit = try await store.apply(changes + [.upsertSession(session)])
        let page = makePage(url: url, sessionID: session.id)
        let next = state.replacing(surface: .page, activePage: page, runtimeState: commit.runtimeState)
        currentState = next
        return applied(next, effects: [.activatePage(page, source: source, interactionState: nil), .showActivePage(page)])
    }

    func receiveExternalURL(_ url: URL, from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        guard state.activePage == nil,
              state.surface == .home,
              state.runtimeState.resumeCheckpoint == nil,
              state.runtimeState.queue.isEmpty
        else { return try await capture(url, from: state) }
        // Incoming links may make an empty Keel active, but never ask AppKit to reveal it.
        return try await startNewPage(url, source: .external, from: state, shouldShow: false)
    }

    func navigationStarted(
        pageID: UUID,
        replacingNavigationID: UUID,
        navigationID: UUID,
        from state: KeelCoordinatorState
    ) -> KeelCoordinatorResult {
        guard let page = state.activePage,
              page.id == pageID,
              page.currentNavigationID == replacingNavigationID
        else { return ignored() }
        let next = state.replacing(activePage: page.navigating(to: page.url, navigationID: navigationID))
        currentState = next
        return applied(next, effects: [])
    }

    func navigated(pageID: UUID, navigationID: UUID, to url: URL, from state: KeelCoordinatorState) -> KeelCoordinatorResult {
        guard let page = state.activePage,
              page.id == pageID,
              page.currentNavigationID == navigationID
        else { return ignored() }
        let next = state.replacing(activePage: page.navigating(to: url, navigationID: navigationID))
        currentState = next
        return applied(next, effects: [])
    }

    func saveResumeCheckpoint(
        pageID: UUID,
        navigationID: UUID,
        interactionState: Data?,
        from state: KeelCoordinatorState
    ) async throws -> KeelCoordinatorResult {
        guard let page = state.activePage,
              page.id == pageID,
              page.currentNavigationID == navigationID
        else { return ignored() }
        let checkpoint = ResumeCheckpoint(url: page.url, sessionID: page.sessionID, savedAt: now(), interactionState: interactionState)
        let commit = try await store.apply([.replaceResumeCheckpoint(checkpoint)])
        let next = state.replacing(runtimeState: commit.runtimeState)
        currentState = next
        return applied(next, effects: [])
    }

    func technicalFailure(pageID: UUID, navigationID: UUID, from state: KeelCoordinatorState) -> KeelCoordinatorResult {
        guard let page = state.activePage,
              page.id == pageID,
              page.currentNavigationID == navigationID
        else { return ignored() }
        let next = state.replacing(activePage: page.failedTechnically())
        currentState = next
        return applied(next, effects: [])
    }

    func requeueAndClose(pageID: UUID, from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        guard let page = state.activePage, page.id == pageID else { return ignored() }
        if let managementResult = dismissManagementBeforePageAction(state) { return managementResult }
        if let detourResult = dismissDetourBeforePageAction(state) { return detourResult }

        let closedAt = now()
        let nextSession = newSession(hostname: nil, at: closedAt)
        let commit = try await store.apply([
            .captureQueuedDestination(page.url),
            .upsertSession(endedSession(for: page, runtimeState: state.runtimeState, at: closedAt)),
            .replaceResumeCheckpoint(nil),
            .replaceCloseUndo(nil),
            .advanceToOldestQueuedDestination(startingSession: nextSession),
        ])
        let destination = consumedDestination(from: commit.outcomes.last)
        let nextPage = destination.map { makePage(url: $0.url, sessionID: nextSession.id) }
        var effects: [KeelCoordinatorEffect] = []
        if let undo = state.undoPage { effects.append(.discardUndoPage(undo)) }
        effects.append(.discardActivePage(page))
        if let nextPage {
            effects.append(.activatePage(nextPage, source: .queueConsumption, interactionState: nil))
            effects.append(.showActivePage(nextPage))
        } else {
            effects.append(.showHome)
        }
        let next = KeelCoordinatorState(
            surface: nextPage == nil ? .home : .page,
            activePage: nextPage,
            detour: nil,
            undoPage: nil,
            runtimeState: commit.runtimeState
        )
        currentState = next
        return applied(next, effects: effects)
    }

    func requestTransactionalDetour(id: UUID, url: URL, from state: KeelCoordinatorState) -> KeelCoordinatorResult {
        guard state.surface == .page, let page = state.activePage, state.detour == nil else { return ignored() }
        let detour = KeelTransactionalDetour(id: id, parentPageID: page.id, url: url)
        let next = state.replacing(detour: .set(detour))
        currentState = next
        return applied(next, effects: [.presentDetour(detour)])
    }

    func closeTransactionalDetour(detourID: UUID, from state: KeelCoordinatorState) -> KeelCoordinatorResult {
        guard let detour = state.detour, detour.id == detourID else { return ignored() }
        let next = state.replacing(detour: .set(nil))
        currentState = next
        return applied(next, effects: [.dismissDetour(detour)])
    }

    func dismissDetourBeforePageAction(_ state: KeelCoordinatorState) -> KeelCoordinatorResult? {
        guard let detour = state.detour else { return nil }
        let next = state.replacing(detour: .set(nil))
        currentState = next
        return applied(next, effects: [.dismissDetour(detour)])
    }

    func capture(_ url: URL, from state: KeelCoordinatorState) async throws -> KeelCoordinatorResult {
        let commit = try await store.apply([.captureQueuedDestination(url)])
        let next = state.replacing(runtimeState: commit.runtimeState)
        currentState = next
        return applied(next, effects: captureReceiptEffects(url: url, commit: commit))
    }

    func captureReceiptEffects(url: URL, commit: KeelStoreCommit) -> [KeelCoordinatorEffect] {
        for outcome in commit.outcomes {
            if case let .captured(destination) = outcome {
                if destination != nil { return [.captureReceipt(url: url, added: true)] }
                if commit.runtimeState.queue.contains(where: { $0.url == url }) {
                    return [.captureReceipt(url: url, added: false)]
                }
            }
        }
        return []
    }

    func startNewPage(
        _ url: URL,
        source: HistoryVisitSource,
        from state: KeelCoordinatorState,
        shouldShow: Bool
    ) async throws -> KeelCoordinatorResult {
        let startedAt = now()
        let session = newSession(hostname: url.host?.lowercased(), at: startedAt)
        let commit = try await store.apply([.upsertSession(session)])
        let page = makePage(url: url, sessionID: session.id)
        let next = state.replacing(surface: .page, activePage: page, runtimeState: commit.runtimeState)
        currentState = next
        var effects: [KeelCoordinatorEffect] = [.activatePage(page, source: source, interactionState: nil)]
        if shouldShow { effects.append(.showActivePage(page)) }
        return applied(next, effects: effects)
    }

    func newSession(hostname: String?, at date: Date) -> BrowsingSession {
        BrowsingSession(id: makeID(), startedAt: date, hostname: hostname)
    }

    func makePage(url: URL, sessionID: UUID) -> KeelPage {
        KeelPage(id: makeID(), sessionID: sessionID, currentNavigationID: makeID(), url: url)
    }

    func endedSession(for page: KeelPage, runtimeState: KeelRuntimeState, at date: Date) -> BrowsingSession {
        endedSession(id: page.sessionID, runtimeState: runtimeState, at: date, fallbackHostname: page.url.host?.lowercased())
    }

    func endedSession(
        id: UUID,
        runtimeState: KeelRuntimeState,
        at date: Date,
        fallbackHostname: String? = nil
    ) -> BrowsingSession {
        let existing = runtimeState.activeSession
        return BrowsingSession(
            id: id,
            startedAt: existing?.id == id ? existing!.startedAt : date,
            endedAt: date,
            hostname: existing?.id == id ? existing!.hostname : fallbackHostname
        )
    }

    func consumedDestination(from outcome: StoreChangeOutcome?) -> QueuedDestination? {
        guard case let .consumed(destination)? = outcome else { return nil }
        return destination
    }

    func applied(_ state: KeelCoordinatorState, effects: [KeelCoordinatorEffect]) -> KeelCoordinatorResult {
        KeelCoordinatorResult(state: state, effects: effects, disposition: .applied)
    }

    func ignored() -> KeelCoordinatorResult {
        KeelCoordinatorResult(state: currentState, effects: [], disposition: .ignored)
    }
}

private enum StateUpdate<Value> {
    case keep
    case set(Value)
}

private extension KeelCoordinatorState {
    func replacing(
        surface: KeelSurface? = nil,
        managementUnderlyingSurface: StateUpdate<KeelSurface?> = .keep,
        activePage: KeelPage?? = nil,
        detour: StateUpdate<KeelTransactionalDetour?> = .keep,
        undoPage: StateUpdate<KeelUndoPage?> = .keep,
        runtimeState: KeelRuntimeState? = nil
    ) -> KeelCoordinatorState {
        let nextManagementUnderlyingSurface: KeelSurface?
        switch managementUnderlyingSurface {
        case .keep: nextManagementUnderlyingSurface = self.managementUnderlyingSurface
        case let .set(value): nextManagementUnderlyingSurface = value
        }
        let nextDetour: KeelTransactionalDetour?
        switch detour {
        case .keep: nextDetour = self.detour
        case let .set(value): nextDetour = value
        }
        let nextUndoPage: KeelUndoPage?
        switch undoPage {
        case .keep: nextUndoPage = self.undoPage
        case let .set(value): nextUndoPage = value
        }
        return KeelCoordinatorState(
            surface: surface ?? self.surface,
            activePage: activePage ?? self.activePage,
            detour: nextDetour,
            undoPage: nextUndoPage,
            runtimeState: runtimeState ?? self.runtimeState,
            managementUnderlyingSurface: nextManagementUnderlyingSurface
        )
    }
}
