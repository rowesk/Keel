import Foundation

public enum KeelDownloadStatus: Equatable, Hashable, Sendable {
    case inProgress
    case completed
    case cancelled
    case failed(message: String?)

    public var label: String {
        switch self {
        case .inProgress: "Downloading"
        case .completed: "Downloaded"
        case .cancelled: "Cancelled"
        case .failed: "Download failed"
        }
    }

    public var isInProgress: Bool {
        self == .inProgress
    }
}
