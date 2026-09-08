import Foundation

public struct KeelQueueItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let displayURL: String
    public let hostname: String
    public let title: String?
    public let icon: KeelIconImage?
    public let capturedAt: Date
    public let sequence: Int64

    public init(
        id: UUID,
        displayURL: String,
        hostname: String,
        title: String? = nil,
        icon: KeelIconImage? = nil,
        capturedAt: Date,
        sequence: Int64
    ) {
        self.id = id
        self.displayURL = displayURL
        self.hostname = hostname
        self.title = title
        self.icon = icon
        self.capturedAt = capturedAt
        self.sequence = sequence
    }

    /// What the row leads with. A page title when Keel knows one, the hostname otherwise.
    public var primaryText: String {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return hostname
        }
        return title
    }

    /// The address as a place, not as a string. Never the raw `absoluteString`.
    public var secondaryText: String {
        displayURL.keelDisplayAddress
    }

    public var accessibilitySummary: String {
        "\(primaryText), \(hostname), captured \(capturedAt.keelRelativeDescription())"
    }
}
