import Foundation

public enum KeelQueueExpiry: Int, CaseIterable, Equatable, Sendable, Identifiable {
    case hours24 = 86_400
    case hours72 = 259_200
    case days7 = 604_800

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .hours24: "24 hours"
        case .hours72: "72 hours"
        case .days7: "7 days"
        }
    }
}
