import Foundation
import KeelStore

public enum KeelPageStatus: Equatable, Sendable {
    case ready
    case technicalFailure
}

public struct KeelPage: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let currentNavigationID: UUID
    public let url: URL
    public let status: KeelPageStatus

    init(id: UUID, sessionID: UUID, currentNavigationID: UUID, url: URL, status: KeelPageStatus = .ready) {
        self.id = id
        self.sessionID = sessionID
        self.currentNavigationID = currentNavigationID
        self.url = url
        self.status = status
    }

    func navigating(to url: URL, navigationID: UUID) -> KeelPage {
        KeelPage(id: id, sessionID: sessionID, currentNavigationID: navigationID, url: url)
    }

    func failedTechnically() -> KeelPage {
        KeelPage(id: id, sessionID: sessionID, currentNavigationID: currentNavigationID, url: url, status: .technicalFailure)
    }
}

public enum KeelManagementScreen: Equatable, Sendable {
    case history
    case downloads
    case settings
}

/// Stable application-owned error codes used when a durable record needs a state
/// transition that WebKit itself cannot report.
public enum KeelDownloadErrorCode {
    /// The process ended while WebKit still owned the transfer, so no live download
    /// exists to resume after launch.
    public static let interruptedAfterRestart = -1_000_001
}

/// Keel has one browser page. Management screens cover that page instead of adding a
/// browser tab or turning Home into a dashboard.
public enum KeelSurface: Equatable, Sendable {
    case home
    case page
    case management(KeelManagementScreen)
}

public struct KeelTransactionalDetour: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let parentPageID: UUID
    public let url: URL

    init(id: UUID, parentPageID: UUID, url: URL) {
        self.id = id
        self.parentPageID = parentPageID
        self.url = url
    }
}

public struct KeelUndoPage: Equatable, Sendable {
    public let page: KeelPage
    public let sessionStartedAt: Date
    public let sessionHostname: String?
    public let deadline: Date

    init(page: KeelPage, sessionStartedAt: Date, sessionHostname: String?, deadline: Date) {
        self.page = page
        self.sessionStartedAt = sessionStartedAt
        self.sessionHostname = sessionHostname
        self.deadline = deadline
    }

    var reopenedSession: BrowsingSession {
        BrowsingSession(id: page.sessionID, startedAt: sessionStartedAt, hostname: sessionHostname)
    }
}

/// A typed, stable History deletion request. It mirrors the Store's deletion scope
/// without making AppKit depend on its storage representation.
public enum KeelHistoryDeletionRequest: Equatable, Sendable {
    case visits(Set<UUID>)
    case hostnameGroup(sessionID: UUID, branchID: HistoryBranchID, groupID: UUID)
    case session(UUID)
    case all

    var storeScope: HistoryDeletionScope {
        switch self {
        case let .visits(ids):
            .visits(ids)
        case let .hostnameGroup(sessionID, branchID, groupID):
            .hostnameGroup(sessionID: sessionID, branchID: branchID, groupID: groupID)
        case let .session(id):
            .session(id)
        case .all:
            .all
        }
    }
}

/// `surface == .home` with a non-nil `activePage` means Home covers that page.
/// A detour can exist only above an active page while the page surface is visible.
public struct KeelCoordinatorState: Equatable, Sendable {
    public let surface: KeelSurface
    /// The non-management surface that a management screen covers. It is nil unless
    /// `surface` is `.management`, and lets dismissal restore Home versus the page
    /// that Home may already be covering.
    public let managementUnderlyingSurface: KeelSurface?
    public let activePage: KeelPage?
    public let detour: KeelTransactionalDetour?
    public let undoPage: KeelUndoPage?
    public let runtimeState: KeelRuntimeState

    init(
        surface: KeelSurface,
        activePage: KeelPage?,
        detour: KeelTransactionalDetour?,
        undoPage: KeelUndoPage?,
        runtimeState: KeelRuntimeState,
        managementUnderlyingSurface: KeelSurface? = nil
    ) {
        self.surface = surface
        self.managementUnderlyingSurface = managementUnderlyingSurface
        self.activePage = activePage
        self.detour = detour
        self.undoPage = undoPage
        self.runtimeState = runtimeState
    }

    public var isHomeCoveringActivePage: Bool {
        surface == .home && activePage != nil
    }
}

public enum KeelCoordinatorDisposition: Equatable, Sendable {
    case applied
    case ignored
}

/// The address palette makes this choice explicitly. A suggestion never changes what
/// raw Open or Add to queue mean for unselected text.
public enum KeelHistorySuggestionDisposition: Equatable, Sendable {
    case open
    case enqueue
}

public enum KeelCoordinatorEffect: Equatable, Sendable {
    case captureReceipt(url: URL, added: Bool)
    case finishReceipt(nextURL: URL?)
    case showHome
    case showManagement(KeelManagementScreen)
    case restorePageThenNavigate(page: KeelPage, checkpoint: ResumeCheckpoint, source: HistoryVisitSource)
    case activatePage(KeelPage, source: HistoryVisitSource, interactionState: Data?)
    case showActivePage(KeelPage)
    case navigateActivePage(pageID: UUID, navigationID: UUID, to: URL, source: HistoryVisitSource)
    case retainClosedPageForUndo(KeelUndoPage, keepsLiveWebView: Bool)
    case discardUndoPage(KeelUndoPage)
    case restoreUndoPage(KeelUndoPage)
    case discardActivePage(KeelPage)
    case presentDetour(KeelTransactionalDetour)
    case dismissDetour(KeelTransactionalDetour)
    case openDownload(DownloadRecord)
    case revealDownload(DownloadRecord)
    case cancelDownload(UUID)
    case exportDiagnostics(Data)
    case refreshManagementData
    case revealSoleWindow
}

public struct KeelCoordinatorResult: Equatable, Sendable {
    public let state: KeelCoordinatorState?
    public let effects: [KeelCoordinatorEffect]
    public let disposition: KeelCoordinatorDisposition

    init(
        state: KeelCoordinatorState?,
        effects: [KeelCoordinatorEffect],
        disposition: KeelCoordinatorDisposition
    ) {
        self.state = state
        self.effects = effects
        self.disposition = disposition
    }
}
