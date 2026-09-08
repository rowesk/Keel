import Foundation

public struct KeelUndoItem: Equatable, Sendable {
    public let displayURL: String
    public let hostname: String
    public let title: String?
    public let icon: KeelIconImage?
    public let deadline: Date

    public init(
        displayURL: String,
        hostname: String,
        title: String? = nil,
        icon: KeelIconImage? = nil,
        deadline: Date
    ) {
        self.displayURL = displayURL
        self.hostname = hostname
        self.title = title
        self.icon = icon
        self.deadline = deadline
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
        "\(primaryText), \(hostname), \(deadline.keelCountdownDescription() ?? "expired")"
    }
}
