import Foundation

public enum HistoryNavigationKind: String, Codable, CaseIterable, Sendable {
    case document
    case redirect
    case reload
    case back
    case forward
    case pushState
    case popState
    case hashNavigation
    case replaceState
}

/// WebKit and the coordinator supply this meaning. History does not infer intent from a URL.
public enum HistoryVisitSource: String, Codable, CaseIterable, Sendable {
    case typedAddress
    case link
    case external
    case history
    case suggestion
    case queueConsumption
    case resume
}

public struct HistoryBranchID: Codable, Equatable, Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum HistoryBranch: Codable, Equatable, Sendable {
    case root
    case transactionalDetour(id: UUID)

    func identifier(for sessionID: UUID) -> HistoryBranchID {
        switch self {
        case .root:
            HistoryBranchID(rawValue: "root:\(sessionID.uuidString.lowercased())")
        case let .transactionalDetour(id):
            HistoryBranchID(rawValue: "detour:\(sessionID.uuidString.lowercased()):\(id.uuidString.lowercased())")
        }
    }

    var storedKind: String {
        switch self {
        case .root: "root"
        case .transactionalDetour: "detour"
        }
    }
}

public struct HistoryVisitEvent: Sendable {
    public let id: UUID
    public let url: URL
    public let title: String?
    public let visitedAt: Date
    public let browsingSessionID: UUID
    public let branch: HistoryBranch
    public let navigationKind: HistoryNavigationKind
    public let source: HistoryVisitSource
    public let currentVisitID: UUID?
    public let faviconReferenceKey: String?

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String? = nil,
        visitedAt: Date,
        browsingSessionID: UUID,
        branch: HistoryBranch = .root,
        navigationKind: HistoryNavigationKind = .document,
        source: HistoryVisitSource,
        currentVisitID: UUID? = nil,
        faviconReferenceKey: String? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
        self.browsingSessionID = browsingSessionID
        self.branch = branch
        self.navigationKind = navigationKind
        self.source = source
        self.currentVisitID = currentVisitID
        self.faviconReferenceKey = faviconReferenceKey
    }
}

public struct HistoryVisit: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public let title: String?
    public let visitedAt: Date
    public let browsingSessionID: UUID
    public let branchID: HistoryBranchID
    public let navigationKind: HistoryNavigationKind
    public let source: HistoryVisitSource
    public let hostnameGroupID: UUID

    public init(
        id: UUID,
        url: URL,
        title: String?,
        visitedAt: Date,
        browsingSessionID: UUID,
        branchID: HistoryBranchID,
        navigationKind: HistoryNavigationKind,
        source: HistoryVisitSource,
        hostnameGroupID: UUID
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
        self.browsingSessionID = browsingSessionID
        self.branchID = branchID
        self.navigationKind = navigationKind
        self.source = source
        self.hostnameGroupID = hostnameGroupID
    }
}

public struct HistoryHostnameGroup: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let browsingSessionID: UUID
    public let branchID: HistoryBranchID
    public let hostname: String
    public let firstVisitedAt: Date
    public let lastVisitedAt: Date

    public init(id: UUID, browsingSessionID: UUID, branchID: HistoryBranchID, hostname: String, firstVisitedAt: Date, lastVisitedAt: Date) {
        self.id = id
        self.browsingSessionID = browsingSessionID
        self.branchID = branchID
        self.hostname = hostname
        self.firstVisitedAt = firstVisitedAt
        self.lastVisitedAt = lastVisitedAt
    }
}

public struct HistoryCandidate: Codable, Equatable, Sendable, Identifiable {
    public let id: Int64
    public let url: URL
    public let displayURL: String
    public let hostname: String
    public let title: String?
    public let faviconReferenceKey: String?
    public let visitCount: Int
    public let typedCount: Int
    public let lastVisitedAt: Date
    public let lastTypedAt: Date?
    public let addressChoiceCount: Int
    public let lastAddressChoiceAt: Date?

    public init(id: Int64, url: URL, displayURL: String, hostname: String, title: String?, faviconReferenceKey: String?, visitCount: Int, typedCount: Int, lastVisitedAt: Date, lastTypedAt: Date?, addressChoiceCount: Int, lastAddressChoiceAt: Date?) {
        self.id = id
        self.url = url
        self.displayURL = displayURL
        self.hostname = hostname
        self.title = title
        self.faviconReferenceKey = faviconReferenceKey
        self.visitCount = visitCount
        self.typedCount = typedCount
        self.lastVisitedAt = lastVisitedAt
        self.lastTypedAt = lastTypedAt
        self.addressChoiceCount = addressChoiceCount
        self.lastAddressChoiceAt = lastAddressChoiceAt
    }
}

/// How a local History destination matched the address palette input.
///
/// The cases are deliberately ordered from weakest to strongest so callers can
/// make a safe default selection without reconstructing Store ranking rules.
public enum HistorySuggestionMatchQuality: Int, Codable, CaseIterable, Comparable, Sendable {
    case contiguousSubstring = 250
    case tokenBoundaryPrefix = 500
    case hostnamePrefix = 700
    case exactURLOrHostname = 1_000

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The stored History field that supplied a suggestion match. No typed input
/// leaves the Store through this value.
public enum HistorySuggestionMatchField: String, Codable, CaseIterable, Sendable {
    case canonicalURL
    case hostname
    case path
    case title
    case mixed
}

public struct HistorySuggestionMatch: Codable, Equatable, Sendable {
    public let quality: HistorySuggestionMatchQuality
    public let field: HistorySuggestionMatchField

    public init(quality: HistorySuggestionMatchQuality, field: HistorySuggestionMatchField) {
        self.quality = quality
        self.field = field
    }
}

/// One local History destination suitable for the address palette.
public struct HistorySuggestion: Codable, Equatable, Sendable, Identifiable {
    public let historyURLID: Int64
    public let url: URL
    public let displayURL: String
    public let hostname: String
    public let title: String?
    public let faviconReferenceKey: String?
    public let match: HistorySuggestionMatch
    public let visitCount: Int
    public let typedCount: Int
    public let lastVisitedAt: Date
    public let lastTypedAt: Date?
    public let addressChoiceCount: Int
    public let lastAddressChoiceAt: Date?
    public let score: Double

    public var id: Int64 { historyURLID }

    public init(
        historyURLID: Int64,
        url: URL,
        displayURL: String,
        hostname: String,
        title: String?,
        faviconReferenceKey: String?,
        match: HistorySuggestionMatch,
        visitCount: Int,
        typedCount: Int,
        lastVisitedAt: Date,
        lastTypedAt: Date? = nil,
        addressChoiceCount: Int,
        lastAddressChoiceAt: Date?,
        score: Double = 0
    ) {
        self.historyURLID = historyURLID
        self.url = url
        self.displayURL = displayURL
        self.hostname = hostname
        self.title = title
        self.faviconReferenceKey = faviconReferenceKey
        self.match = match
        self.visitCount = visitCount
        self.typedCount = typedCount
        self.lastVisitedAt = lastVisitedAt
        self.lastTypedAt = lastTypedAt
        self.addressChoiceCount = addressChoiceCount
        self.lastAddressChoiceAt = lastAddressChoiceAt
        self.score = score
    }
}

/// A bounded, local-only address-palette lookup. It intentionally does not
/// retain the raw text entered into the palette.
public struct HistorySuggestionResult: Codable, Equatable, Sendable {
    public let suggestions: [HistorySuggestion]
    public let defaultSuggestionID: Int64?

    public init(suggestions: [HistorySuggestion], defaultSuggestionID: Int64? = nil) {
        self.suggestions = suggestions
        self.defaultSuggestionID = defaultSuggestionID
    }
}

/// An ended browsing session with the information History needs to show a compact session row.
public struct HistorySessionSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let firstVisitedAt: Date
    public let lastVisitedAt: Date
    public let visitCount: Int
    public let hostname: String
    public let title: String?
    public let displayURL: String
    public let faviconReferenceKey: String?

    public init(id: UUID, startedAt: Date, endedAt: Date, firstVisitedAt: Date, lastVisitedAt: Date, visitCount: Int, hostname: String, title: String?, displayURL: String, faviconReferenceKey: String?) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.firstVisitedAt = firstVisitedAt
        self.lastVisitedAt = lastVisitedAt
        self.visitCount = visitCount
        self.hostname = hostname
        self.title = title
        self.displayURL = displayURL
        self.faviconReferenceKey = faviconReferenceKey
    }
}

/// Where the next page of ended sessions starts. It names the last row of the
/// page just read, so a session recorded in between cannot shift the reader.
public struct HistorySessionCursor: Codable, Equatable, Sendable {
    public let lastVisitedAt: Date
    public let sessionID: UUID

    public init(lastVisitedAt: Date, sessionID: UUID) {
        self.lastVisitedAt = lastVisitedAt
        self.sessionID = sessionID
    }
}

/// One bounded page of ended sessions, newest first. A nil `nextCursor` means
/// nothing older remains.
public struct HistorySessionPage: Codable, Equatable, Sendable {
    public let sessions: [HistorySessionSummary]
    public let nextCursor: HistorySessionCursor?

    public init(sessions: [HistorySessionSummary], nextCursor: HistorySessionCursor?) {
        self.sessions = sessions
        self.nextCursor = nextCursor
    }
}

/// Visits matching a History search, newest first, with the summaries of the
/// ended sessions they belong to. `reachedLimit` is true when the bound cut the
/// result set, so the caller can say the list is partial.
public struct HistorySearchResult: Codable, Equatable, Sendable {
    public let visits: [HistoryVisit]
    public let sessions: [HistorySessionSummary]
    public let reachedLimit: Bool

    public init(visits: [HistoryVisit], sessions: [HistorySessionSummary], reachedLimit: Bool) {
        self.visits = visits
        self.sessions = sessions
        self.reachedLimit = reachedLimit
    }
}

public enum HistoryDeletionScope: Sendable {
    case visits(Set<UUID>)
    case hostnameGroup(sessionID: UUID, branchID: HistoryBranchID, groupID: UUID)
    case session(UUID)
    case all
}

public enum HistoryStoreError: Error, Equatable, Sendable {
    case invalidURL
    case missingBrowsingSession
    case missingCurrentVisit
    case invalidCurrentVisit
    case missingHistoryURL
    case invalidCandidateLimit
    case invalidSuggestionLimit
    case invalidAddressChoiceInput
    case invalidSessionPageLimit
    case invalidSearchLimit
    case tooManySessions
}
