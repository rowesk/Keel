import Foundation

public enum KeelDownloadDeletionRequest: Equatable, Sendable, Identifiable {
    case record(UUID)
    case selected(Set<UUID>)
    case all

    public var id: String {
        switch self {
        case let .record(id): "record-\(id.uuidString)"
        case let .selected(ids): "selected-\(ids.map(\.uuidString).sorted().joined(separator: ","))"
        case .all: "all"
        }
    }

    public var title: String {
        switch self {
        case .record: "Delete this download record?"
        case let .selected(ids): ids.count == 1 ? "Delete this download record?" : "Delete \(ids.count) download records?"
        case .all: "Delete all download records?"
        }
    }
}
