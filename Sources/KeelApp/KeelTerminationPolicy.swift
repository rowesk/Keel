import KeelWeb

@MainActor
enum KeelTerminationPolicy {
    static func hasInProgressDownloads(_ downloads: [KeelDownloadSnapshot]) -> Bool {
        downloads.contains { $0.state == .inProgress }
    }
}
