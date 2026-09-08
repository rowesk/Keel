import Foundation

public enum KeelAppearanceOption: String, CaseIterable, Equatable, Sendable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

public enum KeelPageZoom: Int, CaseIterable, Equatable, Sendable, Identifiable {
    case percent80 = 80
    case percent90 = 90
    case percent100 = 100
    case percent110 = 110
    case percent125 = 125
    case percent150 = 150
    case percent175 = 175
    case percent200 = 200

    public var id: Int { rawValue }

    public var label: String { "\(rawValue)%" }
}

public struct KeelSettingsModel: Equatable, Sendable {
    public var searchProvider: KeelSearchProvider
    public var customSearchTemplate: String
    public var queueExpiry: KeelQueueExpiry
    public var keepsClosedPageReady: Bool
    public var appearance: KeelAppearanceOption
    public var defaultPageZoom: KeelPageZoom
    /// The chosen download directory, or nil while Keel still uses the system Downloads folder.
    public var downloadDirectoryPath: String?
    public var hasDiagnostics: Bool
    public var homeSceneMode: KeelHomeSceneMode
    public var selectedHomeSceneID: KeelHomeSceneID
    public var homeScenes: [KeelHomeSceneTile]

    public init(
        searchProvider: KeelSearchProvider = .google,
        customSearchTemplate: String = "https://example.test/search?q={query}",
        queueExpiry: KeelQueueExpiry = .hours72,
        keepsClosedPageReady: Bool = true,
        appearance: KeelAppearanceOption = .system,
        defaultPageZoom: KeelPageZoom = .percent100,
        downloadDirectoryPath: String? = nil,
        hasDiagnostics: Bool = false,
        homeSceneMode: KeelHomeSceneMode = .onePhoto,
        selectedHomeSceneID: KeelHomeSceneID = .bundled("como"),
        homeScenes: [KeelHomeSceneTile] = []
    ) {
        self.searchProvider = searchProvider
        self.customSearchTemplate = customSearchTemplate
        self.queueExpiry = queueExpiry
        self.keepsClosedPageReady = keepsClosedPageReady
        self.appearance = appearance
        self.defaultPageZoom = defaultPageZoom
        self.downloadDirectoryPath = downloadDirectoryPath
        self.hasDiagnostics = hasDiagnostics
        self.homeSceneMode = homeSceneMode
        self.selectedHomeSceneID = selectedHomeSceneID
        self.homeScenes = homeScenes
    }

    /// Shows the home-relative path so a long absolute path stays readable in one row.
    public var downloadDirectoryLabel: String {
        guard let downloadDirectoryPath, !downloadDirectoryPath.isEmpty else { return "Downloads" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        guard downloadDirectoryPath.hasPrefix(home) else { return downloadDirectoryPath }
        return "~/" + downloadDirectoryPath.dropFirst(home.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// True once the library holds a photograph the user imported. Drives both
    /// the rotate-mine fallback and the extra line of footer copy that explains it.
    public var hasUserHomeScenes: Bool {
        homeScenes.contains { !$0.isBundled }
    }

    public var isCustomSearchTemplateValid: Bool {
        Self.isValidSearchTemplate(customSearchTemplate)
    }

    public static func isValidSearchTemplate(_ template: String) -> Bool {
        guard !template.isEmpty,
              template.utf8.count <= 2_048,
              !template.contains(where: { $0.isWhitespace }),
              template.components(separatedBy: "{query}").count == 2
        else { return false }

        let resolved = template.replacingOccurrences(of: "{query}", with: "keel")
        guard let components = URLComponents(string: resolved),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil
        else { return false }
        return true
    }
}
