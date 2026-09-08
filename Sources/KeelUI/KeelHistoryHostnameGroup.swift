import Foundation

public struct KeelHistoryHostnameGroup: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let branchID: String
    public let hostname: String
    public let visits: [KeelHistoryVisit]
    public let firstVisitedAt: Date
    public let lastVisitedAt: Date

    public init(
        id: UUID,
        sessionID: UUID,
        branchID: String,
        hostname: String,
        visits: [KeelHistoryVisit]
    ) {
        self.init(
            id: id,
            sessionID: sessionID,
            branchID: branchID,
            hostname: hostname,
            visits: visits,
            firstVisitedAt: visits.map(\.visitedAt).min() ?? .distantPast,
            lastVisitedAt: visits.map(\.visitedAt).max() ?? .distantPast
        )
    }

    init(
        id: UUID,
        sessionID: UUID,
        branchID: String,
        hostname: String,
        visits: [KeelHistoryVisit],
        firstVisitedAt: Date,
        lastVisitedAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.branchID = branchID
        self.hostname = hostname
        self.visits = visits
        self.firstVisitedAt = firstVisitedAt
        self.lastVisitedAt = lastVisitedAt
    }
}
