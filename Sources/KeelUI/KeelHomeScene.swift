import AppKit
import Foundation

/// Identifies one scene in the library. Bundled scenes are named by their
/// resource; imported ones by the row's id.
public enum KeelHomeSceneID: Hashable, Sendable {
    case bundled(String)
    case user(UUID)

    /// The form the store keeps, so ids survive a relaunch as plain text.
    public var storedValue: String {
        switch self {
        case .bundled(let name): "bundled:\(name)"
        case .user(let id): "user:\(id.uuidString.lowercased())"
        }
    }

    public init?(storedValue: String) {
        if let name = storedValue.keelDroppingPrefix("bundled:"), !name.isEmpty {
            self = .bundled(name)
        } else if let raw = storedValue.keelDroppingPrefix("user:"), let id = UUID(uuidString: raw) {
            self = .user(id)
        } else {
            return nil
        }
    }
}

private extension String {
    func keelDroppingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

/// One scene in the library, without its pixels.
public struct KeelHomeScene: Equatable, Sendable {
    public var id: KeelHomeSceneID
    public var name: String
    public var topLuminance: Double
    public var bottomLuminance: Double

    public init(id: KeelHomeSceneID, name: String, topLuminance: Double, bottomLuminance: Double) {
        self.id = id
        self.name = name
        self.topLuminance = topLuminance
        self.bottomLuminance = bottomLuminance
    }

    /// The default scene. The luminances are measured from the bundled HEIC
    /// and repeated in `scenes.json`.
    public static let como = KeelHomeScene(
        id: .bundled("como"),
        name: "Como",
        topLuminance: 0.34,
        bottomLuminance: 0.21
    )
}

/// What Home actually draws: the decoded photograph and the two numbers the
/// scrim needs.
public struct KeelHomeSceneDisplay: Equatable, Sendable {
    /// Nil falls back to the bundled Como image in `KeelDesign`.
    public var image: NSImage?
    public var topLuminance: Double
    public var bottomLuminance: Double

    public init(image: NSImage?, topLuminance: Double, bottomLuminance: Double) {
        self.image = image
        self.topLuminance = topLuminance
        self.bottomLuminance = bottomLuminance
    }

    public static let como = KeelHomeSceneDisplay(
        image: nil,
        topLuminance: KeelHomeScene.como.topLuminance,
        bottomLuminance: KeelHomeScene.como.bottomLuminance
    )
}

/// What the library shows each time Home appears.
public enum KeelHomeSceneMode: String, CaseIterable, Identifiable, Sendable {
    case onePhoto
    case rotateMine
    case rotateAll

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .onePhoto: "One photo"
        case .rotateMine: "Rotate my photos"
        case .rotateAll: "Rotate all photos"
        }
    }
}

/// A scene as the settings grid shows it.
public struct KeelHomeSceneTile: Identifiable, Equatable, Sendable {
    public var id: KeelHomeSceneID
    public var name: String
    public var isBundled: Bool
    public var thumbnail: NSImage?

    public init(id: KeelHomeSceneID, name: String, isBundled: Bool, thumbnail: NSImage? = nil) {
        self.id = id
        self.name = name
        self.isBundled = isBundled
        self.thumbnail = thumbnail
    }
}
