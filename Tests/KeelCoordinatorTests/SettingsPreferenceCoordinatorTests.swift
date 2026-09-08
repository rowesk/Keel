@testable import KeelCoordinator
@testable import KeelStore
import Foundation
import Testing

@Suite("Settings preferences through the coordinator")
struct SettingsPreferenceCoordinatorTests {
    @Test("replacing settings publishes the new appearance, zoom and download directory")
    func replaceSettingsPublishesPreferences() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "KeelSettingsCoordinatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 10_000)
        let store = try KeelStore(databaseURL: directory.appending(path: "Keel.sqlite3"), now: { now })
        let coordinator = KeelCoordinator(store: store, now: { now }, makeID: { UUID() })
        _ = try await coordinator.start()

        let settings = KeelSettings(
            appearance: .light,
            defaultPageZoom: .percent150,
            downloadDirectoryBookmark: try DownloadDirectoryBookmark.make(for: directory)
        )
        let result = try await coordinator.handle(.replaceSettings(settings))

        #expect(result.state?.runtimeState.settings == settings)
        #expect(result.effects == [.refreshManagementData])
    }
}
