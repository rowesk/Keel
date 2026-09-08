@testable import KeelStore
import Foundation
import Testing

@Suite("History migration")
struct HistoryMigrationTests {
    @Test("adds history.0001 to a fresh database and a state.0001 database")
    func migratesFreshAndStateOnlyDatabases() async throws {
        let fresh = try HistoryFixture()
        defer { fresh.remove() }
        _ = try KeelStore(databaseURL: fresh.databaseURL)
        #expect(try fresh.migrationIdentifiers() == ["external-apps.0001", "external-apps.0002", "history.0001", "home-scenes.0001", "state.0001", "state.0002"])
        #expect(try fresh.tableExists("history_visits"))
        #expect(try fresh.tableExists("browsing_sessions"))

        let stateOnly = try HistoryFixture()
        defer { stateOnly.remove() }
        let database = try SQLiteDatabase(url: stateOnly.databaseURL)
        try KeelStoreMigrationRunner.apply(database, migrations: [KeelStore.migrations[0]])
        #expect(try stateOnly.migrationIdentifiers() == ["state.0001"])
        _ = try KeelStore(databaseURL: stateOnly.databaseURL)
        #expect(try stateOnly.migrationIdentifiers() == ["external-apps.0001", "external-apps.0002", "history.0001", "home-scenes.0001", "state.0001", "state.0002"])
        #expect(try stateOnly.tableExists("history_urls"))
    }

    @Test("history migration remains idempotent")
    func migratesIdempotently() throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let database = try SQLiteDatabase(url: fixture.databaseURL)
        try KeelStoreMigrationRunner.apply(database, migrations: KeelStore.migrations)
        try KeelStoreMigrationRunner.apply(database, migrations: KeelStore.migrations)
        #expect(try fixture.migrationIdentifiers() == ["external-apps.0001", "external-apps.0002", "history.0001", "home-scenes.0001", "state.0001", "state.0002"])
    }
}

final class HistoryFixture {
    let directory: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "KeelHistoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        databaseURL = directory.appending(path: "Keel.sqlite3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func tableExists(_ table: String) throws -> Bool {
        let database = try SQLiteDatabase(url: databaseURL)
        return try database.scalarText("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", values: [.text(table)]) != nil
    }

    func migrationIdentifiers() throws -> [String] {
        let database = try SQLiteDatabase(url: databaseURL)
        return try database.rows("SELECT identifier FROM keel_schema_migrations ORDER BY identifier ASC").compactMap { $0.text(0) }
    }
}
