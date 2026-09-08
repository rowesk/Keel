import Foundation

/// One row of `scenes.json`: a scene that ships inside KeelUI's resources.
public struct KeelBundledScene: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let file: String
    public let topLuminance: Double
    public let bottomLuminance: Double

    public init(id: String, name: String, file: String, topLuminance: Double, bottomLuminance: Double) {
        self.id = id
        self.name = name
        self.file = file
        self.topLuminance = topLuminance
        self.bottomLuminance = bottomLuminance
    }

    public var scene: KeelHomeScene {
        KeelHomeScene(
            id: .bundled(id),
            name: name,
            topLuminance: topLuminance,
            bottomLuminance: bottomLuminance
        )
    }
}

/// The scenes Keel ships with. The list is data rather than code so the import
/// script can add to it without a source edit. Como stays first and is the
/// default.
public enum KeelBundledScenes {
    public static let all: [KeelBundledScene] = load()

    /// Where the photograph for a bundled scene lives, or nil when the
    /// resource is missing from this build.
    public static func url(for id: String) -> URL? {
        guard let scene = all.first(where: { $0.id == id }) else { return nil }
        return KeelDesign.resourceBundle?.url(forResource: scene.file, withExtension: nil)
    }

    private static func load() -> [KeelBundledScene] {
        guard let url = KeelDesign.resourceBundle?.url(forResource: "scenes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let scenes = try? JSONDecoder().decode([KeelBundledScene].self, from: data)
        else {
            // A build without the resource still gets a working Home.
            return [KeelBundledScene(
                id: "como",
                name: "Como",
                file: "como.heic",
                topLuminance: KeelHomeScene.como.topLuminance,
                bottomLuminance: KeelHomeScene.como.bottomLuminance
            )]
        }
        return scenes
    }
}
