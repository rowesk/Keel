import Foundation

/// Commands emitted by Home. The coordinator decides how each command changes
/// the browser; Home never opens a queued destination directly.
public enum KeelHomeAction: Equatable, Sendable {
    case openAddress
    case resume
    case restoreClosedPage
    case discardResume
    case discardClosedPage
    /// Consumes the oldest queued destination. Home asks; the coordinator decides
    /// whether the queue may advance, so FIFO order is never skipped here.
    case startQueue
    case selectQueueItem(UUID)
    case deleteQueueItems(Set<UUID>)
    case clearQueue
    case restoreQueueDeletionUndo
    case showHistory
    case showDownloads
    case showSettings
}
