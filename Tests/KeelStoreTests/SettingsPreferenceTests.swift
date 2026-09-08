@testable import KeelStore
import Foundation
import Testing

@Suite("Settings preferences")
struct SettingsPreferenceTests {
    @Test("a fresh store starts on system appearance, 100 percent zoom and the Downloads folder")
    func freshStoreDefaults() async throws {
        let fixture = try PreferenceFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)

        let settings = try await store.runtimeState().settings
        #expect(settings.appearance == .system)
        #expect(settings.defaultPageZoom == .percent100)
        #expect(settings.downloadDirectoryBookmark == nil)
    }

    @Test("appearance, default zoom and download directory survive a reopen")
    func preferencesRoundTrip() async throws {
        let fixture = try PreferenceFixture()
        defer { fixture.remove() }
        let bookmark = try DownloadDirectoryBookmark.make(for: fixture.directory)
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let settings = KeelSettings(
            appearance: .dark,
            defaultPageZoom: .percent125,
            downloadDirectoryBookmark: bookmark
        )

        _ = try await store.apply([.replaceSettings(settings)])
        let reopened = try KeelStore(databaseURL: fixture.databaseURL)
        let restored = try await reopened.runtimeState().settings

        #expect(restored == settings)
        #expect(restored.defaultPageZoom.scale == 1.25)
    }

    @Test("a stored record written before these preferences existed still decodes")
    func legacyRecordDecodes() throws {
        let current = KeelSettings(queueRetention: .days7, keepsClosedPageReady: false, searchProvider: .kagi)
        let encoded = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(current))
        var fields = try #require(encoded as? [String: Any])
        fields.removeValue(forKey: "appearance")
        fields.removeValue(forKey: "defaultPageZoom")
        fields.removeValue(forKey: "downloadDirectoryBookmark")
        let legacy = try JSONSerialization.data(withJSONObject: fields)

        let decoded = try JSONDecoder().decode(KeelSettings.self, from: legacy)

        #expect(decoded == current)
        #expect(decoded.appearance == .system)
        #expect(decoded.defaultPageZoom == .percent100)
        #expect(decoded.downloadDirectoryBookmark == nil)
    }

    @Test("a database migrated from the earlier schema keeps its settings and gains the defaults")
    func migrationPreservesEarlierSettings() async throws {
        let fixture = try PreferenceFixture()
        defer { fixture.remove() }
        let earlier = KeelStore.migrations.filter { $0.identifier != "state.0002" }
        let database = try SQLiteDatabase(url: fixture.databaseURL)
        try KeelStoreMigrationRunner.apply(database, migrations: earlier)
        try database.execute("UPDATE settings SET search_provider = 'kagi', keeps_closed_page_ready = 0 WHERE singleton = 1")

        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let settings = try await store.runtimeState().settings

        #expect(settings.searchProvider == .kagi)
        #expect(settings.keepsClosedPageReady == false)
        #expect(settings.appearance == .system)
        #expect(settings.defaultPageZoom == .percent100)
        #expect(settings.downloadDirectoryBookmark == nil)
    }

    @Test("the download directory bookmark resolves back to the directory it was made from")
    func bookmarkResolvesToSameDirectory() throws {
        let fixture = try PreferenceFixture()
        defer { fixture.remove() }
        let chosen = fixture.directory.appending(path: "Papers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let bookmark = try DownloadDirectoryBookmark.make(for: chosen)

        let resolved = try DownloadDirectoryBookmark.withAccess(bookmark) { url, isStale in
            (path: url.resolvingSymlinksInPath().path(percentEncoded: false), isStale: isStale)
        }

        #expect(resolved.path == chosen.resolvingSymlinksInPath().path(percentEncoded: false))
        #expect(resolved.isStale == false)
    }

    @Test("a bookmark Keel could not have produced is refused")
    func rejectsImplausibleBookmark() async throws {
        let fixture = try PreferenceFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let oversized = Data(repeating: 0, count: DownloadDirectoryBookmark.byteLimit + 1)

        await #expect(throws: KeelStoreError.invalidSettings) {
            _ = try await store.apply([.replaceSettings(KeelSettings(downloadDirectoryBookmark: oversized))])
        }
        await #expect(throws: KeelStoreError.invalidSettings) {
            _ = try await store.apply([.replaceSettings(KeelSettings(downloadDirectoryBookmark: Data()))])
        }
    }
}

private final class PreferenceFixture {
    let directory: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "KeelSettingsPreferenceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        databaseURL = directory.appending(path: "Keel.sqlite3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
