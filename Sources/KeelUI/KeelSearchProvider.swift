import Foundation

public enum KeelSearchProvider: Equatable, Sendable {
    case google
    case duckDuckGo
    case kagi
    case custom

    public var label: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .kagi: "Kagi"
        case .custom: "Custom"
        }
    }
}
