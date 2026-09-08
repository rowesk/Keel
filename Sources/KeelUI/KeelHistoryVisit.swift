import Foundation

/// A History visit in the presentation layer. `branchID` stays a string so
/// KeelUI does not depend on the Store's branch type.
public struct KeelHistoryVisit: Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    /// The Store-owned identity for the consecutive-hostname group.
    ///
    /// Standalone presentation fixtures may omit this value. In that case the
    /// visit identity provides a deterministic one-visit group identity.
    public let hostnameGroupID: UUID
    public let sessionID: UUID
    public let branchID: String
    public let hostname: String
    public let displayURL: String
    public let title: String?
    public let icon: KeelIconImage?
    public let visitedAt: Date

    public init(
        id: UUID,
        sessionID: UUID,
        branchID: String = "root",
        hostname: String,
        displayURL: String,
        title: String? = nil,
        icon: KeelIconImage? = nil,
        visitedAt: Date,
        hostnameGroupID: UUID? = nil
    ) {
        self.id = id
        self.hostnameGroupID = hostnameGroupID ?? id
        self.sessionID = sessionID
        self.branchID = branchID
        self.hostname = hostname
        self.displayURL = displayURL
        self.title = title
        self.icon = icon
        self.visitedAt = visitedAt
    }

    /// What the row leads with. A page title when Keel recorded one.
    public var primaryText: String {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return hostname
        }
        return title
    }

    public var secondaryText: String {
        displayURL.keelDisplayAddress
    }
}
