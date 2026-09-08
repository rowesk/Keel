import Foundation
import KeelCoordinator
import KeelStore
import KeelUI
import KeelWeb

/// Converts Store and coordinator values into the deliberately smaller values that
/// SwiftUI renders. The UI does not need to know about Store rows or WebKit types.
@MainActor
enum KeelAppPresentationMapper {
    static func homeModel(
        from state: KeelCoordinatorState,
        favicons: KeelNativeScreenFaviconCache? = nil,
        titles: [String: String] = [:]
    ) -> KeelHomeModel {
        let runtime = state.runtimeState
        let resume = runtime.resumeCheckpoint.map {
            KeelResumeItem(
                displayURL: $0.url.absoluteString,
                hostname: hostname(for: $0.url),
                title: titles[$0.url.absoluteString],
                icon: favicons?.icon(for: $0.url),
                savedAt: $0.savedAt
            )
        }
        let undo = state.undoPage.map {
            KeelUndoItem(
                displayURL: $0.page.url.absoluteString,
                hostname: hostname(for: $0.page.url),
                title: titles[$0.page.url.absoluteString],
                icon: favicons?.icon(for: $0.page.url),
                deadline: $0.deadline
            )
        }
        let queue = runtime.queue.map {
            KeelQueueItem(
                id: $0.id,
                displayURL: $0.url.absoluteString,
                hostname: hostname(for: $0.url),
                title: titles[$0.url.absoluteString],
                icon: favicons?.icon(for: $0.url),
                capturedAt: $0.capturedAt,
                sequence: $0.sequence
            )
        }
        let queueDeletionUndo = runtime.queueDeletionUndo.map {
            KeelQueueDeletionUndoItem(
                deletedCount: $0.destinations.count,
                deadline: $0.deadline
            )
        }
        return KeelHomeModel(
            resume: resume,
            undo: undo,
            queue: queue,
            queueDeletionUndo: queueDeletionUndo,
            // Mirrors the coordinator's own guard, so Start is enabled exactly
            // when `openNextQueuedDestination` would actually do something.
            canStartQueue: state.activePage == nil && runtime.resumeCheckpoint == nil
        )
    }

    static func historyModel(
        activeSession: BrowsingSession?,
        endedSessions: [HistorySessionSummary],
        visitsBySession: [UUID: [HistoryVisit]],
        favicons: KeelNativeScreenFaviconCache? = nil,
        hasOlderSessions: Bool = false,
        searchQuery: String = "",
        searchReachedLimit: Bool = false
    ) -> (model: KeelHistoryModel, visitURLs: [UUID: URL]) {
        var sessions: [(id: UUID, startedAt: Date, endedAt: Date?)] = endedSessions.map { session in
            (id: session.id, startedAt: session.startedAt, endedAt: session.endedAt)
        }
        if let activeSession {
            sessions.append((id: activeSession.id, startedAt: activeSession.startedAt, endedAt: activeSession.endedAt))
        }

        var presentationVisits: [KeelHistoryVisit] = []
        var visitURLs: [UUID: URL] = [:]
        for (sessionID, visits) in visitsBySession {
            for visit in visits {
                let url = visit.url
                presentationVisits.append(
                    KeelHistoryVisit(
                        id: visit.id,
                        sessionID: visit.browsingSessionID,
                        branchID: visit.branchID.rawValue,
                        hostname: hostname(for: url),
                        displayURL: url.absoluteString,
                        title: visit.title,
                        icon: favicons?.icon(for: url),
                        visitedAt: visit.visitedAt,
                        hostnameGroupID: visit.hostnameGroupID
                    )
                )
                visitURLs[visit.id] = url
            }
            // A Store response keyed to the wrong session is not allowed to create a
            // second UI session. The visit's own ID remains the source of truth.
            _ = sessionID
        }

        var sessionDates: [UUID: (startedAt: Date, endedAt: Date?)] = [:]
        for session in sessions {
            sessionDates[session.id] = (session.startedAt, session.endedAt)
        }

        let grouped = KeelHistoryModel(
            visits: presentationVisits,
            sessionDates: sessionDates,
            hasOlderSessions: hasOlderSessions,
            searchQuery: searchQuery,
            searchReachedLimit: searchReachedLimit,
            hasAnyHistory: true
        )
        let groupedByID = Dictionary(uniqueKeysWithValues: grouped.sessions.map { ($0.id, $0) })
        let knownIDs = Set(sessions.map { $0.id }).union(grouped.sessions.map { $0.id })
        let orderedIDs = knownIDs.sorted { lhs, rhs in
            let left = sessionDates[lhs]?.startedAt ?? groupedByID[lhs]?.startedAt ?? .distantPast
            let right = sessionDates[rhs]?.startedAt ?? groupedByID[rhs]?.startedAt ?? .distantPast
            if left != right { return left > right }
            return lhs.uuidString < rhs.uuidString
        }
        let orderedSessions = orderedIDs.map { id in
            groupedByID[id] ?? KeelHistorySession(
                id: id,
                startedAt: sessionDates[id]?.startedAt ?? .distantPast,
                endedAt: sessionDates[id]?.endedAt,
                groups: []
            )
        }
        return (
            KeelHistoryModel(
                sessions: orderedSessions,
                hasOlderSessions: hasOlderSessions,
                searchQuery: searchQuery,
                searchReachedLimit: searchReachedLimit,
                hasAnyHistory: true
            ),
            visitURLs
        )
    }

    static func downloadModel(
        records: [DownloadRecord],
        liveSnapshots: [KeelDownloadSnapshot] = []
    ) -> KeelDownloadModel {
        var items = Dictionary(uniqueKeysWithValues: records.map { record in
            (record.id, KeelDownloadItem(
                id: record.id,
                hostname: record.hostname,
                filename: record.filename,
                path: record.pathReference,
                receivedBytes: record.byteCount,
                status: downloadStatus(for: record),
                createdAt: record.createdAt,
                completedAt: record.completedAt
            ))
        })

        // WebKit publishes a snapshot whenever progress or terminal state changes.
        // Merging that callback is deterministic and avoids a polling loop.
        for snapshot in liveSnapshots {
            items[snapshot.id] = KeelDownloadItem(
                id: snapshot.id,
                hostname: snapshot.sourceHostname,
                filename: snapshot.filename,
                path: snapshot.destinationURL?.path,
                receivedBytes: snapshot.receivedBytes,
                expectedBytes: snapshot.expectedBytes,
                status: downloadStatus(for: snapshot.state),
                createdAt: snapshot.createdAt,
                completedAt: snapshot.completedAt,
                bytesPerSecond: snapshot.bytesPerSecond,
                isStalled: snapshot.isStalled
            )
        }
        return KeelDownloadModel(items: Array(items.values))
    }

    static func settingsModel(
        from settings: KeelSettings,
        hasDiagnostics: Bool,
        downloadDirectoryPath: String? = nil,
        homeScenes: [KeelHomeSceneTile] = []
    ) -> KeelSettingsModel {
        let provider: KeelSearchProvider
        let customTemplate: String
        switch settings.searchProvider {
        case .google:
            provider = .google
            customTemplate = Self.placeholderSearchTemplate
        case .duckDuckGo:
            provider = .duckDuckGo
            customTemplate = Self.placeholderSearchTemplate
        case .kagi:
            provider = .kagi
            customTemplate = Self.placeholderSearchTemplate
        case let .custom(template):
            provider = .custom
            customTemplate = template
        }
        return KeelSettingsModel(
            searchProvider: provider,
            customSearchTemplate: customTemplate,
            queueExpiry: KeelQueueExpiry(rawValue: settings.queueRetention.rawValue) ?? .hours72,
            keepsClosedPageReady: settings.keepsClosedPageReady,
            appearance: appearanceOption(for: settings.appearance),
            defaultPageZoom: KeelPageZoom(rawValue: settings.defaultPageZoom.rawValue) ?? .percent100,
            downloadDirectoryPath: downloadDirectoryPath,
            hasDiagnostics: hasDiagnostics,
            homeSceneMode: homeSceneMode(for: settings.homeSceneMode),
            selectedHomeSceneID: settings.selectedHomeSceneID
                .flatMap(KeelHomeSceneID.init(storedValue:)) ?? .bundled("como"),
            homeScenes: homeScenes
        )
    }

    /// Carries every stored field through. The earlier narrow overloads rebuilt
    /// a `KeelSettings` from a partial model, so anything the model did not
    /// carry was silently reset. Callers now mutate `KeelSettings` directly.
    static func settings(from model: KeelSettingsModel, current: KeelSettings) -> KeelSettings {
        let searchProvider: SearchProvider
        switch model.searchProvider {
        case .google: searchProvider = .google
        case .duckDuckGo: searchProvider = .duckDuckGo
        case .kagi: searchProvider = .kagi
        case .custom: searchProvider = .custom(template: model.customSearchTemplate)
        }
        return KeelSettings(
            queueRetention: QueueRetention(rawValue: model.queueExpiry.rawValue) ?? current.queueRetention,
            keepsClosedPageReady: model.keepsClosedPageReady,
            searchProvider: searchProvider,
            diagnosticModeExpiresAt: current.diagnosticModeExpiresAt,
            appearance: appearanceMode(for: model.appearance),
            defaultPageZoom: PageZoomLevel(rawValue: model.defaultPageZoom.rawValue) ?? current.defaultPageZoom,
            downloadDirectoryBookmark: current.downloadDirectoryBookmark,
            homeSceneMode: homeSceneMode(for: model.homeSceneMode),
            selectedHomeSceneID: model.selectedHomeSceneID == .bundled("como")
                ? nil
                : model.selectedHomeSceneID.storedValue,
            homeSceneRotation: current.homeSceneRotation
        )
    }

    static func homeSceneMode(for mode: HomeSceneMode) -> KeelHomeSceneMode {
        switch mode {
        case .onePhoto: .onePhoto
        case .rotateMine: .rotateMine
        case .rotateAll: .rotateAll
        }
    }

    static func homeSceneMode(for mode: KeelHomeSceneMode) -> HomeSceneMode {
        switch mode {
        case .onePhoto: .onePhoto
        case .rotateMine: .rotateMine
        case .rotateAll: .rotateAll
        }
    }

    static func appearanceOption(for mode: AppearanceMode) -> KeelAppearanceOption {
        switch mode {
        case .system: .system
        case .light: .light
        case .dark: .dark
        }
    }

    static func appearanceMode(for option: KeelAppearanceOption) -> AppearanceMode {
        switch option {
        case .system: .system
        case .light: .light
        case .dark: .dark
        }
    }

    /// Rate and remaining time for the download shelf. KeelApp cannot see
    /// `KeelDownloadItem`, so the same wording is derived here from the snapshot.
    static func transferDetail(for snapshot: KeelDownloadSnapshot) -> String? {
        let item = KeelDownloadItem(
            id: snapshot.id,
            hostname: snapshot.sourceHostname,
            filename: snapshot.filename,
            receivedBytes: snapshot.receivedBytes,
            expectedBytes: snapshot.expectedBytes,
            status: downloadStatus(for: snapshot.state),
            createdAt: snapshot.createdAt,
            completedAt: snapshot.completedAt,
            bytesPerSecond: snapshot.bytesPerSecond,
            isStalled: snapshot.isStalled
        )
        guard let detail = item.progressMetricsDescription, !detail.isEmpty else { return nil }
        return detail
    }

    /// Shown only as a placeholder while a non-custom provider is selected.
    private static let placeholderSearchTemplate = "https://example.test/search?q={query}"

    private static func hostname(for url: URL) -> String {
        url.host?.lowercased() ?? url.scheme?.lowercased() ?? url.absoluteString
    }

    private static func downloadStatus(for record: DownloadRecord) -> KeelDownloadStatus {
        switch record.state {
        case .inProgress: .inProgress
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed:
            if record.errorCode == KeelDownloadErrorCode.interruptedAfterRestart {
                .failed(message: "Keel quit before this download finished.")
            } else {
                .failed(message: record.errorCode.map(String.init))
            }
        }
    }

    private static func downloadStatus(for state: KeelDownloadState) -> KeelDownloadStatus {
        switch state {
        case .inProgress: .inProgress
        case .completed: .completed
        case .cancelled: .cancelled
        case let .failed(errorCode): .failed(message: errorCode.map(String.init))
        }
    }
}
