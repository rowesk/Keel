import Foundation
import KeelStore

public enum KeelCoordinatorEvent: Sendable {
    case showHome
    case returnToActivePage
    case showManagement(KeelManagementScreen)
    case dismissManagement
    case closePage(pageID: UUID)
    case restoreCloseUndo
    case discardCloseUndo
    case closeUndoExpired(pageID: UUID, deadline: Date)
    case resumeCheckpoint
    case preserveFailedResumeBeforeOpen(pageID: UUID, navigationID: UUID, checkpoint: ResumeCheckpoint)
    case discardResumeCheckpoint
    case requeueResumeAndOpenNext
    case openNextQueuedDestination
    case openTypedURL(URL)
    case openHistoryURL(URL)
    /// A History row the address palette has explicitly selected. The stable URL ID lets
    /// the Store safely record adaptive choice use without trusting a display string.
    case selectHistorySuggestion(
        historyURLID: Int64,
        typedInput: String,
        disposition: KeelHistorySuggestionDisposition
    )
    case addURLToQueue(URL)
    /// Queue deletion is only emitted after the management UI's local confirmation.
    case removeQueuedDestinations(ids: Set<UUID>)
    case clearQueuedDestinations
    case restoreQueueDeletionUndo
    case queueDeletionUndoExpired(deadline: Date)
    /// History deletion intentionally changes only Keel's local History database. It
    /// must not clear cookies or other website data.
    case deleteHistory(KeelHistoryDeletionRequest)
    case replaceSettings(KeelSettings)
    /// Persists a WebKit download boundary and publishes the resulting runtime state.
    /// Progress snapshots stay outside coordinator state until the transfer reaches a
    /// lifecycle boundary.
    case updateDownload(DownloadRecord)
    case removeDownloads(ids: Set<UUID>)
    case openDownload(id: UUID)
    case revealDownload(id: UUID)
    case cancelDownload(id: UUID)
    case exportDiagnostics
    case deleteDiagnostics
    case receiveExternalURL(URL)
    case navigationStarted(pageID: UUID, replacingNavigationID: UUID, navigationID: UUID)
    case navigated(pageID: UUID, navigationID: UUID, to: URL)
    case saveResumeCheckpoint(pageID: UUID, navigationID: UUID, interactionState: Data?)
    case technicalFailure(pageID: UUID, navigationID: UUID)
    case requeueAndClose(pageID: UUID)
    case requestTransactionalDetour(id: UUID, url: URL)
    case closeTransactionalDetour(detourID: UUID)
    case recoverSoleWindow
}
