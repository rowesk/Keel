import Foundation

public struct KeelPaths: Sendable, Equatable {
    public let applicationSupportDirectory: URL
    public let databaseURL: URL
    public let diagnosticsDirectory: URL
    /// Favicon bytes fetched from the network. Discardable: deleting it costs one refetch.
    public let faviconCacheDirectory: URL
    /// Photographs the user imported for Home. Not discardable: the originals live outside the container.
    public let homeScenesDirectory: URL

    public init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
        databaseURL = applicationSupportDirectory.appending(path: "Keel.sqlite3")
        diagnosticsDirectory = applicationSupportDirectory.appending(path: "Diagnostics", directoryHint: .isDirectory)
        faviconCacheDirectory = applicationSupportDirectory.appending(path: "Favicons", directoryHint: .isDirectory)
        homeScenesDirectory = applicationSupportDirectory.appending(path: "HomeScenes", directoryHint: .isDirectory)
    }
}

public enum KeelPathProvider {
    public static let applicationSupportDirectoryName = "Keel"

    public static func paths(
        applicationSupportBaseURL: URL
    ) -> KeelPaths {
        KeelPaths(
            applicationSupportDirectory: applicationSupportBaseURL.appending(
                path: applicationSupportDirectoryName,
                directoryHint: .isDirectory
            )
        )
    }

    public static func paths(fileManager: FileManager = .default) throws -> KeelPaths {
        guard let applicationSupportBaseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw KeelPathError.applicationSupportDirectoryUnavailable
        }

        return paths(applicationSupportBaseURL: applicationSupportBaseURL)
    }
}

public enum KeelPathError: Error, Equatable {
    case applicationSupportDirectoryUnavailable
}
