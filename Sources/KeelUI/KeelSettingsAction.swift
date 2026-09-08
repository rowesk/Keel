import Foundation

public enum KeelSettingsAction: Equatable, Sendable {
    case dismiss
    case setSearchProvider(KeelSearchProvider)
    case setCustomSearchTemplate(String)
    case setQueueExpiry(KeelQueueExpiry)
    case setKeepsClosedPageReady(Bool)
    case setAppearance(KeelAppearanceOption)
    case setDefaultPageZoom(KeelPageZoom)
    /// The app layer owns the open panel and the security-scoped bookmark it produces.
    case chooseDownloadDirectory
    case useDefaultDownloadDirectory
    case setHomeSceneMode(KeelHomeSceneMode)
    case selectHomeScene(KeelHomeSceneID)
    /// The app layer owns the open panel.
    case addHomeScenes
    /// Photographs dropped onto the scene grid.
    case importHomeScenes([URL])
    case removeHomeScene(KeelHomeSceneID)
    case exportDiagnostics
    case deleteDiagnostics
}
