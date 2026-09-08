import AppKit
import Foundation
import KeelCoordinator
import KeelStore
import Security
import WebKit

@MainActor
protocol KeelMediaControlling: AnyObject {
    func pauseBeforeDetour(in webView: WKWebView, performDetour: @escaping @MainActor @Sendable () -> Void)
    func pauseBeforeDiscard(in webView: WKWebView, performDiscard: @escaping @MainActor @Sendable () -> Void)
    func resumeAfterDetour(in webView: WKWebView, completion: (@MainActor @Sendable () -> Void)?)
}

extension KeelMediaController: KeelMediaControlling {}

@MainActor
protocol KeelUploadPresenting: AnyObject {
    func present(
        parameters: WKOpenPanelParameters,
        in window: NSWindow?,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    )
}

@MainActor
private final class KeelAppKitUploadPresenter: KeelUploadPresenting {
    func present(
        parameters: WKOpenPanelParameters,
        in window: NSWindow?,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        guard let window else {
            completionHandler(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = !parameters.allowsDirectories
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
}

struct KeelBrowserDebugSnapshot: Equatable {
    let activePageID: UUID?
    let undoPageID: UUID?
    let detourID: UUID?
    let visiblePageID: UUID?
    let visibleDetourID: UUID?
    let hasDetourReservation: Bool
    let liveWebViewCount: Int
    let pageContextCount: Int
    let delegateCount: Int
}

struct KeelDetourPresentationSnapshot: Equatable {
    let detourID: UUID?
    let isLoading: Bool
    let failure: KeelPageFailure?
}

enum KeelDetourEscapeAction: Equatable {
    case blurFocusedEditor
    case closeDetour
}

struct KeelDetourSuspensionTracker {
    private var pending: Set<UUID> = []
    mutating func begin(_ id: UUID) { pending.insert(id) }
    func allowsPresentation(_ id: UUID) -> Bool { pending.contains(id) }
    mutating func consumeResume(_ id: UUID) -> Bool { pending.remove(id) != nil }
}

struct KeelPendingNavigation: Equatable {
    let navigationID: UUID
    let url: URL
    let source: HistoryVisitSource
}

struct KeelDelayedNavigationQueue {
    private var values: [UUID: KeelPendingNavigation] = [:]
    mutating func replace(pageID: UUID, with navigation: KeelPendingNavigation) { values[pageID] = navigation }
    mutating func take(pageID: UUID) -> KeelPendingNavigation? { values.removeValue(forKey: pageID) }
}

/// Keeps a late detour callback from changing a newer presentation.
struct KeelDetourPresentationIdentity: Equatable {
    let detourID: UUID
    let parentPageID: UUID

    func matchesDismissal(_ detour: KeelTransactionalDetour) -> Bool {
        detourID == detour.id && parentPageID == detour.parentPageID
    }
}

/// The navigation controls available for the page currently shown by Keel.
public struct KeelNavigationAvailability: Equatable, Sendable {
    public let hasVisiblePage: Bool
    public let canGoBack: Bool
    public let canGoForward: Bool

    public init(hasVisiblePage: Bool, canGoBack: Bool, canGoForward: Bool) {
        self.hasVisiblePage = hasVisiblePage
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }

    static let unavailable = Self(hasVisiblePage: false, canGoBack: false, canGoForward: false)
}

/// Everything the chrome needs to describe the visible page.
public struct KeelPagePresentation: Equatable, Sendable {
    public let url: URL?
    public let title: String?
    public let isSecure: Bool
    /// `nil` when nothing is loading.
    public let loadingProgress: Double?
    public let isShowingFailure: Bool

    public init(
        url: URL?,
        title: String?,
        isSecure: Bool,
        loadingProgress: Double?,
        isShowingFailure: Bool
    ) {
        self.url = url
        self.title = title
        self.isSecure = isSecure
        self.loadingProgress = loadingProgress
        self.isShowingFailure = isShowingFailure
    }

    public static let empty = Self(
        url: nil,
        title: nil,
        isSecure: false,
        loadingProgress: nil,
        isShowingFailure: false
    )
}

/// Applies committed coordinator effects to WebKit without giving WebKit ownership of
/// Keel's queue, resume, or Undo rules.
@MainActor
public final class KeelBrowserController: NSObject, WKScriptMessageHandler {
    public let contentView: NSView

    /// Startup can retry without replacing or deleting the store.
    public var onDownloadFileUnavailable: (@MainActor () -> Void)?
    public var onStartupPersistenceFailure: (@MainActor (Error) -> Void)?
    public var onTransitionPersistenceFailure: (@MainActor (Error) -> Void)?
    /// Reports one failure until a later successful write restores recording.
    public var onHistoryPersistenceFailure: (@MainActor (String) -> Void)?
    private var hasReportedHistoryPersistenceFailure = false

    public func resetHistoryPersistenceFailureReporting() {
        hasReportedHistoryPersistenceFailure = false
    }

    private func reportHistoryPersistenceFailure(_ error: Error) {
        guard !hasReportedHistoryPersistenceFailure else { return }
        hasReportedHistoryPersistenceFailure = true
        let error = error as NSError
        diagnostics.record(eventType: .webKitCallback, url: nil, result: .failed, errorCode: error.code)
        // Do not expose SQL, URLs, titles, or filesystem paths from error descriptions.
        onHistoryPersistenceFailure?("History could not be saved. Error code \(error.code). Browsing can continue; new visits will retry automatically.")
    }

    /// Called only after the coordinator commits a new product state.
    public var onStateChanged: ((KeelCoordinatorState) -> Void)?

    /// Receipts follow committed coordinator effects only.
    public var onCaptureReceipt: ((URL, Bool) -> Void)?
    public var onFinishReceipt: ((URL?) -> Void)?

    /// Called when the displayed page's Back or Forward availability changes.
    public var onNavigationAvailabilityChanged: ((KeelNavigationAvailability) -> Void)? {
        didSet { publishNavigationAvailability(force: true) }
    }

    /// Called from WebKit download lifecycle events. No timer or UI polling is required.
    public var onDownloadSnapshotsChanged: (([KeelDownloadSnapshot]) -> Void)? {
        didSet { onDownloadSnapshotsChanged?(sortedDownloadSnapshots) }
    }

    /// The AppKit owner uses this to reveal Keel's existing window after a committed effect.
    public var onRevealSoleWindow: (() -> Void)?

    /// The AppKit owner presents the requested native management screen. KeelWeb only
    /// removes visible WebKit views from the browser content view and keeps them alive.
    public var onManagementRequested: ((KeelManagementScreen) -> Void)?

    /// The AppKit owner rebuilds management presentation models from Store and
    /// coordinator state after a committed management mutation.
    public var onManagementDataRefreshRequested: (() -> Void)?

    /// The AppKit owner presents a user-selected save panel for the exported bytes.
    /// KeelWeb never presents that panel itself.
    public var onDiagnosticsExportRequested: ((Data) -> Void)?

    /// App-owned approval seam for an external application handoff. WebKit never opens it.
    public var onExternalApplicationApproval: ((KeelExternalApplicationApproval, @escaping @MainActor (Bool) -> Void) -> Void)?

    /// Address, title, security and loading progress for the visible page. The
    /// toolbar had no way to learn any of this, so it showed none of it.
    public var onPagePresentationChanged: ((KeelPagePresentation) -> Void)? {
        didSet { publishPagePresentation(force: true) }
    }

    private let coordinator: KeelCoordinator
    private let store: KeelStore
    private let historyPersistence: any KeelHistoryPersisting
    private let registry: KeelWebViewRegistry
    private let media: any KeelMediaControlling
    private let uploadPresenter: any KeelUploadPresenting
    private let webViewFactory: (WKWebViewConfiguration) -> WKWebView
    private let diagnostics: KeelWebDiagnostics
    private let now: @Sendable () -> Date
    private var downloadDestinationDirectory: URL?
    private let openLocalFile: @MainActor @Sendable (URL) -> Void
    private let revealLocalFile: @MainActor @Sendable (URL) -> Void

    private var delegates: [ObjectIdentifier: KeelNavigationDelegate] = [:]
    private var pages: [ObjectIdentifier: PageContext] = [:]
    private var eventTail: Task<Void, Never>?
    private var committedState: KeelCoordinatorState?
    private var visiblePageID: UUID?
    private var visibleDetourID: UUID?
    private var detourOverlay: KeelDetourOverlay?
    private var coveredParentAccessibility: CoveredParentAccessibility?
    private var undoSnapshots: [UUID: Data] = [:]
    private var undoPageIDs: Set<UUID> = []
    private var undoExpiryTasks: [UUID: Task<Void, Never>] = [:]
    private var restorationFallbackTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingWebViewCreations: [() -> Void] = []
    private var pendingNavigations = KeelDelayedNavigationQueue()
    private var suspendedDetourParents: [UUID: WKWebView] = [:]
    private var detourSuspensions = KeelDetourSuspensionTracker()
    private var pendingVisiblePageID: UUID?
    private var downloadPersistenceTail: Task<Void, Never>?
    private var downloadSnapshotCache: [UUID: KeelDownloadSnapshot] = [:]
    private var lastNavigationAvailability: KeelNavigationAvailability?
    private var terminalDownloadTasks: [UUID: Task<Void, Never>] = [:]
    /// The zoom every newly created active page starts at. The App sets it from the
    /// stored preference and again whenever the user changes that preference.
    public var defaultPageZoom: CGFloat?
    private let pageErrorView = KeelPageErrorView()
    private var visibleFailure: KeelPageFailure?
    private var failedPageID: UUID?
    /// A detour can fail before its overlay exists, so the failure is held by detour id
    /// and applied when the panel appears.
    private var detourFailures: [UUID: KeelPageFailure] = [:]
    /// The address WebKit asked the detour to open. Retrying a failed first navigation
    /// has no committed URL to reload.
    private var detourURLs: [UUID: URL] = [:]
    private var lastPagePresentation: KeelPagePresentation?
    private var presentationObservations: [NSKeyValueObservation] = []
    private var currentDownloadManager: KeelDownloadManager?
    /// Managers kept alive for downloads that started before the folder changed. They
    /// stay until their last transfer finishes, so a running download keeps writing
    /// where it began.
    private var retiredDownloadManagers: [KeelDownloadManager] = []
    private var downloadManagerIDs: [UUID: KeelDownloadManager] = [:]

    private var downloadManager: KeelDownloadManager {
        if let currentDownloadManager { return currentDownloadManager }
        let manager = KeelDownloadManager(
            destinationDirectory: downloadDestinationDirectory ?? KeelDownloadManager.defaultDestinationDirectory(),
            lifecycleSink: { [weak self] event in
                self?.receiveDownloadLifecycle(event)
            }
        )
        currentDownloadManager = manager
        return manager
    }

    /// This checks only the event-time focused element. Keel does not retain form values.
    private static let detourEscapeEditorCheck = """
    (() => {
      const active = document.activeElement;
      if (!active) return false;
      const tag = active.tagName;
      const isEditor = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || active.isContentEditable;
      if (isEditor) active.blur();
      return isEditor;
    })()
    """

    public convenience init(
        contentView: NSView,
        coordinator: KeelCoordinator,
        store: KeelStore
    ) {
        self.init(
            contentView: contentView,
            coordinator: coordinator,
            store: store,
            webViewFactory: { KeelWebViewFactory.make(configuration: $0) },
            media: KeelMediaController(),
            uploadPresenter: KeelAppKitUploadPresenter(),
            now: Date.init,
            downloadDestinationDirectory: nil
        )
    }

    init(
        contentView: NSView,
        coordinator: KeelCoordinator,
        store: KeelStore,
        webViewFactory: @escaping (WKWebViewConfiguration) -> WKWebView,
        media: any KeelMediaControlling,
        uploadPresenter: any KeelUploadPresenting,
        now: @escaping @Sendable () -> Date = Date.init,
        downloadDestinationDirectory: URL? = nil,
        historyPersistence: (any KeelHistoryPersisting)? = nil,
        openLocalFile: @escaping @MainActor @Sendable (URL) -> Void = { url in
            _ = NSWorkspace.shared.open(url)
        },
        revealLocalFile: @escaping @MainActor @Sendable (URL) -> Void = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    ) {
        self.contentView = contentView
        self.coordinator = coordinator
        self.store = store
        self.historyPersistence = historyPersistence ?? store
        self.webViewFactory = webViewFactory
        registry = KeelWebViewRegistry()
        self.media = media
        self.uploadPresenter = uploadPresenter
        diagnostics = KeelWebDiagnostics(store: store)
        self.now = now
        self.downloadDestinationDirectory = downloadDestinationDirectory
        self.openLocalFile = openLocalFile
        self.revealLocalFile = revealLocalFile
        super.init()
    }

    public convenience init(
        contentView: NSView,
        coordinator: KeelCoordinator,
        store: KeelStore,
        websiteDataStore: WKWebsiteDataStore
    ) {
        self.init(
            contentView: contentView,
            coordinator: coordinator,
            store: store,
            webViewFactory: { KeelWebViewFactory.make(configuration: $0, websiteDataStore: websiteDataStore) },
            media: KeelMediaController(),
            uploadPresenter: KeelAppKitUploadPresenter()
        )
    }

    public var liveWebViewCount: Int {
        registry.liveWebViewCount
    }

    public var activeURL: URL? {
        registry.activeWebView()?.url
    }

    public var downloads: [KeelDownloadSnapshot] {
        sortedDownloadSnapshots
    }

    /// Points new downloads at `directory`, or at the system Downloads folder when it
    /// is nil. Settings can move the folder while transfers are running, so the manager
    /// that owns those transfers is retired rather than reconfigured.
    public func setDownloadDestinationDirectory(_ directory: URL?) {
        downloadDestinationDirectory = directory
        guard let manager = currentDownloadManager else { return }

        let resolved = (directory ?? KeelDownloadManager.defaultDestinationDirectory()).standardizedFileURL
        guard resolved != manager.destinationDirectory.standardizedFileURL else { return }

        if hasUnfinishedDownloads(in: manager) {
            retiredDownloadManagers.append(manager)
        }
        // The next download builds a manager rooted in the new folder.
        currentDownloadManager = nil
    }

    public func cancelDownload(id: UUID) {
        downloadManager(for: id).cancel(id: id)
    }

    public func dismissDownload(id: UUID) {
        // A live transfer has no dismiss action. Its terminal callback still needs
        // to reach the coordinator and must not be able to recreate a hidden row.
        guard let snapshot = downloadSnapshotCache[id], snapshot.state.isTerminal else { return }
        terminalDownloadTasks.removeValue(forKey: id)?.cancel()
        downloadManager(for: id).dismissTerminal(id: id)
        downloadManagerIDs.removeValue(forKey: id)
        downloadSnapshotCache.removeValue(forKey: id)
        releaseFinishedRetiredDownloadManagers()
        onDownloadSnapshotsChanged?(sortedDownloadSnapshots)
    }

    public func openDownload(id: UUID) {
        guard let snapshot = downloadSnapshotCache[id],
              let url = localDownloadURL(for: snapshot.destinationURL)
        else { return }
        openLocalFile(url)
    }

    public func revealDownload(id: UUID) {
        guard let snapshot = downloadSnapshotCache[id],
              let url = localDownloadURL(for: snapshot.destinationURL)
        else { return }
        revealLocalFile(url)
    }

    public func start() {
        enqueueStart()
    }

    public func handle(_ event: KeelCoordinatorEvent) {
        enqueue(event)
    }

    func waitForIdleForTesting() async {
        await eventTail?.value
        while !restorationFallbackTasks.isEmpty {
            let tasks = Array(restorationFallbackTasks.values)
            for task in tasks { await task.value }
        }
    }

    func debugSnapshotForTesting() -> KeelBrowserDebugSnapshot {
        KeelBrowserDebugSnapshot(
            activePageID: registry.activeWebView().flatMap(context(for:))?.pageID,
            undoPageID: undoPageIDs.first,
            detourID: visibleDetourID,
            visiblePageID: visiblePageID,
            visibleDetourID: visibleDetourID,
            hasDetourReservation: registry.hasDetourReservation,
            liveWebViewCount: registry.liveWebViewCount,
            pageContextCount: pages.count,
            delegateCount: delegates.count
        )
    }

    func detourPresentationForTesting() -> KeelDetourPresentationSnapshot {
        KeelDetourPresentationSnapshot(
            detourID: detourOverlay?.detourID,
            isLoading: detourOverlay?.isLoading ?? false,
            failure: detourOverlay?.presentedFailure
        )
    }

    func downloadDestinationDirectoryForTesting() -> URL {
        downloadManager.destinationDirectory
    }

    func activePageFailureForTesting() -> KeelPageFailure? {
        visibleFailure
    }

    func activePageErrorViewIsVisibleForTesting() -> Bool {
        pageErrorView.superview === contentView
    }

    public func receiveExternalURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme != "http", scheme != "https" else {
            enqueue(.receiveExternalURL(url))
            return
        }
        requestExternalApplicationApproval(
            for: KeelNavigationRequest(url: url, externalApplicationTrigger: .typed)
        )
    }

    /// Typed non-web addresses never enter the coordinator or a WKWebView. They go
    /// straight to the AppKit-owned confirmation boundary.
    public func openTypedURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme != "http", scheme != "https" else {
            enqueue(.openTypedURL(url))
            return
        }
        requestExternalApplicationApproval(
            for: KeelNavigationRequest(url: url, externalApplicationTrigger: .typed)
        )
    }

    private func requestExternalApplicationApproval(for request: KeelNavigationRequest) {
        switch KeelNavigationPolicy.decision(for: request) {
        case let .requestExternalApplicationApproval(approval):
            onExternalApplicationApproval?(approval) { _ in }
        case .allowInActivePage, .enqueue, .download, .cancel:
            break
        }
    }

    public func showHome() {
        enqueue(.showHome)
    }

    public func returnToActivePage() {
        enqueue(.returnToActivePage)
    }

    public func showManagement(_ screen: KeelManagementScreen) {
        enqueue(.showManagement(screen))
    }

    public func dismissManagement() {
        enqueue(.dismissManagement)
    }

    public func exportDiagnostics() {
        enqueue(.exportDiagnostics)
    }

    public func closeActivePage() {
        guard let context = registry.activeWebView().flatMap(context(for:)) else { return }
        enqueue(.closePage(pageID: context.pageID))
    }

    public func requeueAndCloseActivePage() {
        guard let context = registry.activeWebView().flatMap(context(for:)) else { return }
        enqueue(.requeueAndClose(pageID: context.pageID))
    }

    @discardableResult
    public func copyActiveURL(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let url = registry.activeWebView()?.url else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(url.absoluteString, forType: .string)
    }

    public func checkpointActivePage() {
        guard let webView = registry.activeWebView(),
              let context = context(for: webView),
              let binding = context.lastCommittedBinding
        else {
            return
        }
        enqueue(
            .saveResumeCheckpoint(
                pageID: binding.pageID,
                navigationID: binding.navigationID,
                interactionState: archiveInteractionState(webView.interactionState)
            )
        )
    }

    /// Flushes the final checkpoint, durable Undo removal, and requested download cancellation.
    public func prepareForTermination(
        cancelActiveDownloads: Bool = false,
        completion: @escaping @MainActor () -> Void
    ) {
        let historyTails = pages.values.compactMap(\.historyTail)
        checkpointActivePage()
        enqueue(.discardCloseUndo)
        for pageID in undoPageIDs {
            if let webView = registry.discardUndo(pageID: pageID) { discard(webView: webView) }
        }
        for task in undoExpiryTasks.values { task.cancel() }
        undoExpiryTasks.removeAll()
        undoPageIDs.removeAll()
        undoSnapshots.removeAll()
        let tail = eventTail
        Task { @MainActor in
            await tail?.value
            for historyTail in historyTails { await historyTail.value }
            if cancelActiveDownloads {
                for manager in self.allDownloadManagers {
                    await manager.cancelAllAndWait()
                }
            }
            await self.downloadPersistenceTail?.value
            completion()
        }
    }

    public func prepareForTermination(cancelActiveDownloads: Bool = false) async {
        await withCheckedContinuation { continuation in
            prepareForTermination(cancelActiveDownloads: cancelActiveDownloads) {
                continuation.resume()
            }
        }
    }

    public func goBack() {
        guard let webView = interactiveWebView(), let context = context(for: webView) else { return }
        beginUserNavigation(in: webView, context: context, kind: .back) { webView.goBack() }
    }

    public func goForward() {
        guard let webView = interactiveWebView(), let context = context(for: webView) else { return }
        beginUserNavigation(in: webView, context: context, kind: .forward) { webView.goForward() }
    }

    public func reload() {
        guard let webView = interactiveWebView(), let context = context(for: webView) else { return }
        beginUserNavigation(in: webView, context: context, kind: .reload) { webView.reload() }
    }

    public func reloadFromOrigin() {
        guard let webView = interactiveWebView(), let context = context(for: webView) else { return }
        beginUserNavigation(in: webView, context: context, kind: .reload) { webView.reloadFromOrigin() }
    }

    private func beginUserNavigation(
        in webView: WKWebView,
        context: PageContext,
        kind: HistoryNavigationKind,
        perform: () -> WKNavigation?
    ) {
        let binding = NavigationBinding(
            pageID: context.pageID,
            navigationID: UUID(),
            source: .link,
            kind: kind,
            detourID: context.detourID,
            currentVisitNavigationID: kind == .reload
                ? context.lastCommittedBinding?.navigationID
                : nil
        )
        guard let navigation = perform() else { return }
        let replacingNavigationID = context.latestBinding?.navigationID ?? binding.navigationID
        context.bind(binding, to: navigation)
        guard binding.detourID == nil else { return }
        enqueue(
            .navigationStarted(
                pageID: binding.pageID,
                replacingNavigationID: replacingNavigationID,
                navigationID: binding.navigationID
            )
        )
    }

    public func printPage() {
        guard let webView = interactiveWebView() else { return }
        let operation = webView.printOperation(with: .shared)
        operation.run()
    }

    /// Finds text in the visible page, wrapping at either end of the document.
    /// `completion` reports whether WebKit matched. The find panel had no way to
    /// say "no results", so a failed search looked the same as a successful one.
    public func find(
        query: String,
        backwards: Bool = false,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard !query.isEmpty, let webView = visibleInteractiveWebView() else {
            completion?(false)
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        webView.find(query, configuration: configuration) { result in
            MainActor.assumeIsolated {
                completion?(result.matchFound)
            }
        }
    }

    public var pageZoom: CGFloat? {
        visibleInteractiveWebView()?.pageZoom
    }

    @discardableResult
    public func increasePageZoom() -> CGFloat? {
        adjustPageZoom(by: 0.1)
    }

    @discardableResult
    public func decreasePageZoom() -> CGFloat? {
        adjustPageZoom(by: -0.1)
    }

    @discardableResult
    public func resetPageZoom() -> CGFloat? {
        setPageZoom(1)
    }

    /// Returns keyboard focus to the currently visible page without activating its window.
    @discardableResult
    public func focusVisiblePage() -> Bool {
        guard let webView = visibleInteractiveWebView(),
              let window = webView.window ?? contentView.window
        else { return false }
        return window.makeFirstResponder(webView)
    }

    /// Call this only after the focused Keel control declined Escape.
    @discardableResult
    public func dismissTransientForEscape() -> Bool {
        guard let visibleDetourID,
              let webView = registry.detourWebView(for: visibleDetourID)
        else { return false }
        webView.evaluateJavaScript(Self.detourEscapeEditorCheck) { [weak self] result, _ in
            guard let self, self.visibleDetourID == visibleDetourID else { return }
            let action = Self.detourEscapeAction(activeElementIsEditable: result as? Bool == true)
            guard action == .closeDetour else { return }
            self.enqueue(.closeTransactionalDetour(detourID: visibleDetourID))
        }
        return true
    }

    static func detourEscapeAction(activeElementIsEditable: Bool) -> KeelDetourEscapeAction {
        activeElementIsEditable ? .blurFocusedEditor : .closeDetour
    }

    func navigationDelegate(for webView: WKWebView) -> KeelNavigationDelegate? {
        delegates[ObjectIdentifier(webView)]
    }

    func context(for webView: WKWebView) -> PageContext? {
        pages[ObjectIdentifier(webView)]
    }

    func createPopup(
        from sourceWebView: WKWebView,
        configuration: WKWebViewConfiguration,
        navigationAction: WKNavigationAction
    ) -> WKWebView? {
        guard let source = context(for: sourceWebView) else { return nil }

        if let url = navigationAction.request.url {
            let decision = KeelNavigationPolicy.decision(
                for: KeelNavigationRequest(
                    url: url,
                    isPageOwned: true,
                    shouldPerformDownload: navigationAction.shouldPerformDownload,
                    sourceURL: sourceWebView.url,
                    isTargetBlank: true,
                    queueIntent: navigationAction.modifierFlags.contains(.command),
                    externalApplicationTrigger: externalApplicationTrigger(for: navigationAction),
                    sourcePageID: source.pageID
                )
            )
            switch decision {
            case let .requestExternalApplicationApproval(approval):
                onExternalApplicationApproval?(approval) { _ in }
                return nil
            case .cancel:
                return nil
            case .allowInActivePage, .enqueue, .download:
                break
            }
        }

        if navigationAction.modifierFlags.contains(.command), let url = navigationAction.request.url {
            enqueue(.addURLToQueue(url))
            return nil
        }

        if source.detourID != nil {
            sourceWebView.load(navigationAction.request)
            return nil
        }

        if navigationAction.navigationType == .linkActivated {
            sourceWebView.load(navigationAction.request)
            return nil
        }

        let detourID = UUID()
        guard let reservation = registry.reserveDetour(id: detourID, parentPageID: source.pageID) else {
            return nil
        }
        if let evictedUndo = registry.takeEvictedUndoWebView(from: reservation) {
            if let pageID = undoPageIDs.first,
               let snapshot = archiveInteractionState(KeelWebViewFactory.interactionState(of: evictedUndo)) {
                undoSnapshots[pageID] = snapshot
            }
            discardEvictedUndoForDetour(evictedUndo)
        }
        guard registry.canCreateWebView else {
            registry.cancelDetourReservation(reservation)
            return nil
        }

        let webView = makeWebView(configuration: configuration)
        let detourContext = PageContext(
            pageID: source.pageID,
            sessionID: source.sessionID,
            detourID: detourID
        )
        install(webView, context: detourContext)
        guard registry.presentDetour(id: detourID, webView: webView, reservation: reservation) else {
            registry.cancelDetourReservation(reservation)
            discard(webView: webView)
            return nil
        }

        guard let url = navigationAction.request.url ?? sourceWebView.url else {
            if let detached = registry.dismissDetour(id: detourID) { discard(webView: detached) }
            return nil
        }
        detourURLs[detourID] = url
        enqueueDetourRequest(id: detourID, url: url)
        return webView
    }

    func closeScriptedDetour(_ webView: WKWebView) {
        guard let detourID = context(for: webView)?.detourID else { return }
        enqueue(.closeTransactionalDetour(detourID: detourID))
    }

    func handleNavigationAction(
        in webView: WKWebView,
        action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = action.request.url else {
            decisionHandler(.cancel)
            return
        }
        let decision = KeelNavigationPolicy.decision(
            for: KeelNavigationRequest(
                url: url,
                isPageOwned: context(for: webView) != nil && (context(for: webView)?.detourID != nil || ["http", "https"].contains(action.sourceFrame.request.url?.scheme?.lowercased() ?? "")),
                shouldPerformDownload: action.shouldPerformDownload,
                sourceURL: webView.url,
                isTargetBlank: action.targetFrame == nil,
                queueIntent: action.modifierFlags.contains(.command),
                externalApplicationTrigger: externalApplicationTrigger(for: action),
                sourcePageID: context(for: webView)?.pageID
            )
        )
        if decision == .download, action.targetFrame?.isMainFrame == true {
            context(for: webView)?.markDownloadHandoff()
        }
        applyNavigationDecision(decision, url: url, webView: webView, decisionHandler: decisionHandler)
    }

    func handleNavigationResponse(
        in webView: WKWebView,
        response: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        guard let url = response.response.url else {
            decisionHandler(.cancel)
            return
        }
        let decision = KeelNavigationPolicy.decision(
            for: KeelNavigationRequest(
                url: url,
                isPageOwned: context(for: webView) != nil,
                shouldPerformDownload: KeelNavigationPolicy.isAttachment(response.response),
                responseCanShowMIMEType: response.canShowMIMEType
            )
        )
        switch decision {
        case .allowInActivePage:
            decisionHandler(.allow)
        case .download:
            if response.isForMainFrame { context(for: webView)?.markDownloadHandoff() }
            decisionHandler(.download)
        case .enqueue, .requestExternalApplicationApproval, .cancel:
            decisionHandler(.cancel)
        }
    }

    func navigationDidStart(in webView: WKWebView, navigation: WKNavigation?) {
        guard let context = context(for: webView) else { return }
        if context.detourID == nil, failedPageID == context.pageID {
            clearFailure()
        }
        if let detourID = context.detourID {
            detourFailures[detourID] = nil
            if let overlay = detourOverlay, overlay.detourID == detourID {
                overlay.clearFailure()
                // Only the first navigation gets the spinner. After that the panel
                // already has a page to look at.
                if context.lastCommittedBinding == nil { overlay.beginLoading() }
            }
        }
        if context.binding(for: navigation) != nil { return }
        let binding = NavigationBinding(
            pageID: context.pageID,
            navigationID: UUID(),
            source: .link,
            kind: .document,
            detourID: context.detourID
        )
        let replacingNavigationID = context.latestBinding?.navigationID ?? binding.navigationID
        context.bind(binding, to: navigation)
        guard binding.detourID == nil else { return }
        enqueue(
            .navigationStarted(
                pageID: binding.pageID,
                replacingNavigationID: replacingNavigationID,
                navigationID: binding.navigationID
            )
        )
    }

    func navigationDidCommit(in webView: WKWebView, navigation: WKNavigation?) {
        guard let context = context(for: webView),
              let binding = context.binding(for: navigation),
              context.latestBinding?.callbackID == binding.callbackID,
              let url = webView.url
        else { return }
        if let pending = context.navigationAfterResumeCommit,
           binding.navigationID == pending.navigationID,
           committedState?.activePage?.id == context.pageID,
           committedState?.activePage?.currentNavigationID == pending.navigationID {
            context.navigationAfterResumeCommit = nil
            context.resumeSeedCheckpoint = nil
            load(pageID: context.pageID, navigationID: pending.navigationID, url: pending.url, source: pending.source, in: webView, context: context)
            return
        }
        context.lastCommittedBinding = binding
        if let detourID = binding.detourID, detourOverlay?.detourID == detourID {
            detourOverlay?.endLoading()
        }
        if binding.detourID == nil {
            enqueue(.navigated(pageID: binding.pageID, navigationID: binding.navigationID, to: url))
            enqueue(
                .saveResumeCheckpoint(
                    pageID: binding.pageID,
                    navigationID: binding.navigationID,
                    interactionState: archiveInteractionState(webView.interactionState)
                )
            )
        }
        recordHistory(url: url, context: context, binding: binding)
        publishNavigationAvailability()
        publishPagePresentation()
    }

    func navigationDidFinish(in webView: WKWebView, navigation: WKNavigation?) {
        guard let context = context(for: webView), let binding = context.binding(for: navigation) else { return }
        enqueueHistoryTitleUpdate(webView.title, for: binding, context: context)
        publishPagePresentation()
    }

    func navigationFailed(in webView: WKWebView, navigation: WKNavigation?, error: any Error) {
        guard let context = context(for: webView), let binding = context.binding(for: navigation) else { return }
        let navigationError = error as NSError
        let code = navigationError.code
        // WebKit reports its policy interruption before delivering WKDownload.
        // Only the load explicitly handed to Downloads can ignore this error.
        if context.isDownloadHandoff(binding),
           navigationError.domain == "WebKitErrorDomain", code == 102 { return }
        guard !(navigationError.domain == NSURLErrorDomain && code == NSURLErrorCancelled),
              context.latestBinding?.callbackID == binding.callbackID else { return }
        if let pending = context.navigationAfterResumeCommit,
           let checkpoint = context.resumeSeedCheckpoint,
           pending.navigationID == binding.navigationID,
           committedState?.activePage?.currentNavigationID == binding.navigationID {
            context.navigationAfterResumeCommit = nil
            preserveFailedResume(checkpoint, pending: pending, in: webView, context: context)
            return
        }
        diagnostics.record(eventType: .navigation, url: webView.url, result: .failed, errorCode: code)
        let failure = KeelPageFailure(
            host: failingHost(for: webView, error: error),
            code: code,
            underlyingDescription: (error as NSError).localizedDescription
        )
        // A detour is subordinate to the page underneath it. Its failure stays inside
        // the panel and never reaches the coordinator, which holds the queue for the
        // active page alone.
        if let detourID = binding.detourID {
            presentDetourFailure(failure, detourID: detourID)
            return
        }
        enqueue(.technicalFailure(pageID: binding.pageID, navigationID: binding.navigationID))
        // The coordinator's job here is to hold the queue. Telling the user what
        // happened is this controller's, and nothing used to do it at all.
        presentFailure(failure, pageID: binding.pageID, webView: webView)
    }

    func webContentProcessDidTerminate(_ webView: WKWebView) {
        guard let context = context(for: webView), let binding = context.latestBinding else { return }
        diagnostics.record(eventType: .processEvent, url: webView.url, result: .failed)
        let failure = KeelPageFailure(
            host: webView.url?.host ?? "this page",
            code: KeelPageFailure.webContentProcessTerminated,
            underlyingDescription: "The web content process ended."
        )
        if let detourID = binding.detourID {
            presentDetourFailure(failure, detourID: detourID)
            return
        }
        enqueue(.technicalFailure(pageID: binding.pageID, navigationID: binding.navigationID))
        presentFailure(failure, pageID: binding.pageID, webView: webView)
    }

    func receiveHistoryBridgeMessage(_ message: WKScriptMessage) {
        guard let change = KeelHistoryBridge.change(from: message),
              let webView = message.webView,
              let context = context(for: webView)
        else { return }
        let kind: HistoryNavigationKind
        switch change.kind {
        case .pushState: kind = .pushState
        case .replaceState: kind = .replaceState
        case .popState: kind = .popState
        case .hashNavigation: kind = .hashNavigation
        }
        guard var binding = context.lastCommittedBinding else { return }
        binding = NavigationBinding(
            pageID: binding.pageID,
            navigationID: binding.navigationID,
            source: binding.source,
            kind: kind,
            detourID: binding.detourID,
            currentVisitNavigationID: kind == .replaceState ? binding.navigationID : nil
        )
        recordHistory(url: change.url, context: context, binding: binding)
        if binding.detourID == nil {
            enqueue(.navigated(pageID: binding.pageID, navigationID: binding.navigationID, to: change.url))
        }
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        receiveHistoryBridgeMessage(message)
    }

    func runOpenPanel(
        parameters: WKOpenPanelParameters,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        uploadPresenter.present(parameters: parameters, in: contentView.window, completionHandler: completionHandler)
    }

    func validateCertificate(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              SecTrustEvaluateWithError(trust, nil)
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func adopt(download: WKDownload, sourceURL: URL?) {
        let manager = downloadManager
        downloadManagerIDs[manager.register(download: download, sourceURL: sourceURL)] = manager
    }

    /// A download belongs to the manager that registered it, which may be a retired one.
    private func downloadManager(for id: UUID) -> KeelDownloadManager {
        downloadManagerIDs[id] ?? downloadManager
    }

    private func hasUnfinishedDownloads(in manager: KeelDownloadManager) -> Bool {
        // A download registered a moment ago has no snapshot yet. It counts as
        // unfinished: WKDownload holds its delegate weakly, so releasing the manager
        // early would strand the transfer.
        downloadManagerIDs.contains { id, owner in
            owner === manager && downloadSnapshotCache[id]?.state.isTerminal != true
        }
    }

    private func releaseFinishedRetiredDownloadManagers() {
        let finished = retiredDownloadManagers.filter { !hasUnfinishedDownloads(in: $0) }
        guard !finished.isEmpty else { return }
        retiredDownloadManagers.removeAll { manager in finished.contains { $0 === manager } }
        downloadManagerIDs = downloadManagerIDs.filter { _, owner in
            !finished.contains { $0 === owner }
        }
    }

    func receiveDownloadLifecycleForTesting(_ event: KeelDownloadLifecycleEvent) {
        receiveDownloadLifecycle(event)
    }

    private func enqueueStart() {
        let previous = eventTail
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self else { return }
            do {
                try apply(await coordinator.start())
            } catch {
                self.onStartupPersistenceFailure?(error)
            }
        }
        eventTail = task
    }

    @discardableResult
    private func enqueue(_ event: KeelCoordinatorEvent) -> Task<Void, Never> {
        let previous = eventTail
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self else { return }
            do {
                try apply(await coordinator.handle(event))
            } catch {
                self.onTransitionPersistenceFailure?(error)
            }
        }
        eventTail = task
        return task
    }

    private func enqueueDetourRequest(id: UUID, url: URL) {
        let previous = eventTail
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self else { return }
            do {
                let result = try await coordinator.handle(.requestTransactionalDetour(id: id, url: url))
                guard result.disposition == .applied else {
                    discardProvisionalDetour(id: id)
                    return
                }
                try apply(result)
            } catch {
                self.onTransitionPersistenceFailure?(error)
                discardProvisionalDetour(id: id)
            }
        }
        eventTail = task
    }

    private func discardProvisionalDetour(id: UUID) {
        detourFailures[id] = nil
        detourURLs[id] = nil
        guard let webView = registry.dismissDetour(id: id) else { return }
        if detourOverlay?.detourID == id {
            detourOverlay?.removeFromSuperview()
            detourOverlay = nil
        }
        if visibleDetourID == id { visibleDetourID = nil }
        restoreCoveredParentAccessibility(for: id)
        discard(webView: webView)
    }

    private func apply(_ result: KeelCoordinatorResult) throws {
        guard result.disposition == .applied else { return }
        if let state = result.state { committedState = state }
        for effect in result.effects {
            switch effect {
            case .showHome:
                pendingVisiblePageID = nil
                detachVisibleWebViews()
            case let .showManagement(screen):
                pendingVisiblePageID = committedState?.activePage?.id
                detachVisibleWebViews()
                onManagementRequested?(screen)
            case let .activatePage(page, source, interactionState):
                activate(page, source: source, interactionState: interactionState)
            case let .restorePageThenNavigate(page, checkpoint, source):
                restorePageThenNavigate(page, checkpoint: checkpoint, source: source)
            case let .showActivePage(page):
                showActivePage(page)
            case let .navigateActivePage(pageID, navigationID, url, source):
                navigate(pageID: pageID, navigationID: navigationID, to: url, source: source)
            case let .retainClosedPageForUndo(undo, keepsLiveWebView):
                retainForUndo(undo, keepsLiveWebView: keepsLiveWebView)
            case let .discardUndoPage(undo):
                discardUndoView(undo)
            case let .restoreUndoPage(undo):
                let hasFollowingShow = result.effects.contains {
                    guard case let .showActivePage(page) = $0 else { return false }
                    return page.id == undo.page.id
                }
                restoreUndoView(undo, showImmediately: !hasFollowingShow)
            case let .discardActivePage(page):
                discardActivePage(page)
            case let .presentDetour(detour):
                presentDetour(detour)
            case let .dismissDetour(detour):
                dismissDetour(detour)
            case let .openDownload(download):
                openDownload(download)
            case let .revealDownload(download):
                revealDownload(download)
            case let .cancelDownload(id):
                cancelDownload(id: id)
            case let .exportDiagnostics(data):
                onDiagnosticsExportRequested?(data)
            case .refreshManagementData:
                onManagementDataRefreshRequested?()
            case let .captureReceipt(url, added):
                onCaptureReceipt?(url, added)
            case let .finishReceipt(nextURL):
                onFinishReceipt?(nextURL)
            case .revealSoleWindow:
                onRevealSoleWindow?()
            }
        }
        if let state = result.state {
            onStateChanged?(state)
        }
        publishNavigationAvailability()
    }

    private func restorePageThenNavigate(_ page: KeelPage, checkpoint: ResumeCheckpoint, source: HistoryVisitSource) {
        guard committedState?.activePage?.id == page.id,
              committedState?.activePage?.currentNavigationID == page.currentNavigationID else { return }
        guard registry.canCreateWebView else {
            pendingWebViewCreations.append { [weak self] in
                self?.restorePageThenNavigate(page, checkpoint: checkpoint, source: source)
            }
            return
        }
        let webView = makeWebView(configuration: nil)
        if let displaced = registry.activate(pageID: page.id, webView: webView) { discard(webView: displaced) }
        let context = PageContext(pageID: page.id, sessionID: page.sessionID, detourID: nil)
        install(webView, context: context)
        if let data = checkpoint.interactionState {
            KeelWebViewFactory.restoreInteractionState(unarchiveInteractionState(data), in: webView)
        }
        if webView.backForwardList.currentItem != nil {
            load(pageID: page.id, navigationID: page.currentNavigationID, url: page.url, source: source, in: webView, context: context)
        } else {
            // A URL-only checkpoint must enter the back list before explicit Open.
            // A failed seed leaves the stored checkpoint intact and shows normal retry.
            context.resumeSeedCheckpoint = checkpoint
            context.navigationAfterResumeCommit = KeelPendingNavigation(navigationID: page.currentNavigationID, url: page.url, source: source)
            let binding = NavigationBinding(pageID: page.id, navigationID: page.currentNavigationID, source: .resume, kind: .document, detourID: nil)
            context.bind(binding, to: webView.load(URLRequest(url: checkpoint.url, timeoutInterval: 15)))
        }
        if pendingVisiblePageID == page.id {
            pendingVisiblePageID = nil
            showActivePage(page)
        }
    }

    private func activate(_ page: KeelPage, source: HistoryVisitSource, interactionState: Data?) {
        guard let currentPage = committedState?.activePage, currentPage.id == page.id else { return }
        guard registry.canCreateWebView else {
            pendingWebViewCreations.append { [weak self] in
                self?.activate(page, source: source, interactionState: interactionState)
            }
            return
        }
        let webView = makeWebView(configuration: nil)
        let displaced = registry.activate(pageID: currentPage.id, webView: webView)
        if let displaced { discard(webView: displaced) }
        let context = PageContext(
            pageID: currentPage.id,
            sessionID: currentPage.sessionID,
            detourID: nil
        )
        install(webView, context: context)
        if let pending = pendingNavigations.take(pageID: currentPage.id) {
            load(pageID: currentPage.id, navigationID: pending.navigationID, url: pending.url, source: pending.source, in: webView, context: context)
        } else {
            restoreOrLoad(
                page: currentPage,
                in: webView,
                context: context,
                source: source,
                interactionState: currentPage.currentNavigationID == page.currentNavigationID ? interactionState : nil
            )
        }
        if pendingVisiblePageID == currentPage.id {
            pendingVisiblePageID = nil
            showActivePage(currentPage)
        }
    }

    private func preserveFailedResume(_ checkpoint: ResumeCheckpoint, pending: KeelPendingNavigation, in webView: WKWebView, context: PageContext) {
        let previous = eventTail
        eventTail = Task { @MainActor [weak self, weak webView, weak context] in
            await previous?.value
            guard let self, let webView, let context,
                  self.context(for: webView) === context,
                  self.committedState?.activePage?.id == context.pageID,
                  self.committedState?.activePage?.currentNavigationID == pending.navigationID else { return }
            do {
                let result = try await self.coordinator.handle(.preserveFailedResumeBeforeOpen(
                    pageID: context.pageID, navigationID: pending.navigationID, checkpoint: checkpoint))
                try self.apply(result)
                guard result.disposition == .applied,
                      self.context(for: webView) === context,
                      self.committedState?.activePage?.currentNavigationID == pending.navigationID else { return }
                context.resumeSeedCheckpoint = nil
                self.load(pageID: context.pageID, navigationID: pending.navigationID, url: pending.url, source: pending.source, in: webView, context: context)
            } catch {
                self.onTransitionPersistenceFailure?(error)
            }
        }
    }

    private func navigate(pageID: UUID, navigationID: UUID, to url: URL, source: HistoryVisitSource) {
        guard let webView = registry.activeWebView(for: pageID), let context = context(for: webView) else {
            pendingNavigations.replace(pageID: pageID, with: KeelPendingNavigation(navigationID: navigationID, url: url, source: source))
            return
        }
        context.navigationAfterResumeCommit = nil
        if let checkpoint = context.resumeSeedCheckpoint {
            preserveFailedResume(checkpoint, pending: KeelPendingNavigation(navigationID: navigationID, url: url, source: source), in: webView, context: context)
            return
        }
        load(pageID: pageID, navigationID: navigationID, url: url, source: source, in: webView, context: context)
    }

    private func load(pageID: UUID, navigationID: UUID, url: URL, source: HistoryVisitSource, in webView: WKWebView, context: PageContext) {
        let binding = NavigationBinding(
            pageID: pageID,
            navigationID: navigationID,
            source: source,
            kind: .document,
            detourID: nil
        )
        context.bind(binding, to: webView.load(URLRequest(url: url)))
    }

    /// Interaction state can start navigation asynchronously. Bind the intended resume
    /// navigation first, then only use the persisted URL after a short bounded wait if
    /// WebKit did not begin restoring on its own.
    private func restoreOrLoad(
        page: KeelPage,
        in webView: WKWebView,
        context: PageContext,
        source: HistoryVisitSource,
        interactionState: Data?
    ) {
        let binding = NavigationBinding(
            pageID: page.id,
            navigationID: page.currentNavigationID,
            source: source,
            kind: .document,
            detourID: nil
        )
        guard let interactionState else {
            context.bind(binding, to: webView.load(URLRequest(url: page.url)))
            return
        }

        context.enqueuePending(binding)
        restorationFallbackTasks[binding.navigationID]?.cancel()
        restorationFallbackTasks[binding.navigationID] = Task { @MainActor [weak self, weak webView, weak context] in
            defer { self?.restorationFallbackTasks.removeValue(forKey: binding.navigationID) }
            // Let the committed show effect attach the restored view before WebKit applies
            // its state. Scroll restoration is otherwise lost for a detached root view.
            await Task.yield()
            guard let self,
                  let webView,
                  let context,
                  self.context(for: webView) === context
            else {
                return
            }
            KeelWebViewFactory.restoreInteractionState(self.unarchiveInteractionState(interactionState), in: webView)
            try? await Task.sleep(for: .milliseconds(100))
            // isLoading becomes true before didStart consumes the pending
            // binding. A cold WebKit process can stay in that gap past 100 ms.
            // A URL load here would replace the restoration and lose its scroll.
            guard !Task.isCancelled,
                  !webView.isLoading,
                  self.context(for: webView) === context,
                  let fallbackBinding = context.removePendingBinding(navigationID: binding.navigationID)
            else {
                return
            }
            // Some WebKit restores supply history but do not initiate navigation. Reapply
            // the opaque state immediately before the persisted-URL fallback so WebKit can
            // restore scroll and back-forward state onto that navigation.
            KeelWebViewFactory.restoreInteractionState(self.unarchiveInteractionState(interactionState), in: webView)
            context.bind(fallbackBinding, to: webView.load(URLRequest(url: page.url)))
        }
    }

    private func showActivePage(_ page: KeelPage) {
        if let surface = committedState?.surface,
           case .management = surface {
            pendingVisiblePageID = page.id
            detachVisibleWebViews()
            return
        }
        guard let webView = registry.activeWebView(for: page.id) else {
            pendingVisiblePageID = page.id
            return
        }
        attach(webView)
        visiblePageID = page.id
    }

    private func retainForUndo(_ undo: KeelUndoPage, keepsLiveWebView: Bool) {
        guard case let .retained(replacedUndoWebView) = registry.retainActiveAsUndo(pageID: undo.page.id) else { return }
        if let replacedUndoWebView { discard(webView: replacedUndoWebView) }
        for task in undoExpiryTasks.values { task.cancel() }
        undoExpiryTasks.removeAll()
        undoPageIDs.insert(undo.page.id)
        scheduleUndoExpiry(for: undo)
        visiblePageID = nil
        guard let webView = registry.webView(for: undo.page.id) else { return }
        webView.removeFromSuperview()
        if keepsLiveWebView {
            media.pauseBeforeDetour(in: webView) {}
        } else {
            if let snapshot = archiveInteractionState(KeelWebViewFactory.interactionState(of: webView)) {
                undoSnapshots[undo.page.id] = snapshot
            }
            _ = registry.discardUndo(pageID: undo.page.id)
            discard(webView: webView)
        }
    }

    private func restoreUndoView(_ undo: KeelUndoPage, showImmediately: Bool) {
        undoExpiryTasks.removeValue(forKey: undo.page.id)?.cancel()
        if let webView = registry.restoreUndo(pageID: undo.page.id) {
            _ = registry.activate(pageID: undo.page.id, webView: webView)
            media.resumeAfterDetour(in: webView, completion: nil)
        } else {
            guard registry.canCreateWebView else {
                pendingWebViewCreations.append { [weak self] in
                    self?.restoreUndoView(undo, showImmediately: showImmediately)
                }
                return
            }
            let webView = makeWebView(configuration: nil)
            let context = PageContext(
                pageID: undo.page.id,
                sessionID: undo.page.sessionID,
                detourID: nil
            )
            install(webView, context: context)
            _ = registry.activate(pageID: undo.page.id, webView: webView)
            restoreOrLoad(
                page: undo.page,
                in: webView,
                context: context,
                source: .resume,
                interactionState: undoSnapshots.removeValue(forKey: undo.page.id)
            )
        }
        undoPageIDs.remove(undo.page.id)
        if showImmediately { showActivePage(undo.page) }
    }

    private func discardUndoView(_ undo: KeelUndoPage) {
        undoExpiryTasks.removeValue(forKey: undo.page.id)?.cancel()
        undoPageIDs.remove(undo.page.id)
        undoSnapshots.removeValue(forKey: undo.page.id)
        if let webView = registry.discardUndo(pageID: undo.page.id) {
            discard(webView: webView)
        }
    }

    private func discardActivePage(_ page: KeelPage) {
        guard let webView = registry.detachActive(pageID: page.id) else { return }
        visiblePageID = nil
        discard(webView: webView)
    }

    private func scheduleUndoExpiry(for undo: KeelUndoPage) {
        let delay = max(0, undo.deadline.timeIntervalSince(now()))
        undoExpiryTasks[undo.page.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.enqueue(.closeUndoExpired(pageID: undo.page.id, deadline: undo.deadline))
        }
    }

    private func presentDetour(_ detour: KeelTransactionalDetour) {
        guard let detourWebView = registry.detourWebView(for: detour.id),
              let activeWebView = registry.activeWebView(for: detour.parentPageID)
        else { return }
        suspendedDetourParents[detour.id] = activeWebView
        detourSuspensions.begin(detour.id)
        media.pauseBeforeDetour(in: activeWebView) { [weak self] in
            guard let self,
                  self.detourSuspensions.allowsPresentation(detour.id),
                  self.suspendedDetourParents[detour.id] === activeWebView,
                  self.registry.detourWebView(for: detour.id) === detourWebView,
                  self.registry.activeWebView(for: detour.parentPageID) === activeWebView
            else { return }
            self.showDetour(
                detourWebView,
                id: detour.id,
                parentPageID: detour.parentPageID,
                parentWebView: activeWebView
            )
        }
    }

    private func dismissDetour(_ detour: KeelTransactionalDetour) {
        guard let webView = registry.dismissDetour(id: detour.id) else { return }
        detourFailures[detour.id] = nil
        detourURLs[detour.id] = nil
        let suspendedParent = suspendedDetourParents.removeValue(forKey: detour.id)
        let requiresResume = detourSuspensions.consumeResume(detour.id)
        media.pauseBeforeDiscard(in: webView) { [weak self] in
            guard let self else { return }
            self.remove(webView: webView)
            self.registry.finishRetiring(webView)
            if self.detourOverlay?.detourID == detour.id {
                self.detourOverlay?.removeFromSuperview()
                self.detourOverlay = nil
            }
            if self.visibleDetourID == detour.id { self.visibleDetourID = nil }
            if !self.registry.hasDetour(parentPageID: detour.parentPageID),
               let active = self.registry.activeWebView(for: detour.parentPageID),
               requiresResume,
               suspendedParent === active {
                _ = self.restoreCoveredParentAccessibility(for: detour)
                self.media.resumeAfterDetour(in: active) { [weak self, weak active] in
                    guard let self,
                          let active,
                          self.visibleDetourID == nil,
                          self.registry.activeWebView(for: detour.parentPageID) === active,
                          !self.registry.hasDetour(parentPageID: detour.parentPageID)
                    else { return }
                    _ = self.focusVisiblePage()
                }
            }
            self.drainPendingWebViewCreations()
            self.publishNavigationAvailability()
        }
    }

    private func makeWebView(configuration: WKWebViewConfiguration?) -> WKWebView {
        let configuration = configuration ?? WKWebViewConfiguration()
        KeelHistoryBridge.install(in: configuration, receiver: self)
        return webViewFactory(configuration)
    }

    private func install(_ webView: WKWebView, context: PageContext) {
        // A new page starts at the user's stored default. A page already on screen keeps
        // whatever zoom the user gave it, so this deliberately does not run on re-show.
        if context.detourID == nil, let defaultPageZoom {
            webView.pageZoom = Self.clampedPageZoom(defaultPageZoom)
        }
        let delegate = KeelNavigationDelegate(owner: self)
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        webView.allowsMagnification = true
        let id = ObjectIdentifier(webView)
        delegates[id] = delegate
        pages[id] = context
    }

    private func attach(_ webView: WKWebView) {
        detachVisibleWebViews(except: webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        observePresentation(of: webView)
        publishPagePresentation(force: true)
    }

    private func detachVisibleWebViews(except retainedWebView: WKWebView? = nil) {
        detourOverlay?.removeFromSuperview()
        detourOverlay = nil
        visibleDetourID = nil
        clearFailure()
        restoreCoveredParentAccessibility()
        for child in contentView.subviews where child is WKWebView && child !== retainedWebView {
            child.removeFromSuperview()
        }
        if retainedWebView == nil { visiblePageID = nil }
    }

    private func remove(webView: WKWebView) {
        webView.stopLoading()
        webView.removeFromSuperview()
        let id = ObjectIdentifier(webView)
        delegates.removeValue(forKey: id)
        pages.removeValue(forKey: id)
    }

    private func discard(webView: WKWebView) {
        media.pauseBeforeDiscard(in: webView) { [weak self] in
            guard let self else { return }
            self.remove(webView: webView)
            self.registry.finishRetiring(webView)
            self.drainPendingWebViewCreations()
        }
    }

    /// WebKit needs the slot immediately for a supplied transactional popup. The logical
    /// Undo record remains alive through `undoSnapshots`, but the evicted view must leave
    /// every browser-owned reference before the detour becomes live.
    private func discardEvictedUndoForDetour(_ webView: WKWebView) {
        webView.stopLoading()
        webView.removeFromSuperview()
        let identifier = ObjectIdentifier(webView)
        delegates.removeValue(forKey: identifier)
        pages.removeValue(forKey: identifier)
        media.pauseBeforeDiscard(in: webView) {}
    }

    private func openDownload(_ record: DownloadRecord) {
        guard let url = localDownloadURL(for: record) else {
            onDownloadFileUnavailable?()
            return
        }
        openLocalFile(url)
    }

    private func revealDownload(_ record: DownloadRecord) {
        guard let url = localDownloadURL(for: record) else {
            onDownloadFileUnavailable?()
            return
        }
        revealLocalFile(url)
    }

    /// Download records can outlive the WebKit manager that created them. Resolve a
    /// persisted path only when it names an existing regular local file. Relative
    /// references stay below the manager's configured destination directory.
    private func localDownloadURL(for record: DownloadRecord) -> URL? {
        if let snapshotURL = downloadSnapshotCache[record.id]?.destinationURL,
           let url = localDownloadURL(for: snapshotURL) {
            return url
        }
        guard let pathReference = record.pathReference,
              !pathReference.isEmpty,
              !pathReference.contains("\0"),
              !pathReference.hasPrefix("~")
        else { return nil }
        let candidate: URL
        if pathReference.hasPrefix("/") {
            candidate = URL(fileURLWithPath: pathReference)
        } else {
            let base = downloadManager.destinationDirectory.standardizedFileURL
            let relativeCandidate = base
                .appendingPathComponent(pathReference)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard relativeCandidate.path == base.path
                    || relativeCandidate.path.hasPrefix(base.path + "/")
            else { return nil }
            candidate = relativeCandidate
        }
        return localDownloadURL(for: candidate)
    }

    private func localDownloadURL(for candidate: URL?) -> URL? {
        guard let candidate,
              candidate.isFileURL,
              !candidate.path.isEmpty,
              FileManager.default.fileExists(atPath: candidate.path),
              let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true
        else { return nil }
        return candidate.standardizedFileURL
    }

    private func drainPendingWebViewCreations() {
        while registry.canCreateWebView, !pendingWebViewCreations.isEmpty {
            let creation = pendingWebViewCreations.removeFirst()
            creation()
        }
    }

    private func interactiveWebView() -> WKWebView? {
        if let visibleDetourID {
            return registry.detourWebView(for: visibleDetourID)
        }
        return registry.activeWebView()
    }

    private func visibleInteractiveWebView() -> WKWebView? {
        if let visibleDetourID {
            return registry.detourWebView(for: visibleDetourID)
        }
        guard let visiblePageID else { return nil }
        return registry.activeWebView(for: visiblePageID)
    }

    @discardableResult
    private func adjustPageZoom(by delta: CGFloat) -> CGFloat? {
        guard let webView = visibleInteractiveWebView() else { return nil }
        return setPageZoom(webView.pageZoom + delta)
    }

    /// Sets the visible page's zoom, clamped to the range the keyboard commands use.
    /// Returns the zoom that was applied, or nil when no page is visible.
    @discardableResult
    public func setPageZoom(_ value: CGFloat) -> CGFloat? {
        guard let webView = visibleInteractiveWebView() else { return nil }
        webView.pageZoom = Self.clampedPageZoom(value)
        return webView.pageZoom
    }

    static func clampedPageZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.5), 3)
    }

    private var sortedDownloadSnapshots: [KeelDownloadSnapshot] {
        downloadSnapshotCache.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString > $1.id.uuidString
        }
    }

    private func navigationAvailability() -> KeelNavigationAvailability {
        guard let webView = visibleInteractiveWebView() else {
            return .unavailable
        }
        return KeelNavigationAvailability(
            hasVisiblePage: true,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward
        )
    }

    private func publishNavigationAvailability(force: Bool = false) {
        let availability = navigationAvailability()
        guard force || availability != lastNavigationAvailability else { return }
        lastNavigationAvailability = availability
        onNavigationAvailabilityChanged?(availability)
    }

    // MARK: Page presentation

    /// Watches the visible page so the toolbar can show an address, a title and
    /// a progress bar. Observations are rebuilt on every attach, so only the
    /// page the user is looking at is ever observed.
    private func observePresentation(of webView: WKWebView) {
        presentationObservations.removeAll()
        let publish: @MainActor (WKWebView) -> Void = { [weak self] _ in
            self?.publishPagePresentation()
        }
        presentationObservations = [
            webView.observe(\.url, options: [.new]) { view, _ in
                MainActor.assumeIsolated { publish(view) }
            },
            webView.observe(\.title, options: [.new]) { view, _ in
                MainActor.assumeIsolated { publish(view) }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { view, _ in
                MainActor.assumeIsolated { publish(view) }
            },
            webView.observe(\.isLoading, options: [.new]) { view, _ in
                MainActor.assumeIsolated { publish(view) }
            },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { view, _ in
                MainActor.assumeIsolated { publish(view) }
            },
        ]
    }

    private func publishPagePresentation(force: Bool = false) {
        let presentation = pagePresentation()
        guard force || presentation != lastPagePresentation else { return }
        lastPagePresentation = presentation
        onPagePresentationChanged?(presentation)
    }

    private func pagePresentation() -> KeelPagePresentation {
        guard let webView = visibleInteractiveWebView() ?? registry.activeWebView() else {
            return .empty
        }
        let url = webView.url ?? committedState?.activePage?.url
        return KeelPagePresentation(
            url: url,
            title: webView.title?.isEmpty == false ? webView.title : nil,
            isSecure: url?.scheme?.lowercased() == "https" && webView.hasOnlySecureContent,
            loadingProgress: webView.isLoading ? webView.estimatedProgress : nil,
            isShowingFailure: visibleFailure != nil
        )
    }

    // MARK: Failure presentation

    private func presentFailure(_ failure: KeelPageFailure, pageID: UUID, webView: WKWebView) {
        // Only the page the user can actually see gets an error screen. A
        // background or detour failure must not paint over the active page.
        guard visiblePageID == nil || visiblePageID == pageID else { return }
        visibleFailure = failure
        failedPageID = pageID
        pageErrorView.present(failure: failure)
        pageErrorView.onRetry = { [weak self, weak webView] in
            guard let self else { return }
            self.clearFailure()
            if let webView, webView.url != nil {
                webView.reload()
            } else {
                self.reload()
            }
        }
        pageErrorView.onCloseAndContinue = { [weak self] in
            // The coordinator advances the queue on close, which is the only
            // place a technical failure is allowed to move it along.
            self?.clearFailure()
            self?.closeActivePage()
        }
        pageErrorView.onGoHome = { [weak self] in
            self?.clearFailure()
            self?.showHome()
        }

        if pageErrorView.superview !== contentView {
            pageErrorView.removeFromSuperview()
            contentView.addSubview(pageErrorView)
            NSLayoutConstraint.activate([
                pageErrorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                pageErrorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                pageErrorView.topAnchor.constraint(equalTo: contentView.topAnchor),
                pageErrorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }
        contentView.addSubview(pageErrorView, positioned: .above, relativeTo: nil)
        publishPagePresentation(force: true)
    }

    /// Draws the failure inside the detour panel, leaving the dimmed page underneath
    /// exactly as it was. The panel keeps it until the overlay appears when a detour
    /// fails before WebKit has anything to show.
    private func presentDetourFailure(_ failure: KeelPageFailure, detourID: UUID) {
        detourFailures[detourID] = failure
        guard let overlay = detourOverlay, overlay.detourID == detourID else { return }
        overlay.presentFailure(failure)
    }

    private func clearFailure() {
        guard visibleFailure != nil else { return }
        visibleFailure = nil
        failedPageID = nil
        pageErrorView.removeFromSuperview()
        publishPagePresentation(force: true)
    }

    /// The host Keel was trying to reach, preferring the failing URL WebKit
    /// reports over the last committed one.
    private func failingHost(for webView: WKWebView, error: any Error) -> String {
        let userInfo = (error as NSError).userInfo
        if let failingURL = userInfo[NSURLErrorFailingURLErrorKey] as? URL, let host = failingURL.host {
            return host
        }
        return webView.url?.host ?? committedState?.activePage?.url.host ?? "that site"
    }

    private func recordHistory(url: URL, context: PageContext, binding: NavigationBinding) {
        let previous = context.historyTail
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self else { return }
            let event = HistoryVisitEvent(
                url: url,
                visitedAt: self.now(),
                browsingSessionID: context.sessionID,
                branch: binding.detourID.map(HistoryBranch.transactionalDetour) ?? .root,
                navigationKind: binding.kind,
                source: binding.source,
                currentVisitID: binding.currentVisitNavigationID.flatMap { context.visitIDs[$0] }
            )
            do {
                let visit = try await self.historyPersistence.recordHistoryVisit(event)
                context.visitIDs[binding.navigationID] = visit.id
                if let title = context.pendingTitles.removeValue(forKey: binding.navigationID) {
                    try await self.historyPersistence.updateHistoryTitle(visitID: visit.id, title: title)
                }
                self.hasReportedHistoryPersistenceFailure = false
            } catch {
                self.reportHistoryPersistenceFailure(error)
            }
        }
        context.historyTail = task
    }

    private func enqueueHistoryTitleUpdate(
        _ title: String?,
        for binding: NavigationBinding,
        context: PageContext
    ) {
        guard let title else { return }
        let previous = context.historyTail
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self else { return }
            guard let visitID = context.visitIDs[binding.navigationID] else {
                context.pendingTitles[binding.navigationID] = title
                return
            }
            do {
                try await self.historyPersistence.updateHistoryTitle(visitID: visitID, title: title)
                self.hasReportedHistoryPersistenceFailure = false
            } catch {
                self.reportHistoryPersistenceFailure(error)
            }
        }
        context.historyTail = task
    }

    private func archiveInteractionState(_ state: Any?) -> Data? {
        guard let state else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
    }

    private var allDownloadManagers: [KeelDownloadManager] {
        retiredDownloadManagers + [currentDownloadManager].compactMap { $0 }
    }

    private func receiveDownloadLifecycle(_ event: KeelDownloadLifecycleEvent) {
        for snapshot in event.snapshots {
            downloadSnapshotCache[snapshot.id] = snapshot
        }
        releaseFinishedRetiredDownloadManagers()
        onDownloadSnapshotsChanged?(sortedDownloadSnapshots)
        switch event {
        case .progress, .updated:
            return
        case let .started(snapshot), let .finished(snapshot):
            persistDownloadRecord(snapshot)
        }
    }

    private func persistDownloadRecord(_ snapshot: KeelDownloadSnapshot) {
        let record = DownloadRecord(
            id: snapshot.id,
            hostname: snapshot.sourceHostname,
            filename: snapshot.filename,
            pathReference: snapshot.destinationURL?.path,
            byteCount: snapshot.receivedBytes,
            state: storeDownloadState(snapshot.state),
            createdAt: snapshot.createdAt,
            completedAt: snapshot.completedAt,
            errorCode: storeDownloadErrorCode(snapshot.state)
        )
        // Lifecycle records share the coordinator event tail with user actions. This
        // keeps a newly started live ID available to Cancel even when Downloads is
        // already open, and publishes the committed record through onStateChanged.
        downloadPersistenceTail = enqueue(.updateDownload(record))

        guard snapshot.state.isTerminal else { return }
        terminalDownloadTasks[snapshot.id]?.cancel()
        terminalDownloadTasks[snapshot.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.dismissDownload(id: snapshot.id)
        }
    }

    private func storeDownloadState(_ state: KeelDownloadState) -> DownloadState {
        switch state {
        case .inProgress: .inProgress
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        }
    }

    private func storeDownloadErrorCode(_ state: KeelDownloadState) -> Int? {
        if case let .failed(errorCode) = state { return errorCode }
        return nil
    }

    private func unarchiveInteractionState(_ data: Data) -> Any? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        let state = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()
        return state
    }

    private func applyNavigationDecision(
        _ decision: KeelNavigationDecision,
        url: URL,
        webView: WKWebView,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        switch decision {
        case .allowInActivePage:
            decisionHandler(.allow)
        case .enqueue:
            decisionHandler(.cancel)
            enqueue(.addURLToQueue(url))
        case .download:
            decisionHandler(.download)
        case let .requestExternalApplicationApproval(approval):
            decisionHandler(.cancel)
            onExternalApplicationApproval?(approval) { _ in
                // The AppKit owner performs any explicit approved handoff outside WebKit.
            }
        case .cancel:
            diagnostics.record(eventType: .policyDecision, url: url, result: .cancelled)
            decisionHandler(.cancel)
        }
    }

    private func externalApplicationTrigger(for action: WKNavigationAction) -> KeelExternalApplicationTrigger {
        Self.externalApplicationTrigger(for: action.navigationType)
    }

    /// WebKit marks ordinary submitted forms as a user action. A resubmission can come
    /// from browser state restoration or script, so it remains automatic until WebKit
    /// exposes a reliable explicit-activation signal for that case.
    static func externalApplicationTrigger(for navigationType: WKNavigationType) -> KeelExternalApplicationTrigger {
        switch navigationType {
        case .linkActivated, .formSubmitted:
            .userActivatedPage
        case .formResubmitted, .other, .backForward, .reload:
            .automaticPage
        @unknown default:
            .automaticPage
        }
    }

    private func showDetour(
        _ webView: WKWebView,
        id: UUID,
        parentPageID: UUID,
        parentWebView: WKWebView
    ) {
        guard detourOverlay == nil,
              registry.detourWebView(for: id) === webView
        else { return }
        let identity = KeelDetourPresentationIdentity(detourID: id, parentPageID: parentPageID)
        coveredParentAccessibility = CoveredParentAccessibility(
            identity: identity,
            webView: parentWebView,
            wasHidden: parentWebView.isAccessibilityHidden()
        )
        parentWebView.setAccessibilityHidden(true)
        let overlay = KeelDetourOverlay(id: id, hostname: webView.url?.host ?? "Transaction")
        overlay.onOutsideClick = { [weak self] in
            self?.enqueue(.closeTransactionalDetour(detourID: id))
        }
        overlay.onBack = { [weak self, weak webView] in
            guard self?.registry.detourWebView(for: id) === webView else { return }
            webView?.goBack()
        }
        overlay.onForward = { [weak self, weak webView] in
            guard self?.registry.detourWebView(for: id) === webView else { return }
            webView?.goForward()
        }
        overlay.onReload = { [weak self, weak webView] in
            guard self?.registry.detourWebView(for: id) === webView else { return }
            webView?.reload()
        }
        overlay.onClose = { [weak self] in
            self?.enqueue(.closeTransactionalDetour(detourID: id))
        }
        overlay.onFailureRetry = { [weak self, weak webView, weak overlay] in
            guard let self, let webView, self.registry.detourWebView(for: id) === webView else { return }
            self.detourFailures[id] = nil
            overlay?.clearFailure()
            overlay?.beginLoading()
            if webView.url != nil {
                webView.reload()
            } else if let url = self.detourURLs[id] {
                webView.load(URLRequest(url: url))
            }
        }
        overlay.onFailureClose = { [weak self] in
            self?.enqueue(.closeTransactionalDetour(detourID: id))
        }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        overlay.animateAppearance()
        webView.translatesAutoresizingMaskIntoConstraints = false
        overlay.pageContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: overlay.pageContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: overlay.pageContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: overlay.pageContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: overlay.pageContainer.bottomAnchor),
        ])
        detourOverlay = overlay
        visibleDetourID = id
        if let failure = detourFailures[id] {
            overlay.presentFailure(failure)
        } else if webView.isLoading || webView.url == nil {
            overlay.beginLoading()
        }
        _ = focusVisiblePage()
    }

    @discardableResult
    private func restoreCoveredParentAccessibility(for detour: KeelTransactionalDetour) -> Bool {
        guard let coveredParentAccessibility,
              coveredParentAccessibility.identity.matchesDismissal(detour),
              registry.activeWebView(for: detour.parentPageID) === coveredParentAccessibility.webView
        else { return false }
        coveredParentAccessibility.webView.setAccessibilityHidden(coveredParentAccessibility.wasHidden)
        self.coveredParentAccessibility = nil
        return true
    }

    private func restoreCoveredParentAccessibility(for detourID: UUID) {
        guard let coveredParentAccessibility,
              coveredParentAccessibility.identity.detourID == detourID
        else { return }
        coveredParentAccessibility.webView.setAccessibilityHidden(coveredParentAccessibility.wasHidden)
        self.coveredParentAccessibility = nil
    }

    private func restoreCoveredParentAccessibility() {
        guard let coveredParentAccessibility else { return }
        coveredParentAccessibility.webView.setAccessibilityHidden(coveredParentAccessibility.wasHidden)
        self.coveredParentAccessibility = nil
    }
}

@MainActor
private struct CoveredParentAccessibility {
    let identity: KeelDetourPresentationIdentity
    let webView: WKWebView
    let wasHidden: Bool
}

@MainActor
final class PageContext {
    let pageID: UUID
    let sessionID: UUID
    let detourID: UUID?
    private var bindings: [ObjectIdentifier: NavigationBinding] = [:]
    private var pendingBindings: [NavigationBinding] = []
    var lastCommittedBinding: NavigationBinding?
    private(set) var latestBinding: NavigationBinding?
    private var downloadHandoffCallbackID: UUID?

    func markDownloadHandoff() {
        downloadHandoffCallbackID = latestBinding?.callbackID
    }

    func isDownloadHandoff(_ binding: NavigationBinding) -> Bool {
        downloadHandoffCallbackID == binding.callbackID
    }
    var visitIDs: [UUID: UUID] = [:]
    var pendingTitles: [UUID: String] = [:]
    var resumeSeedCheckpoint: ResumeCheckpoint?
    var navigationAfterResumeCommit: KeelPendingNavigation?
    var historyTail: Task<Void, Never>?

    init(pageID: UUID, sessionID: UUID, detourID: UUID?) {
        self.pageID = pageID
        self.sessionID = sessionID
        self.detourID = detourID
    }

    func bind(_ binding: NavigationBinding, to navigation: WKNavigation?) {
        latestBinding = binding
        guard let navigation else {
            enqueuePending(binding)
            return
        }
        bindings[ObjectIdentifier(navigation)] = binding
    }

    func enqueuePending(_ binding: NavigationBinding) {
        latestBinding = binding
        pendingBindings.append(binding)
    }

    func removePendingBinding(navigationID: UUID) -> NavigationBinding? {
        guard let index = pendingBindings.firstIndex(where: { $0.navigationID == navigationID }) else {
            return nil
        }
        return pendingBindings.remove(at: index)
    }

    func binding(for navigation: WKNavigation?) -> NavigationBinding? {
        if let navigation, let binding = bindings[ObjectIdentifier(navigation)] { return binding }
        guard navigation != nil, !pendingBindings.isEmpty else { return nil }
        let binding = pendingBindings.removeFirst()
        bindings[ObjectIdentifier(navigation!)] = binding
        return binding
    }
}

struct NavigationBinding: Equatable {
    /// One WebKit load can supersede another while continuing the same product navigation.
    let callbackID = UUID()
    let pageID: UUID
    let navigationID: UUID
    let source: HistoryVisitSource
    let kind: HistoryNavigationKind
    let detourID: UUID?
    /// The prior navigation whose visit reload or replaceState updates after History settles.
    let currentVisitNavigationID: UUID?

    init(
        pageID: UUID,
        navigationID: UUID,
        source: HistoryVisitSource,
        kind: HistoryNavigationKind,
        detourID: UUID?,
        currentVisitNavigationID: UUID? = nil
    ) {
        self.pageID = pageID
        self.navigationID = navigationID
        self.source = source
        self.kind = kind
        self.detourID = detourID
        self.currentVisitNavigationID = currentVisitNavigationID
    }
}

@MainActor
final class KeelDetourOverlay: NSView {
    let panel = NSVisualEffectView()
    let pageContainer = NSView()
    let detourID: UUID
    var onOutsideClick: (() -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?
    var onClose: (() -> Void)?
    var onFailureRetry: (() -> Void)?
    var onFailureClose: (() -> Void)?

    private let loadingIndicator = NSProgressIndicator()
    private let errorView = KeelPageErrorView()
    private(set) var isLoading = false
    private(set) var presentedFailure: KeelPageFailure?

    init(id: UUID, hostname: String) {
        detourID = id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.38).cgColor
        panel.shadow = NSShadow()
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.3
        panel.layer?.shadowRadius = 30
        panel.layer?.shadowOffset = CGSize(width: 0, height: -10)
        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 12
        panel.layer?.masksToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.88),
            panel.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.88),
        ])
        let toolbar = NSVisualEffectView()
        toolbar.material = .headerView
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(toolbar)
        let back = button(symbol: "chevron.backward", label: "Back", action: #selector(backPressed))
        let forward = button(symbol: "chevron.forward", label: "Forward", action: #selector(forwardPressed))
        let reload = button(symbol: "arrow.clockwise", label: "Reload", action: #selector(reloadPressed))
        let close = button(symbol: "xmark", label: "Close transaction", action: #selector(closePressed))

        let lockIcon = NSImageView()
        lockIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        lockIcon.contentTintColor = .tertiaryLabelColor
        let title = NSTextField(labelWithString: hostname)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        title.alignment = .center
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The hostname is centred in the bar. It used to be the fourth item in a
        // plain stack, which parked Close in the middle for a short hostname.
        let titleGroup = NSStackView(views: [lockIcon, title])
        titleGroup.orientation = .horizontal
        titleGroup.spacing = 4
        titleGroup.alignment = .centerY
        titleGroup.translatesAutoresizingMaskIntoConstraints = false

        let leading = NSStackView(views: [back, forward, reload])
        leading.orientation = .horizontal
        leading.spacing = 2
        leading.translatesAutoresizingMaskIntoConstraints = false
        close.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addSubview(leading)
        toolbar.addSubview(titleGroup)
        toolbar.addSubview(close)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: panel.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 38),
            leading.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            leading.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            titleGroup.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),
            titleGroup.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            titleGroup.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 8),
            titleGroup.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
        ])

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
        ])
        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(pageContainer)
        NSLayoutConstraint.activate([
            pageContainer.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            pageContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])

        // Both of these sit above the detour's web view, which the controller adds to
        // pageContainer later. A slow sign-in used to be a blank panel, and a failed
        // one stayed blank for good.
        loadingIndicator.style = .spinning
        loadingIndicator.isIndeterminate = true
        loadingIndicator.isDisplayedWhenStopped = false
        loadingIndicator.controlSize = .regular
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(loadingIndicator)

        errorView.isHidden = true
        errorView.onRetry = { [weak self] in self?.onFailureRetry?() }
        errorView.onCloseDetour = { [weak self] in self?.onFailureClose?() }
        panel.addSubview(errorView)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: pageContainer.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: pageContainer.centerYAnchor),
            errorView.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            errorView.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            errorView.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
        ])
    }

    func beginLoading() {
        guard presentedFailure == nil, !isLoading else { return }
        isLoading = true
        loadingIndicator.startAnimation(nil)
    }

    func endLoading() {
        guard isLoading else { return }
        isLoading = false
        loadingIndicator.stopAnimation(nil)
    }

    func presentFailure(_ failure: KeelPageFailure) {
        endLoading()
        presentedFailure = failure
        errorView.present(failure: failure, exits: .transactionalDetour)
        errorView.isHidden = false
    }

    func clearFailure() {
        guard presentedFailure != nil else { return }
        presentedFailure = nil
        errorView.isHidden = true
    }

    /// Fades the scrim in. It used to snap to full opacity in one frame.
    func animateAppearance() {
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeelDetourOverlay must be created in code")
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(location) {
            onOutsideClick?()
            return
        }
        super.mouseDown(with: event)
    }

    private func button(symbol: String, label: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 11.5, weight: .medium))
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        // Borderless, like every other control Keel draws. The detour was the
        // only place in the app with bezelled toolbar buttons.
        button.isBordered = false
        button.bezelStyle = .inline
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
        return button
    }

    @objc private func backPressed() { onBack?() }
    @objc private func forwardPressed() { onForward?() }
    @objc private func reloadPressed() { onReload?() }
    @objc private func closePressed() { onClose?() }
}
