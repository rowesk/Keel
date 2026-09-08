import Foundation

public struct KeelHistorySession: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date?
    public let groups: [KeelHistoryHostnameGroup]

    public init(id: UUID, startedAt: Date, endedAt: Date? = nil, groups: [KeelHistoryHostnameGroup]) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.groups = groups
    }

    public var visits: [KeelHistoryVisit] {
        groups.flatMap(\.visits)
    }
}
