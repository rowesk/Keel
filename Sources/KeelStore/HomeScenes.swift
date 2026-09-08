import Foundation

/// What Home shows behind the capsule.
public enum HomeSceneMode: String, Codable, Sendable {
    /// The selected scene, every arrival.
    case onePhoto
    /// Cycle the user's own scenes. With none imported this behaves as `rotateAll`.
    case rotateMine
    /// Cycle bundled scenes and the user's together.
    case rotateAll
}

/// A photograph the user imported. The file itself lives in `KeelPaths.homeScenesDirectory`;
/// the luminance values are measured once at import so Home can pick its gradient without decoding.
public struct UserHomeScene: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let fileName: String
    public let displayName: String
    public let topLuminance: Double
    public let bottomLuminance: Double
    public let addedAt: Date

    public init(
        id: UUID = UUID(),
        fileName: String,
        displayName: String,
        topLuminance: Double,
        bottomLuminance: Double,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.displayName = displayName
        self.topLuminance = topLuminance
        self.bottomLuminance = bottomLuminance
        self.addedAt = addedAt
    }
}

/// A persisted shuffle: the deck and how far through it we are. Storing both means every scene
/// shows once per cycle and a relaunch carries on where the last one stopped.
public struct HomeSceneRotationState: Codable, Equatable, Sendable {
    /// Scene ids in stored-string form, `bundled:<name>` or `user:<uuid-lowercase>`.
    public var order: [String]
    /// Index into `order` of the scene showing now.
    public var position: Int

    public init(order: [String] = [], position: Int = 0) {
        self.order = order
        self.position = position
    }
}

/// The rotation rule, kept pure so it can be reasoned about and tested without a store or a window.
public enum HomeSceneRotation {
    /// Picks the scene for one arrival at Home.
    ///
    /// `available` is the set the current mode offers, `state` the deck as last persisted, and
    /// `current` the scene showing right now (nil on launch). Returns the scene to show and the
    /// state to persist.
    ///
    /// When `available` no longer matches the deck, the deck is rebuilt so its first scene is not
    /// `current`. Otherwise the position advances, and at the end of a cycle the deck is reshuffled
    /// so the new cycle does not open on the scene that just closed the old one.
    ///
    /// The id is optional for one reason: an empty `available` has nothing to show. That case
    /// returns `nil` with a cleared state, and the caller falls back to the default bundled scene.
    public static func next(
        available: [String],
        state: HomeSceneRotationState,
        current: String?
    ) -> (id: String?, state: HomeSceneRotationState) {
        var generator = SystemRandomNumberGenerator()
        return next(available: available, state: state, current: current, using: &generator)
    }

    /// The same rule with the shuffle's randomness supplied, so tests can pin an order.
    public static func next(
        available: [String],
        state: HomeSceneRotationState,
        current: String?,
        using generator: inout some RandomNumberGenerator
    ) -> (id: String?, state: HomeSceneRotationState) {
        guard !available.isEmpty else { return (nil, HomeSceneRotationState()) }

        if Set(state.order) != Set(available) || state.order.count != available.count {
            let order = shuffled(available, avoidingFirst: current, using: &generator)
            return (order[0], HomeSceneRotationState(order: order, position: 0))
        }

        let position = state.position + 1
        if state.order.indices.contains(position) {
            return (state.order[position], HomeSceneRotationState(order: state.order, position: position))
        }

        // The deck ran out. Reshuffle, keeping the scene that just showed off the front.
        let lastShown = state.order.indices.contains(state.position) ? state.order[state.position] : current
        let order = shuffled(available, avoidingFirst: lastShown ?? current, using: &generator)
        return (order[0], HomeSceneRotationState(order: order, position: 0))
    }

    private static func shuffled(
        _ available: [String],
        avoidingFirst avoided: String?,
        using generator: inout some RandomNumberGenerator
    ) -> [String] {
        var order = available.shuffled(using: &generator)
        guard order.count > 1, let avoided, order[0] == avoided else { return order }
        let swapIndex = Int.random(in: 1 ..< order.count, using: &generator)
        order.swapAt(0, swapIndex)
        return order
    }
}

extension KeelStore {
    /// Adds the imported-scene table and the three Home preferences. Column defaults carry every
    /// pre-existing row to the values a fresh install starts with.
    static func createHomeSceneSchema(_ database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE TABLE home_scenes (
                id TEXT PRIMARY KEY NOT NULL,
                file_name TEXT NOT NULL,
                display_name TEXT NOT NULL,
                top_luminance REAL NOT NULL,
                bottom_luminance REAL NOT NULL,
                added_at REAL NOT NULL
            )
            """)
        try database.execute("CREATE INDEX home_scenes_added_at_index ON home_scenes(added_at)")
        try database.execute("ALTER TABLE settings ADD COLUMN home_scene_mode TEXT NOT NULL DEFAULT 'onePhoto'")
        try database.execute("ALTER TABLE settings ADD COLUMN home_scene_selected TEXT")
        try database.execute("ALTER TABLE settings ADD COLUMN home_scene_rotation TEXT")
    }

    /// The user's imported scenes, oldest first, which is the order the settings grid shows.
    public func userHomeScenes() throws -> [UserHomeScene] {
        try database.rows(
            "SELECT id, file_name, display_name, top_luminance, bottom_luminance, added_at FROM home_scenes ORDER BY added_at ASC, id ASC"
        ).map { row in
            guard let idText = row.text(0),
                  let id = UUID(uuidString: idText),
                  let fileName = row.text(1),
                  let displayName = row.text(2),
                  let top = row.real(3),
                  let bottom = row.real(4),
                  let addedAt = row.real(5)
            else { throw KeelStoreError.corruptData }
            return UserHomeScene(
                id: id,
                fileName: fileName,
                displayName: displayName,
                topLuminance: top,
                bottomLuminance: bottom,
                addedAt: Date(timeIntervalSince1970: addedAt)
            )
        }
    }

    public func insertUserHomeScene(_ scene: UserHomeScene) throws {
        guard !scene.fileName.isEmpty, !scene.displayName.isEmpty else { throw KeelStoreError.invalidSettings }
        try database.execute(
            """
            INSERT INTO home_scenes (id, file_name, display_name, top_luminance, bottom_luminance, added_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                file_name = excluded.file_name,
                display_name = excluded.display_name,
                top_luminance = excluded.top_luminance,
                bottom_luminance = excluded.bottom_luminance,
                added_at = excluded.added_at
            """,
            values: [
                .text(scene.id.uuidString),
                .text(scene.fileName),
                .text(scene.displayName),
                .real(scene.topLuminance),
                .real(scene.bottomLuminance),
                .real(scene.addedAt.timeIntervalSince1970),
            ]
        )
    }

    /// Removes the row only. The file is the caller's to delete, because only it knows the container.
    public func deleteUserHomeScene(id: UUID) throws {
        try database.execute("DELETE FROM home_scenes WHERE id = ?", values: [.text(id.uuidString)])
    }
}

/// JSON is the stored form of the rotation deck: one column, no schema change when the deck grows.
enum HomeSceneRotationCoding {
    static func encode(_ state: HomeSceneRotationState) -> String? {
        guard !state.order.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(state) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A deck we cannot read is not worth failing a launch over: start a fresh one.
    static func decode(_ text: String?) -> HomeSceneRotationState {
        guard let text, let data = text.data(using: .utf8),
              let state = try? JSONDecoder().decode(HomeSceneRotationState.self, from: data)
        else { return HomeSceneRotationState() }
        return state
    }
}
