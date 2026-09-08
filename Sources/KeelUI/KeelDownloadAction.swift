import Foundation

public enum KeelDownloadAction: Equatable, Sendable {
    case dismiss
    case open(UUID)
    case showInFinder(UUID)
    case cancel(UUID)
    case deleteRecords(Set<UUID>)
    case deleteAllRecords
}
