@testable import KeelStore
import Foundation
import Testing

@Suite("Home scenes")
struct HomeSceneStoreTests {
    @Test("a database written before home scenes existed gains the defaults and an empty library")
    func migratesFromThePreviousSchema() async throws {
        let fixture = try HomeSceneFixture()
        defer { fixture.remove() }

        let previous = try SQLiteDatabase(url: fixture.databaseURL)
        try KeelStoreMigrationRunner.apply(previous, migrations: Array(KeelStore.migrations.dropLast()))
        #expect(try !fixture.tableExists("home_scenes"))

        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let settings = try await store.runtimeState().settings
        #expect(settings.homeSceneMode == .onePhoto)
        #expect(settings.selectedHomeSceneID == nil)
        #expect(settings.homeSceneRotation == HomeSceneRotationState())
        #expect(try await store.userHomeScenes().isEmpty)
        #expect(try fixture.tableExists("home_scenes"))
    }

    @Test("mode, selection and rotation deck survive a reopen")
    func preferencesRoundTrip() async throws {
        let fixture = try HomeSceneFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let settings = KeelSettings(
            homeSceneMode: .rotateAll,
            selectedHomeSceneID: "user:4b0f5f0e-0000-4000-8000-00000000abcd",
            homeSceneRotation: HomeSceneRotationState(order: ["bundled:como", "user:x"], position: 1)
        )

        _ = try await store.apply([.replaceSettings(settings)])
        let reopened = try KeelStore(databaseURL: fixture.databaseURL)
        let restored = try await reopened.runtimeState().settings

        #expect(restored == settings)
        #expect(restored.homeSceneRotation.position == 1)
    }

    @Test("imported scenes list in added order and delete by id")
    func userScenesInsertListDelete() async throws {
        let fixture = try HomeSceneFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = UserHomeScene(fileName: "a.heic", displayName: "Lake", topLuminance: 0.3, bottomLuminance: 0.2, addedAt: start)
        let second = UserHomeScene(fileName: "b.heic", displayName: "Dune", topLuminance: 0.6, bottomLuminance: 0.4, addedAt: start.addingTimeInterval(60))
        let third = UserHomeScene(fileName: "c.heic", displayName: "Pier", topLuminance: 0.5, bottomLuminance: 0.5, addedAt: start.addingTimeInterval(120))

        // Inserted out of order to prove the list orders by when the scene was added.
        try await store.insertUserHomeScene(second)
        try await store.insertUserHomeScene(first)
        try await store.insertUserHomeScene(third)

        #expect(try await store.userHomeScenes() == [first, second, third])

        try await store.deleteUserHomeScene(id: second.id)
        #expect(try await store.userHomeScenes().map(\.id) == [first.id, third.id])

        let reopened = try KeelStore(databaseURL: fixture.databaseURL)
        #expect(try await reopened.userHomeScenes() == [first, third])
    }
}

@Suite("Home scene rotation")
struct HomeSceneRotationTests {
    private let available = ["bundled:como", "bundled:dune", "user:1", "user:2", "user:3"]

    @Test("a cycle shows every scene exactly once")
    func cycleShowsEveryScene() {
        var generator = SeededGenerator(seed: 7)
        var state = HomeSceneRotationState()
        var shown: [String] = []
        var current: String?

        for _ in available.indices {
            let step = HomeSceneRotation.next(available: available, state: state, current: current, using: &generator)
            state = step.state
            current = step.id
            shown.append(step.id ?? "nothing")
        }

        #expect(Set(shown) == Set(available))
        #expect(shown.count == available.count)
    }

    @Test("a new cycle does not open on the scene that closed the last one")
    func doesNotRepeatAcrossACycleBoundary() {
        for seed in UInt64(1) ... 50 {
            var generator = SeededGenerator(seed: seed)
            var state = HomeSceneRotationState()
            var current: String?
            for _ in available.indices {
                let step = HomeSceneRotation.next(available: available, state: state, current: current, using: &generator)
                state = step.state
                current = step.id
            }
            let first = HomeSceneRotation.next(available: available, state: state, current: current, using: &generator)
            #expect(first.id != current)
            #expect(first.state.position == 0)
        }
    }

    @Test("the position advances through the returned state and the deck stays put")
    func positionPersists() {
        var generator = SeededGenerator(seed: 42)
        let opening = HomeSceneRotation.next(available: available, state: HomeSceneRotationState(), current: nil, using: &generator)
        #expect(opening.state.position == 0)
        #expect(Set(opening.state.order) == Set(available))

        let second = HomeSceneRotation.next(available: available, state: opening.state, current: opening.id, using: &generator)
        #expect(second.state.order == opening.state.order)
        #expect(second.state.position == 1)
        #expect(second.id == opening.state.order[1])

        // Resuming from a persisted deck carries on rather than restarting.
        let resumed = HomeSceneRotation.next(available: available, state: second.state, current: second.id, using: &generator)
        #expect(resumed.state.order == opening.state.order)
        #expect(resumed.state.position == 2)
    }

    @Test("a changed set rebuilds the deck without repeating the scene showing now")
    func setChangeRebuilds() {
        for seed in UInt64(1) ... 50 {
            var generator = SeededGenerator(seed: seed)
            let opening = HomeSceneRotation.next(available: available, state: HomeSceneRotationState(), current: nil, using: &generator)
            let grown = available + ["user:4"]
            let rebuilt = HomeSceneRotation.next(available: grown, state: opening.state, current: opening.id, using: &generator)

            #expect(Set(rebuilt.state.order) == Set(grown))
            #expect(rebuilt.state.position == 0)
            #expect(rebuilt.id != opening.id)
        }
    }

    @Test("one scene keeps showing, and no scenes shows nothing")
    func edgeCases() {
        var generator = SeededGenerator(seed: 3)
        let single = HomeSceneRotation.next(available: ["bundled:como"], state: HomeSceneRotationState(), current: nil, using: &generator)
        #expect(single.id == "bundled:como")
        #expect(single.state == HomeSceneRotationState(order: ["bundled:como"], position: 0))

        let again = HomeSceneRotation.next(available: ["bundled:como"], state: single.state, current: single.id, using: &generator)
        #expect(again.id == "bundled:como")
        #expect(again.state.position == 0)

        // Nothing to show: the caller falls back to the default bundled scene.
        let empty = HomeSceneRotation.next(available: [], state: single.state, current: single.id, using: &generator)
        #expect(empty.id == nil)
        #expect(empty.state == HomeSceneRotationState())
    }
}

/// SplitMix64, so a shuffle is reproducible across runs and platforms.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class HomeSceneFixture {
    let directory: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "KeelHomeSceneTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        databaseURL = directory.appending(path: "Keel.sqlite3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func tableExists(_ table: String) throws -> Bool {
        let database = try SQLiteDatabase(url: databaseURL)
        return try database.scalarText("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", values: [.text(table)]) != nil
    }
}
