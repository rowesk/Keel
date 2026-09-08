import Foundation

/// What History currently has on screen. It holds one page of sessions at a
/// time, or the results of one Store-backed search, never the whole record.
public struct KeelHistoryModel: Equatable, Sendable {
    public let sessions: [KeelHistorySession]
    public let allVisitIDs: [UUID]
    /// Older sessions remain in the Store. The view offers Load older while this
    /// is true and no search is running.
    public let hasOlderSessions: Bool
    /// The app is fetching the next page right now.
    public let isLoadingOlderSessions: Bool
    /// The query these sessions answer. Empty means this is the browse list.
    public let searchQuery: String
    /// The app is running a search whose results have not arrived. The view
    /// waits rather than claiming there are no matches.
    public let isSearching: Bool
    /// The Store's search bound cut the results, so older matches exist.
    public let searchReachedLimit: Bool
    /// History holds at least one visit. The browse list can be empty mid-search
    /// without History being empty, so Delete all reads this instead.
    public let hasAnyHistory: Bool

    public init(
        sessions: [KeelHistorySession] = [],
        hasOlderSessions: Bool = false,
        isLoadingOlderSessions: Bool = false,
        searchQuery: String = "",
        isSearching: Bool = false,
        searchReachedLimit: Bool = false,
        hasAnyHistory: Bool? = nil
    ) {
        self.sessions = sessions
        self.allVisitIDs = sessions.flatMap { $0.visits.map(\.id) }
        self.hasOlderSessions = hasOlderSessions
        self.isLoadingOlderSessions = isLoadingOlderSessions
        self.searchQuery = searchQuery
        self.isSearching = isSearching
        self.searchReachedLimit = searchReachedLimit
        self.hasAnyHistory = hasAnyHistory ?? !sessions.isEmpty
    }

    /// Builds the UI hierarchy in one pass over date-ordered visits. A new
    /// hostname group starts when the Store group identity changes. The Store
    /// owns the hostname and branch invariants for each group.
    public init(
        visits: [KeelHistoryVisit],
        sessionDates: [UUID: (startedAt: Date, endedAt: Date?)] = [:],
        hasOlderSessions: Bool = false,
        isLoadingOlderSessions: Bool = false,
        searchQuery: String = "",
        isSearching: Bool = false,
        searchReachedLimit: Bool = false,
        hasAnyHistory: Bool? = nil
    ) {
        var groupedSessions: [UUID: [KeelHistoryHostnameGroup]] = [:]
        var sessionOrder: [UUID] = []
        var currentGroupBySession: [UUID: KeelHistoryHostnameGroup] = [:]

        let orderedVisits = visits.enumerated().sorted {
            if $0.element.visitedAt != $1.element.visitedAt {
                return $0.element.visitedAt < $1.element.visitedAt
            }
            return $0.offset < $1.offset
        }.map(\.element)

        for visit in orderedVisits {
            if groupedSessions[visit.sessionID] == nil {
                groupedSessions[visit.sessionID] = []
                sessionOrder.append(visit.sessionID)
            }

            if let current = currentGroupBySession[visit.sessionID],
               current.id == visit.hostnameGroupID {
                let replacement = KeelHistoryHostnameGroup(
                    id: current.id,
                    sessionID: current.sessionID,
                    branchID: current.branchID,
                    hostname: current.hostname,
                    visits: current.visits + [visit],
                    firstVisitedAt: min(current.firstVisitedAt, visit.visitedAt),
                    lastVisitedAt: max(current.lastVisitedAt, visit.visitedAt)
                )
                currentGroupBySession[visit.sessionID] = replacement
                groupedSessions[visit.sessionID]?.removeLast()
                groupedSessions[visit.sessionID]?.append(replacement)
            } else {
                let group = KeelHistoryHostnameGroup(
                    id: visit.hostnameGroupID,
                    sessionID: visit.sessionID,
                    branchID: visit.branchID,
                    hostname: visit.hostname,
                    visits: [visit]
                )
                currentGroupBySession[visit.sessionID] = group
                groupedSessions[visit.sessionID]?.append(group)
            }
        }

        let builtSessions = sessionOrder.map { sessionID in
            let groups = groupedSessions[sessionID] ?? []
            let dates = sessionDates[sessionID]
            return KeelHistorySession(
                id: sessionID,
                startedAt: dates?.startedAt ?? groups.first?.firstVisitedAt ?? .distantPast,
                endedAt: dates?.endedAt ?? groups.last?.lastVisitedAt,
                groups: groups
            )
        }
        self.sessions = builtSessions
        self.allVisitIDs = builtSessions.flatMap { $0.visits.map(\.id) }
        self.hasOlderSessions = hasOlderSessions
        self.isLoadingOlderSessions = isLoadingOlderSessions
        self.searchQuery = searchQuery
        self.isSearching = isSearching
        self.searchReachedLimit = searchReachedLimit
        self.hasAnyHistory = hasAnyHistory ?? !builtSessions.isEmpty
    }

    public var isEmpty: Bool {
        sessions.isEmpty
    }

    /// True while the reader is filtering. The view shows search results and
    /// hides Load older, which pages the browse list rather than the results.
    public var isSearchActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var allVisits: [KeelHistoryVisit] {
        sessions.flatMap(\.visits)
    }

    public static func fixture(sessionCount: Int, visitsPerSession: Int) -> KeelHistoryModel {
        let safeSessionCount = max(0, sessionCount)
        let safeVisitCount = max(0, visitsPerSession)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        var visits: [KeelHistoryVisit] = []
        visits.reserveCapacity(safeSessionCount * safeVisitCount)

        for sessionIndex in 0..<safeSessionCount {
            let sessionID = UUID()
            for visitIndex in 0..<safeVisitCount {
                let hostname = visitIndex.isMultiple(of: 2) ? "docs.example.test" : "mail.example.test"
                visits.append(
                    KeelHistoryVisit(
                        id: UUID(),
                        sessionID: sessionID,
                        hostname: hostname,
                        displayURL: "https://\(hostname)/item/\(visitIndex)",
                        title: "Item \(visitIndex)",
                        visitedAt: baseDate.addingTimeInterval(TimeInterval(sessionIndex * 10_000 + visitIndex))
                    )
                )
            }
        }
        return KeelHistoryModel(visits: visits)
    }
}
