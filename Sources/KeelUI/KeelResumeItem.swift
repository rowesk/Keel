import Foundation

public struct KeelResumeItem: Equatable, Sendable {
    public let displayURL: String
    public let hostname: String
    public let title: String?
    public let icon: KeelIconImage?
    public let savedAt: Date

    public init(
        displayURL: String,
        hostname: String,
        title: String? = nil,
        icon: KeelIconImage? = nil,
        savedAt: Date
    ) {
        self.displayURL = displayURL
        self.hostname = hostname
        self.title = title
        self.icon = icon
        self.savedAt = savedAt
    }

    public var primaryText: String {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return hostname
        }
        return title
    }

    public var secondaryText: String {
        displayURL.keelDisplayAddress
    }

    public var accessibilitySummary: String {
        "\(primaryText), \(hostname), saved \(savedAt.keelRelativeDescription())"
    }
}
