import Foundation

public enum KeelHistoryDeletionRequest: Equatable, Sendable, Identifiable {
    case visit(UUID)
    case selected(Set<UUID>)
    case hostnameGroup(sessionID: UUID, branchID: String, groupID: UUID)
    case session(UUID)
    case all

    public var id: String {
        switch self {
        case let .visit(id): "visit-\(id.uuidString)"
        case let .selected(ids): "selected-\(ids.map(\.uuidString).sorted().joined(separator: ","))"
        case let .hostnameGroup(sessionID, branchID, groupID): "group-\(sessionID.uuidString)-\(branchID)-\(groupID.uuidString)"
        case let .session(id): "session-\(id.uuidString)"
        case .all: "all"
        }
    }

    public var confirmationTitle: String {
        switch self {
        case .visit: "Delete this History visit?"
        case let .selected(ids): ids.count == 1 ? "Delete this History visit?" : "Delete \(ids.count) History visits?"
        case .hostnameGroup: "Delete this hostname group?"
        case .session: "Delete this browsing session?"
        case .all: "Delete all History?"
        }
    }

    public var confirmationMessage: String {
        "This removes Keel's local History only. Cookies and website data remain."
    }
}
