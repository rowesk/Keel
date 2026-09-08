import Foundation

public enum KeelQueueDeletionRequest: Equatable, Sendable, Identifiable {
    case selected(Set<UUID>)
    case all

    public var id: String {
        switch self {
        case let .selected(ids):
            "selected-\(ids.map(\.uuidString).sorted().joined(separator: ","))"
        case .all: "all"
        }
    }

    public var confirmationTitle: String {
        switch self {
        case let .selected(ids):
            ids.count == 1 ? "Remove this queued page?" : "Remove \(ids.count) queued pages?"
        case .all:
            "Clear the queue?"
        }
    }

    public var confirmationMessage: String {
        "Keel keeps this deletion available to undo for 60 seconds. It will not change website data."
    }

    public var selectedIDs: Set<UUID> {
        switch self {
        case let .selected(ids): ids
        case .all: []
        }
    }
}
