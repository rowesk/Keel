import Foundation

public enum KeelHistoryAction: Equatable, Sendable {
    case dismiss
    case openVisit(UUID)
    case deleteVisit(UUID)
    case deleteVisits(Set<UUID>)
    case deleteHostnameGroup(sessionID: UUID, branchID: String, groupID: UUID)
    case deleteSession(UUID)
    case deleteAll
    /// The reader reached the end of the loaded sessions and asked for the next
    /// page. The app appends the page to the model it already gave the view.
    case loadOlderSessions
    /// The filter text changed. An empty string means the reader cleared it and
    /// wants the paged browse list back. Every query runs in the Store, so it
    /// reaches visits no page ever loaded.
    case search(String)
}
