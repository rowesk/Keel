import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import KeelCoordinator
import KeelFoundation
import KeelStore
import KeelUI
import KeelWeb

@MainActor
final class KeelApplicationDelegate: NSObject, NSApplicationDelegate {
    private static let managementDownloadLimit = 200
    private lazy var recoveryController = KeelRecoveryController(savePanel: diagnosticsSavePanel)
    private let interactionReceipt = KeelInteractionReceiptController()
    private var didExplainHistoryFailure = false
    private var didExplainTransitionFailure = false

    private let makeStore: () throws -> KeelStore
    private let appearanceController: KeelAppearanceController
    private let addressPalette: KeelAddressPaletteController
    /// What Home's embedded copy of the palette looks like right now.
    private let embeddedPaletteState = KeelEmbeddedPaletteState()
    private let findController: KeelFindController
    private let downloadShelf: KeelDownloadShelfController
    private let nativeScreenHost: KeelNativeScreenHost
    private let diagnosticsSavePanel: any KeelDiagnosticsSavePanelPresenting
    private let errorPresenter: any KeelAppErrorPresenting
    private let queueDeletionUndoExpiry: KeelQueueDeletionUndoExpiryController
    private let diagnosticsPresence: KeelDiagnosticsPresenceCache
    private let focusVisiblePageOverride: (@MainActor () -> Void)?

    private var store: KeelStore?
    private var coordinator: KeelCoordinator?
    private var browserController: KeelBrowserController?
    private var addressSuggestionPresenter: KeelAddressSuggestionPresenter?
    private var externalApplicationHandoffController: KeelExternalApplicationHandoffController?
    private var windowController: KeelWindowController?
    private var shellView: KeelShellView?
    private var nativeScreenFavicons: KeelNativeScreenFaviconCache?
    private var addressBarFaviconGeneration = 0
    private var escapeMonitor: Any?
    private(set) var coordinatorState: KeelCoordinatorState?
    var interactionReceiptForTesting: KeelInteractionReceiptController { interactionReceipt }
    var shellViewForTesting: KeelShellView? { shellView }
    var onTransitionFailureForTesting: (() -> Void)?
    var onStateForTesting: ((KeelCoordinatorState) -> Void)?
    private var presentsWindows = true
    private(set) var storedPreferencesApplied = false
    private var didAttemptFirstLaunchExplanation = false
    private var liveDownloadSnapshots: [KeelDownloadSnapshot] = []
    private var historyModel: KeelHistoryModel?
    private var historyVisitURLs: [UUID: URL] = [:]
    private var managementLoadTask: Task<Void, Never>?
    private var managementLoadGeneration = 0
    private var visibleManagementScreen: KeelManagementScreen?
    private var terminationInProgress = false
    private var destinationTitles: [String: String] = [:]
    private var destinationTitleTask: Task<Void, Never>?
    private var historySessionCursor: HistorySessionCursor?
    private var loadedHistorySessions: [KeelHistorySession] = []
    private var historyHasOlderSessions = false
    private var historySearchQuery = ""
    private var historyPagingTask: Task<Void, Never>?
    private var historySearchTask: Task<Void, Never>?
    private var resolvedDownloadDirectory: URL?
    private(set) var homeSceneController: KeelHomeSceneController?
    /// True while Home is the visible surface. Rotation advances on the edge
    /// into Home, not on the re-renders that follow.
    private var homeSurfaceIsVisible = false
    /// What the page last published, so a surface change can redraw the bar.
    private var lastPagePresentation: KeelPagePresentation?
    private lazy var shortcutsWindow = KeelShortcutsWindowController()

    init(
        makeStore: @escaping () throws -> KeelStore = { try KeelStore() },
        appearanceController: KeelAppearanceController = KeelAppearanceController(),
        addressPalette: KeelAddressPaletteController = KeelAddressPaletteController(),
        findController: KeelFindController = KeelFindController(),
        downloadShelf: KeelDownloadShelfController = KeelDownloadShelfController(),
        addressSuggestionPresenter: KeelAddressSuggestionPresenter? = nil,
        nativeScreenHost: KeelNativeScreenHost = KeelNativeScreenHost(),
        diagnosticsSavePanel: any KeelDiagnosticsSavePanelPresenting = KeelAppKitDiagnosticsSavePanel(),
        errorPresenter: any KeelAppErrorPresenting = KeelAppKitErrorPresenter(),
        queueDeletionUndoExpiry: KeelQueueDeletionUndoExpiryController = KeelQueueDeletionUndoExpiryController(),
        diagnosticsPresence: KeelDiagnosticsPresenceCache = KeelDiagnosticsPresenceCache(),
        focusVisiblePage: (@MainActor () -> Void)? = nil
    ) {
        self.makeStore = makeStore
        self.appearanceController = appearanceController
        self.addressPalette = addressPalette
        self.findController = findController
        self.downloadShelf = downloadShelf
        self.addressSuggestionPresenter = addressSuggestionPresenter
        self.nativeScreenHost = nativeScreenHost
        self.diagnosticsSavePanel = diagnosticsSavePanel
        self.errorPresenter = errorPresenter
        self.queueDeletionUndoExpiry = queueDeletionUndoExpiry
        self.diagnosticsPresence = diagnosticsPresence
        self.focusVisiblePageOverride = focusVisiblePage
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try configureProductionApp()
        } catch {
            presentStartupFailure(error)
        }
    }

    func presentStartupFailure(_ error: Error) {
        recoveryController.showStartupFailure(error: error) { [weak self] in
            guard let self else { return }
            do {
                try configureProductionApp()
                recoveryController.close()
            } catch {
                presentStartupFailure(error)
            }
        }
    }

    private func presentFirstLaunchExplanation() {
        let key = "Keel.hasSeenOnePageIntroduction"
        guard !UserDefaults.standard.bool(forKey: key), let window = windowController?.window else { return }
        let alert = NSAlert()
        alert.messageText = "One page at a time"
        alert.informativeText = "Open a page with Return. Use Command-Return to add a destination to the queue. Closing your page opens the next queued destination. Home keeps unfinished work available to resume."
        alert.addButton(withTitle: "Start browsing")
        alert.beginSheetModal(for: window) { _ in
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else {
            return true
        }
        if coordinatorState == nil, recoveryController.reopenIfNeeded() { return true }
        windowController?.showSoleWindow()
        browserController?.handle(.recoverSoleWindow)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            browserController?.receiveExternalURL(url)
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        browserController?.checkpointActivePage()
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeEscapeMonitor()
        windowController?.removeHiddenChromeDragMonitor()
        managementLoadTask?.cancel()
        queueDeletionUndoExpiry.cancel()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let browserController else {
            return .terminateNow
        }

        guard !terminationInProgress else {
            return .terminateLater
        }
        terminationInProgress = true

        if KeelTerminationPolicy.hasInProgressDownloads(browserController.downloads) {
            confirmTerminationWithDownloads(browserController)
        } else {
            finishTermination(using: browserController, cancelActiveDownloads: false)
        }
        return .terminateLater
    }

    @objc
    private func sendUndo(_ sender: Any?) {
        NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: sender)
    }

    @objc
    private func sendRedo(_ sender: Any?) {
        NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: sender)
    }

    @objc
    private func sendCut(_ sender: Any?) {
        NSApp.sendAction(NSSelectorFromString("cut:"), to: nil, from: sender)
    }

    @objc
    private func sendCopy(_ sender: Any?) {
        NSApp.sendAction(NSSelectorFromString("copy:"), to: nil, from: sender)
    }

    @objc
    private func sendPaste(_ sender: Any?) {
        NSApp.sendAction(NSSelectorFromString("paste:"), to: nil, from: sender)
    }

    @objc
    private func sendSelectAll(_ sender: Any?) {
        NSApp.sendAction(NSSelectorFromString("selectAll:"), to: nil, from: sender)
    }
}

@MainActor
enum KeelDetourCommandPolicy {
    static func allows(_ command: KeelChromeCommand, whileDetourIsActive isActive: Bool) -> Bool {
        guard isActive else {
            return true
        }

        switch command {
        case .back, .forward, .reload, .reloadFromOrigin, .closePage,
             .printPage, .zoomIn, .zoomOut, .resetZoom,
             .showSoleWindow, .toggleChrome:
            return true
        // A detour is a subordinate context. Anything that would change which
        // page Keel owns stays blocked until it closes.
        case .showAddressPalette, .newAddress, .copyCurrentURL, .showHome,
             .requeueAndClosePage, .restoreCloseUndo, .addCurrentURLToQueue,
             .startQueue, .findInPage, .findNext, .findPrevious:
            return false
        }
    }
}

@MainActor
enum KeelAddressSuggestionSubmissionPolicy {
    case blocked
    case sendAndKeepPalette
    case sendAndDismissPalette

    static func action(detourIsActive: Bool, addressSubmissionIsAllowed: Bool) -> Self {
        if detourIsActive {
            return .sendAndKeepPalette
        }
        return addressSubmissionIsAllowed ? .sendAndDismissPalette : .blocked
    }
}

@MainActor
enum KeelManagementCommandPolicy {
    static func allows(
        modalWindowIsPresented: Bool,
        attachedSheetIsPresented: Bool
    ) -> Bool {
        !modalWindowIsPresented && !attachedSheetIsPresented
    }
}

extension KeelApplicationDelegate {
    func confirmTerminationWithDownloads(_ browserController: KeelBrowserController) {
        guard let window = windowController?.window else {
            terminationInProgress = false
            NSApp.reply(toApplicationShouldTerminate: false)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Downloads are still in progress"
        alert.informativeText = "Keep Keel running to finish them, or cancel the downloads and quit."
        alert.addButton(withTitle: "Keep Keel Running")
        alert.addButton(withTitle: "Cancel Downloads and Quit")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else {
                return
            }
            guard response != .alertFirstButtonReturn else {
                self.terminationInProgress = false
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }

            self.finishTermination(using: browserController, cancelActiveDownloads: true)
        }
    }

    func finishTermination(
        using browserController: KeelBrowserController,
        cancelActiveDownloads: Bool
    ) {
        Task { @MainActor [weak self] in
            await browserController.prepareForTermination(cancelActiveDownloads: cancelActiveDownloads)
            self?.terminationInProgress = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    func configureProductionApp(presentsWindow: Bool = true, isolatedScenePaths: KeelPaths? = nil) throws {
        presentsWindows = presentsWindow
        let store = try makeStore()
        let coordinator = KeelCoordinator(store: store)
        let shellView = makeShellView()
        let browserContentView = makeBrowserContentView(in: shellView)
        installNativeScreenHost(in: shellView)

        let browserController = presentsWindow
            ? KeelBrowserController(contentView: browserContentView, coordinator: coordinator, store: store)
            : KeelBrowserController(contentView: browserContentView, coordinator: coordinator, store: store,
                                    websiteDataStore: .nonPersistent())
        let addressSuggestionPresenter = presentsWindow
            ? KeelAddressSuggestionPresenter(store: store, faviconLoader: KeelFaviconLoader())
            : KeelAddressSuggestionPresenter(lookup: { try await store.addressSuggestions(for: $0).suggestions })
        let chromeController = KeelChromeController()
        let windowController = KeelWindowController(
            shellView: shellView,
            chromeController: chromeController,
            permitsWindowPresentation: presentsWindow
        )
        windowController.window?.center()
        if let window = windowController.window {
            appearanceController.apply(.system, to: window)
        }
        _ = resolvedDownloadDirectory

        self.store = store
        self.coordinator = coordinator
        self.browserController = browserController
        self.addressSuggestionPresenter = addressSuggestionPresenter
        self.windowController = windowController
        self.shellView = shellView
        interactionReceipt.install(in: shellView)
        if presentsWindow {
            self.nativeScreenFavicons = KeelNativeScreenFaviconCache { [weak self] in
                self?.refreshFaviconDependentScreens()
            }
            self.homeSceneController = makeHomeSceneController(store: store, windowController: windowController)
        }
        if !presentsWindow, let isolatedScenePaths {
            self.homeSceneController = makeHomeSceneController(store: store, windowController: windowController, paths: isolatedScenePaths)
        }
        self.queueDeletionUndoExpiry.onExpired = { [weak self] deadline in
            self?.browserController?.handle(.queueDeletionUndoExpired(deadline: deadline))
        }
        self.externalApplicationHandoffController = KeelExternalApplicationHandoffController(
            store: store,
            windowProvider: { [weak windowController] in
                windowController?.showSoleWindow()
                return windowController?.window
            }
        )

        installDownloadShelf()
        installPaletteCallbacks()
        installFindCallbacks()
        installChromeCallbacks(chromeController)
        installBrowserMenu(using: chromeController)
        installBrowserCallbacks(browserController, chromeController: chromeController)
        if presentsWindow { installEscapeMonitor() }

        windowController.showSoleWindow()
        browserController.start()
        refreshChromeState()
        refreshDownloadShelf()
        applyStoredPreferences(store)
    }

    /// Appearance and the download directory are stored, so they have to be put
    /// back before the first frame rather than left at their defaults.
    private func applyStoredPreferences(_ store: KeelStore) {
        Task { @MainActor [weak self] in
            guard let self, let settings = try? await store.runtimeState().settings else { return }
            self.applyAppearance(settings.appearance)
            self.refreshDownloadDirectory(settings)
            self.browserController?.defaultPageZoom = settings.defaultPageZoom.scale
            self.homeSceneController?.settingsDidChange(settings)
            await self.homeSceneController?.loadLibrary()
            self.storedPreferencesApplied = true
        }
    }

    func handlePerformanceEvent(_ event: KeelCoordinatorEvent) {
        browserController?.handle(event)
    }

    func updateNativeScreens(for state: KeelCoordinatorState) {
        queueDeletionUndoExpiry.update(
            deadline: state.runtimeState.queueDeletionUndo?.deadline
        )

        homeSceneController?.settingsDidChange(state.runtimeState.settings)

        switch state.surface {
        case .home:
            visibleManagementScreen = nil
            // The one arrival point. Launch, a closed page, a discarded page
            // and a finished queue all land here, and each is one edge into
            // Home rather than a re-render of it.
            if !homeSurfaceIsVisible {
                homeSurfaceIsVisible = true
                homeSceneController?.arriveAtHome()
            }
            renderHome(for: state)
        case .page:
            let wasManagementVisible = visibleManagementScreen != nil
            visibleManagementScreen = nil
            leaveHome()
            nativeScreenHost.hide()
            if wasManagementVisible, !modalPanelOwnsInput {
                focusVisiblePage()
            }
        case let .management(screen):
            leaveHome()
            if visibleManagementScreen != screen {
                // Do not leave Home or the previous management screen interactive
                // while Store-backed data for the new screen is loading.
                nativeScreenHost.hide()
                visibleManagementScreen = screen
                loadManagementData(for: screen)
            } else {
                updateVisibleManagementState(from: state)
            }
        }
    }

    /// Every Home render goes through here so the photograph, the model and
    /// the embedded palette always arrive together.
    private func renderHome(for state: KeelCoordinatorState) {
        nativeScreenHost.showHome(
            model: KeelAppPresentationMapper.homeModel(
                from: state,
                favicons: nativeScreenFavicons,
                titles: destinationTitles
            ),
            actions: homeActions(),
            addressField: AnyView(KeelEmbeddedAddressField(state: embeddedPaletteState, palette: addressPalette)),
            scene: homeSceneController?.currentDisplay ?? .como
        )
    }

    /// Leaving Home is when the next photograph is worth decoding, because the
    /// window is showing something else while it happens.
    private func leaveHome() {
        guard homeSurfaceIsVisible else { return }
        homeSurfaceIsVisible = false
        homeSceneController?.prefetchNext()
    }

    func makeHomeSceneController(
        store: KeelStore,
        windowController: KeelWindowController,
        paths suppliedPaths: KeelPaths? = nil
    ) -> KeelHomeSceneController? {
        guard let paths = suppliedPaths ?? (try? KeelPathProvider.paths()) else { return nil }
        let controller = KeelHomeSceneController(
            store: store,
            paths: paths,
            window: { [weak windowController] in windowController?.window },
            persistSettings: { [weak self] settings in
                self?.browserController?.handle(.replaceSettings(settings))
            }
        )
        controller.onDisplayChange = { [weak self] in
            guard let self, let state = self.coordinatorState, case .home = state.surface else { return }
            self.renderHome(for: state)
        }
        controller.onLibraryChange = { [weak self] in
            guard let self, let state = self.coordinatorState,
                  case .management(.settings) = state.surface,
                  self.nativeScreenHost.screen == .settings
            else { return }
            self.updateVisibleManagementState(from: state)
        }
        return controller
    }

    private var modalPanelOwnsInput: Bool {
        NSApp.modalWindow != nil || windowController?.window?.attachedSheet != nil
    }

    private func focusVisiblePage() {
        if let focusVisiblePageOverride {
            focusVisiblePageOverride()
        } else {
            _ = browserController?.focusVisiblePage()
        }
    }

    private func updateVisibleManagementState(from state: KeelCoordinatorState) {
        switch state.surface {
        case .management(.history):
            guard nativeScreenHost.screen == .history,
                  let historyModel
            else { return }
            nativeScreenHost.showHistory(model: historyModel, actions: historyActions())
        case .management(.settings):
            // Settings are wholly represented by coordinator runtime state, so this
            // update does not need another Store read.
            guard nativeScreenHost.screen == .settings else { return }
            let currentModel = KeelAppPresentationMapper.settingsModel(
                from: state.runtimeState.settings,
                hasDiagnostics: diagnosticsPresence.hasDiagnostics,
                homeScenes: homeSceneController?.tiles() ?? []
            )
            nativeScreenHost.showSettings(model: currentModel, actions: settingsActions())
        case .management(.downloads):
            guard nativeScreenHost.screen == .downloads else { return }
            let model = Self.downloadManagementModel(
                records: state.runtimeState.downloads,
                liveSnapshots: liveDownloadSnapshots
            )
            nativeScreenHost.showDownloads(model: model, actions: downloadActions())
        default:
            break
        }
    }

    func updateVisibleDownloads() {
        guard let state = coordinatorState else { return }
        guard case .management(.downloads) = state.surface else { return }
        updateVisibleManagementState(from: state)
    }

    /// Combines Store records with live WebKit snapshots before applying the same
    /// newest-first, created-at/id ordering and 200-row bound as the Store query.
    /// A live snapshot replaces its durable record for the same identifier.
    static func downloadManagementModel(
        records: [DownloadRecord],
        liveSnapshots: [KeelDownloadSnapshot]
    ) -> KeelDownloadModel {
        var recordsByID: [UUID: DownloadRecord] = [:]
        for record in records {
            recordsByID[record.id] = record
        }
        var snapshotsByID: [UUID: KeelDownloadSnapshot] = [:]
        for snapshot in liveSnapshots {
            snapshotsByID[snapshot.id] = snapshot
        }

        let orderedIDs = Set(recordsByID.keys).union(snapshotsByID.keys).sorted { left, right in
            let leftDate = snapshotsByID[left]?.createdAt ?? recordsByID[left]?.createdAt ?? .distantPast
            let rightDate = snapshotsByID[right]?.createdAt ?? recordsByID[right]?.createdAt ?? .distantPast
            if leftDate != rightDate {
                return leftDate > rightDate
            }
            return left.uuidString > right.uuidString
        }
        let visibleIDs = Set(orderedIDs.prefix(managementDownloadLimit))

        return KeelAppPresentationMapper.downloadModel(
            records: records.filter { visibleIDs.contains($0.id) },
            liveSnapshots: liveSnapshots.filter { visibleIDs.contains($0.id) }
        )
    }

    func loadManagementData(for screen: KeelManagementScreen) {
        managementLoadTask?.cancel()
        managementLoadGeneration &+= 1
        let loadGeneration = managementLoadGeneration
        guard let store else { return }
        managementLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch screen {
                case .history:
                    let history = try await loadHistory(from: store)
                    guard !Task.isCancelled,
                          loadGeneration == managementLoadGeneration,
                          case .management(.history) = coordinatorState?.surface
                    else { return }
                    historyModel = history.model
                    historyVisitURLs = history.visitURLs
                    nativeScreenHost.showHistory(model: history.model, actions: historyActions())
                case .downloads:
                    let records = try await store.downloadRecords(limit: 200)
                    guard !Task.isCancelled,
                          loadGeneration == managementLoadGeneration,
                          case .management(.downloads) = coordinatorState?.surface
                    else { return }
                    nativeScreenHost.showDownloads(
                        model: Self.downloadManagementModel(
                            records: records,
                            liveSnapshots: liveDownloadSnapshots
                        ),
                        actions: downloadActions()
                    )
                case .settings:
                    let runtimeState = try await store.runtimeState()
                    let settings = runtimeState.settings
                    let hasDiagnostics = try !(await store.diagnostics()).isEmpty
                    guard !Task.isCancelled,
                          loadGeneration == managementLoadGeneration,
                          case .management(.settings) = coordinatorState?.surface
                    else { return }
                    diagnosticsPresence.update(hasDiagnostics: hasDiagnostics)
                    nativeScreenHost.showSettings(
                        model: KeelAppPresentationMapper.settingsModel(
                            from: settings,
                            hasDiagnostics: hasDiagnostics,
                            homeScenes: homeSceneController?.tiles() ?? []
                        ),
                        actions: settingsActions()
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      loadGeneration == managementLoadGeneration,
                      case let .management(currentScreen)? = coordinatorState?.surface,
                      currentScreen == screen
                else { return }
                showRecoverableManagementScreen(for: screen)
                visibleManagementScreen = nil
                presentManagementError(error)
            }
        }
    }

    private func showRecoverableManagementScreen(for screen: KeelManagementScreen) {
        guard let state = coordinatorState else { return }

        switch screen {
        case .history:
            nativeScreenHost.showHistory(
                model: historyModel ?? KeelHistoryModel(),
                actions: historyActions()
            )
        case .downloads:
            nativeScreenHost.showDownloads(
                model: Self.downloadManagementModel(
                    records: state.runtimeState.downloads,
                    liveSnapshots: liveDownloadSnapshots
                ),
                actions: downloadActions()
            )
        case .settings:
            nativeScreenHost.showSettings(
                model: KeelAppPresentationMapper.settingsModel(
                    from: state.runtimeState.settings,
                    hasDiagnostics: diagnosticsPresence.hasDiagnostics,
                    homeScenes: homeSceneController?.tiles() ?? []
                ),
                actions: settingsActions()
            )
        }
    }

    /// Loads the first page only. The previous version read every session ever
    /// recorded and then ran one visit query per session, which grew without
    /// bound because History is permanent.
    private func loadHistory(from store: KeelStore) async throws -> (model: KeelHistoryModel, visitURLs: [UUID: URL]) {
        historySessionCursor = nil
        loadedHistorySessions = []
        historySearchQuery = ""

        let page = try await store.endedHistorySessionPage()
        let activeSession = coordinatorState?.runtimeState.activeSession

        let visits = try await store.historyVisits(
            inSessions: Self.historySessionIDsToLoad(
                page: page.sessions,
                activeSessionID: activeSession?.id
            )
        )
        let summaries = page.sessions

        historySessionCursor = page.nextCursor
        historyHasOlderSessions = page.nextCursor != nil

        let built = KeelAppPresentationMapper.historyModel(
            activeSession: activeSession,
            endedSessions: summaries,
            visitsBySession: visits,
            favicons: nativeScreenFavicons,
            hasOlderSessions: historyHasOlderSessions
        )
        loadedHistorySessions = built.model.sessions
        return built
    }

    /// The active session is never in a page of *ended* sessions, but the
    /// presentation mapper adds it anyway. Its visits have to be fetched
    /// explicitly, or the session the user is in renders as "No visits".
    static func historySessionIDsToLoad(
        page: [HistorySessionSummary],
        activeSessionID: UUID?
    ) -> [UUID] {
        var ids = page.map(\.id)
        if let activeSessionID, !ids.contains(activeSessionID) {
            ids.append(activeSessionID)
        }
        return ids
    }

    /// Appends the next page to what is already on screen.
    private func loadOlderHistorySessions() {
        guard let store, let cursor = historySessionCursor, historyPagingTask == nil else { return }
        republishHistory(isLoadingOlder: true)

        historyPagingTask = Task { @MainActor [weak self] in
            defer { self?.historyPagingTask = nil }
            guard let self else { return }
            do {
                let page = try await store.endedHistorySessionPage(before: cursor)
                let visits = try await store.historyVisits(inSessions: page.sessions.map(\.id))
                guard case .management(.history)? = self.coordinatorState?.surface else { return }

                let older = KeelAppPresentationMapper.historyModel(
                    activeSession: nil,
                    endedSessions: page.sessions,
                    visitsBySession: visits,
                    favicons: self.nativeScreenFavicons,
                    hasOlderSessions: page.nextCursor != nil
                )
                self.historyVisitURLs.merge(older.visitURLs) { _, new in new }
                self.loadedHistorySessions.append(contentsOf: older.model.sessions)
                self.historySessionCursor = page.nextCursor
                self.historyHasOlderSessions = page.nextCursor != nil
                self.republishHistory()
            } catch {
                self.republishHistory()
            }
        }
    }

    /// Searches every recorded visit, not only the pages already loaded. The
    /// view debounces, so this runs once per settled query.
    private func searchHistory(_ query: String) {
        guard let store else { return }
        historySearchTask?.cancel()
        historySearchQuery = query

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            republishHistory()
            return
        }

        republishHistory(isSearching: true)
        historySearchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await store.searchHistoryVisits(matching: trimmed)
                guard !Task.isCancelled,
                      self.historySearchQuery == query,
                      case .management(.history)? = self.coordinatorState?.surface
                else { return }

                var visitsBySession: [UUID: [HistoryVisit]] = [:]
                for visit in result.visits {
                    visitsBySession[visit.browsingSessionID, default: []].append(visit)
                }
                let found = KeelAppPresentationMapper.historyModel(
                    activeSession: nil,
                    endedSessions: result.sessions,
                    visitsBySession: visitsBySession,
                    favicons: self.nativeScreenFavicons,
                    searchQuery: query,
                    searchReachedLimit: result.reachedLimit
                )
                self.historyVisitURLs.merge(found.visitURLs) { _, new in new }
                self.historyModel = found.model
                self.nativeScreenHost.showHistory(model: found.model, actions: self.historyActions())
            } catch is CancellationError {
                return
            } catch {
                self.republishHistory()
            }
        }
    }

    /// Rebuilds the History model from what is already loaded. Used for paging
    /// and loading flags, and to leave a search.
    private func republishHistory(isLoadingOlder: Bool = false, isSearching: Bool = false) {
        guard nativeScreenHost.screen == .history else { return }
        let model = KeelHistoryModel(
            sessions: loadedHistorySessions,
            hasOlderSessions: historyHasOlderSessions,
            isLoadingOlderSessions: isLoadingOlder,
            searchQuery: isSearching ? historySearchQuery : "",
            isSearching: isSearching,
            hasAnyHistory: true
        )
        historyModel = model
        nativeScreenHost.showHistory(model: model, actions: historyActions())
    }

    /// Page titles Keel already recorded in History, keyed by address. Queue,
    /// Undo and Resume rows previously showed only a hostname and a raw URL.
    func refreshDestinationTitles() {
        guard let store, let state = coordinatorState else { return }
        var wanted: Set<URL> = Set(state.runtimeState.queue.map(\.url))
        if let resume = state.runtimeState.resumeCheckpoint { wanted.insert(resume.url) }
        if let undo = state.undoPage { wanted.insert(undo.page.url) }
        let missing = wanted.filter { destinationTitles[$0.absoluteString] == nil }
        guard !missing.isEmpty else { return }

        destinationTitleTask?.cancel()
        destinationTitleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // One query for the whole set. This used to be one actor hop per URL.
            guard let titles = try? await store.recordedTitles(for: Array(missing)) else { return }
            var found: [String: String] = [:]
            for (url, title) in titles where !title.isEmpty {
                found[url.absoluteString] = title
            }
            guard !Task.isCancelled, !found.isEmpty else { return }
            self.destinationTitles.merge(found) { _, new in new }
            self.refreshFaviconDependentScreens()
        }
    }

    /// Re-renders whichever Keel-owned screen is on screen after an icon or a
    /// title arrives. Nothing else in the app changes.
    func refreshFaviconDependentScreens() {
        guard let state = coordinatorState else { return }
        switch state.surface {
        case .home:
            renderHome(for: state)
        case .management(.history):
            guard nativeScreenHost.screen == .history else { return }
            reloadVisibleManagementData()
        default:
            break
        }
        chromeController?.updateAddressFavicon(
            nativeScreenFavicons?.icon(for: browserController?.activeURL)?.image
        )
    }

    var chromeController: KeelChromeController? {
        windowController?.chromeController
    }

    func reloadVisibleManagementData() {
        guard case let .management(screen)? = coordinatorState?.surface else { return }
        loadManagementData(for: screen)
    }

    private func presentManagementError(_ error: Error) {
        errorPresenter.present(
            message: "Keel could not load this screen",
            informativeText: String(describing: error),
            in: windowController?.window
        )
    }

    func presentDiagnosticsExport(_ data: Data) {
        diagnosticsSavePanel.save(
            data: data,
            suggestedFileName: "keel-diagnostics.json",
            in: windowController?.window
        ) { [weak self] result in
            guard let self else { return }
            guard case let .failure(error) = result, error != .cancelled else { return }
            self.errorPresenter.present(
                message: "Keel could not export diagnostics",
                informativeText: String(describing: error),
                in: self.windowController?.window
            )
        }
    }

    func homeActions() -> KeelHomeActions {
        KeelHomeActions { [weak self] action in
            self?.handleHomeAction(action)
        }
    }

    private func handleHomeAction(_ action: KeelHomeAction) {
        switch action {
        case .openAddress:
            presentAddressPalette()
        case .resume:
            browserController?.handle(.resumeCheckpoint)
        case .restoreClosedPage:
            browserController?.handle(.restoreCloseUndo)
        case .discardResume:
            browserController?.handle(.discardResumeCheckpoint)
        case .discardClosedPage:
            browserController?.handle(.discardCloseUndo)
        case .startQueue:
            // The coordinator re-checks its own guards, so Home cannot skip FIFO
            // order. It only asks for the oldest destination.
            browserController?.handle(.openNextQueuedDestination)
        case .selectQueueItem:
            // Selection is local to Home. It must never consume or skip FIFO work.
            break
        case .showHistory:
            showManagement(.history)
        case .showDownloads:
            showManagement(.downloads)
        case .showSettings:
            showManagement(.settings)
        case let .deleteQueueItems(ids):
            browserController?.handle(.removeQueuedDestinations(ids: ids))
        case .clearQueue:
            browserController?.handle(.clearQueuedDestinations)
        case .restoreQueueDeletionUndo:
            browserController?.handle(.restoreQueueDeletionUndo)
        }
    }

    func historyActions() -> KeelHistoryActions {
        KeelHistoryActions { [weak self] action in
            self?.handleHistoryAction(action)
        }
    }

    private func handleHistoryAction(_ action: KeelHistoryAction) {
        switch action {
        case .dismiss:
            browserController?.dismissManagement()
        case let .openVisit(id):
            guard let url = historyVisitURLs[id] else { return }
            browserController?.handle(.openHistoryURL(url))
        case let .deleteVisit(id):
            browserController?.handle(.deleteHistory(.visits([id])))
        case let .deleteVisits(ids):
            browserController?.handle(.deleteHistory(.visits(ids)))
        case let .deleteHostnameGroup(sessionID, branchID, groupID):
            browserController?.handle(.deleteHistory(.hostnameGroup(
                sessionID: sessionID,
                branchID: HistoryBranchID(rawValue: branchID),
                groupID: groupID
            )))
        case let .deleteSession(id):
            browserController?.handle(.deleteHistory(.session(id)))
        case .deleteAll:
            browserController?.handle(.deleteHistory(.all))
        case .loadOlderSessions:
            loadOlderHistorySessions()
        case let .search(query):
            searchHistory(query)
        }
    }

    func downloadActions() -> KeelDownloadActions {
        KeelDownloadActions { [weak self] action in
            self?.handleDownloadAction(action)
        }
    }

    private func handleDownloadAction(_ action: KeelDownloadAction) {
        switch action {
        case .dismiss:
            browserController?.dismissManagement()
        case let .open(id):
            browserController?.handle(.openDownload(id: id))
        case let .showInFinder(id):
            browserController?.handle(.revealDownload(id: id))
        case let .cancel(id):
            browserController?.handle(.cancelDownload(id: id))
        case let .deleteRecords(ids):
            browserController?.handle(.removeDownloads(ids: ids))
        case .deleteAllRecords:
            guard let state = coordinatorState else { return }
            browserController?.handle(.removeDownloads(ids: Set(state.runtimeState.downloads.map(\.id))))
        }
    }

    func settingsActions() -> KeelSettingsActions {
        KeelSettingsActions { [weak self] action in
            self?.handleSettingsAction(action)
        }
    }

    private func handleSettingsAction(_ action: KeelSettingsAction) {
        guard let browserController, let currentSettings = coordinatorState?.runtimeState.settings else {
            return
        }

        // Mutate the stored settings in place. Rebuilding them from the view
        // model used to drop any field the model did not carry.
        var next = currentSettings
        switch action {
        case .dismiss:
            browserController.dismissManagement()
            return
        case let .setSearchProvider(provider):
            let model = KeelAppPresentationMapper.settingsModel(
                from: currentSettings,
                hasDiagnostics: false,
                homeScenes: homeSceneController?.tiles() ?? []
            )
            var replacement = model
            replacement.searchProvider = provider
            next = KeelAppPresentationMapper.settings(from: replacement, current: currentSettings)
        case let .setCustomSearchTemplate(template):
            var model = KeelAppPresentationMapper.settingsModel(
                from: currentSettings,
                hasDiagnostics: false,
                homeScenes: homeSceneController?.tiles() ?? []
            )
            model.searchProvider = .custom
            model.customSearchTemplate = template
            next = KeelAppPresentationMapper.settings(from: model, current: currentSettings)
        case let .setQueueExpiry(expiry):
            next.queueRetention = QueueRetention(rawValue: expiry.rawValue) ?? next.queueRetention
        case let .setKeepsClosedPageReady(keepsReady):
            next.keepsClosedPageReady = keepsReady
        case let .setAppearance(option):
            next.appearance = KeelAppPresentationMapper.appearanceMode(for: option)
        case let .setDefaultPageZoom(zoom):
            next.defaultPageZoom = PageZoomLevel(rawValue: zoom.rawValue) ?? next.defaultPageZoom
        case .chooseDownloadDirectory:
            chooseDownloadDirectory(current: currentSettings)
            return
        case .useDefaultDownloadDirectory:
            next.downloadDirectoryBookmark = nil
        case let .setHomeSceneMode(mode):
            next.homeSceneMode = KeelAppPresentationMapper.homeSceneMode(for: mode)
        case let .selectHomeScene(id):
            // Nil is the stored form of Como, so a default install keeps a
            // null selection rather than a string it would have to migrate.
            next.selectedHomeSceneID = id == .bundled("como") ? nil : id.storedValue
        case .addHomeScenes:
            presentHomeScenePanel()
            return
        case let .importHomeScenes(urls):
            importHomeScenes(urls)
            return
        case let .removeHomeScene(id):
            Task { @MainActor [weak self] in
                await self?.homeSceneController?.remove(id)
                self?.reloadVisibleManagementData()
            }
            return
        case .exportDiagnostics:
            browserController.exportDiagnostics()
            return
        case .deleteDiagnostics:
            browserController.handle(.deleteDiagnostics)
            return
        }

        browserController.handle(.replaceSettings(next))
        applyAppearance(next.appearance)
        browserController.defaultPageZoom = next.defaultPageZoom.scale
    }

    private func presentHomeScenePanel() {
        guard let window = windowController?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose"
        panel.message = "Choose photos for Home."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, !panel.urls.isEmpty else { return }
            self.importHomeScenes(panel.urls)
        }
    }

    private func importHomeScenes(_ urls: [URL]) {
        guard let homeSceneController else { return }
        Task { @MainActor [weak self] in
            let outcome = await homeSceneController.importScenes(urls)
            guard let self else { return }
            self.reloadVisibleManagementData()
            guard !outcome.failures.isEmpty else { return }
            self.errorPresenter.present(
                message: outcome.failures.count == 1
                    ? "Keel could not use that photo"
                    : "Keel could not use those photos",
                informativeText: outcome.failures.joined(separator: "\n"),
                in: self.windowController?.window
            )
        }
    }

    /// The sandbox only grants access to a directory the user picked in a panel,
    /// and only through the bookmark that panel produces. A stored path would
    /// resolve but fail to write.
    private func chooseDownloadDirectory(current: KeelSettings) {
        guard let window = windowController?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Keel saves downloaded files."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let directory = panel.url else { return }
            do {
                var next = current
                next.downloadDirectoryBookmark = try DownloadDirectoryBookmark.make(for: directory)
                self.browserController?.handle(.replaceSettings(next))
                self.refreshDownloadDirectory(next)
            } catch {
                self.errorPresenter.present(
                    message: "Keel could not use that folder",
                    informativeText: String(describing: error),
                    in: window
                )
            }
        }
    }

    /// Resolves the stored bookmark and hands the directory to the download
    /// manager, or falls back to the system Downloads folder.
    func refreshDownloadDirectory(_ settings: KeelSettings) {
        guard let bookmark = settings.downloadDirectoryBookmark else {
            resolvedDownloadDirectory = nil
            browserController?.setDownloadDestinationDirectory(nil)
            return
        }
        let resolved = try? DownloadDirectoryBookmark.withAccess(bookmark) { url, _ in url }
        resolvedDownloadDirectory = resolved
        browserController?.setDownloadDestinationDirectory(resolved)
    }

    func applyAppearance(_ mode: AppearanceMode) {
        guard let window = windowController?.window else { return }
        appearanceController.apply(mode, to: window)
    }

    func makeShellView() -> KeelShellView {
        KeelShellView()
    }

    /// Pinned to the shell's content guide, not its edges. Pinning to the edges
    /// under `.fullSizeContentView` is what drew the page under the toolbar.
    func makeBrowserContentView(in shellView: KeelShellView) -> NSView {
        let contentView = NSView()
        shellView.addSubview(contentView)
        shellView.pinToContentArea(contentView)
        return contentView
    }

    func installNativeScreenHost(in shellView: KeelShellView) {
        shellView.addSubview(nativeScreenHost)
        shellView.pinToContentArea(nativeScreenHost)
    }

    /// A real macOS menu bar. Keel previously shipped three menus with no File,
    /// no View, no Help, no About and no Hide, so half the system shortcuts a
    /// Mac user reaches for silently did nothing.
    func installBrowserMenu(using chromeController: KeelChromeController) {
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenuItem())
        mainMenu.addItem(fileMenuItem(using: chromeController))
        mainMenu.addItem(editMenuItem(using: chromeController))
        mainMenu.addItem(viewMenuItem(using: chromeController))
        mainMenu.addItem(historyMenuItem(using: chromeController))
        mainMenu.addItem(windowMenuItem(using: chromeController))
        let help = helpMenuItem()
        mainMenu.addItem(help)
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = mainMenu.item(withTitle: "Window")?.submenu
        NSApp.helpMenu = help.submenu
    }

    func applicationMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Keel")
        menu.addItem(
            menuItem(
                title: "About Keel",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                modifiers: []
            )
        )
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",", target: self))
        menu.addItem(.separator())

        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services

        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Hide Keel", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = menuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h",
            modifiers: [.command, .option]
        )
        menu.addItem(hideOthers)
        menu.addItem(menuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), modifiers: []))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit Keel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let rootItem = NSMenuItem(title: "Keel", action: nil, keyEquivalent: "")
        rootItem.submenu = menu
        return rootItem
    }

    func fileMenuItem(using chromeController: KeelChromeController) -> NSMenuItem {
        let menu = NSMenu(title: "File")
        menu.autoenablesItems = false
        // Cmd+T and Cmd+L both land here. The one-page model has no new tab, but
        // the gesture still means "give me somewhere to type".
        menu.addItem(chromeController.menuItem(for: .newAddress))
        menu.addItem(chromeController.menuItem(for: .showAddressPalette))
        menu.addItem(.separator())
        menu.addItem(chromeController.menuItem(for: .addCurrentURLToQueue))
        menu.addItem(chromeController.menuItem(for: .startQueue))
        menu.addItem(.separator())
        menu.addItem(chromeController.menuItem(for: .closePage))
        menu.addItem(chromeController.menuItem(for: .requeueAndClosePage))
        menu.addItem(chromeController.menuItem(for: .restoreCloseUndo))
        menu.addItem(.separator())
        menu.addItem(chromeController.menuItem(for: .copyCurrentURL))
        menu.addItem(chromeController.menuItem(for: .printPage))

        let rootItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        rootItem.submenu = menu
        return rootItem
    }

    func editMenuItem(using chromeController: KeelChromeController) -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        menu.addItem(menuItem(title: "Undo", action: #selector(KeelApplicationDelegate.sendUndo(_:)), keyEquivalent: "z", target: self))
        menu.addItem(menuItem(title: "Redo", action: #selector(KeelApplicationDelegate.sendRedo(_:)), keyEquivalent: "z", modifiers: [.command, .shift], target: self))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Cut", action: #selector(KeelApplicationDelegate.sendCut(_:)), keyEquivalent: "x", target: self))
        menu.addItem(menuItem(title: "Copy", action: #selector(KeelApplicationDelegate.sendCopy(_:)), keyEquivalent: "c", target: self))
        menu.addItem(menuItem(title: "Paste", action: #selector(KeelApplicationDelegate.sendPaste(_:)), keyEquivalent: "v", target: self))
        menu.addItem(menuItem(title: "Select All", action: #selector(KeelApplicationDelegate.sendSelectAll(_:)), keyEquivalent: "a", target: self))
        menu.addItem(.separator())
        menu.addItem(chromeController.menuItem(for: .findInPage))
        menu.addItem(chromeController.menuItem(for: .findNext))
        menu.addItem(chromeController.menuItem(for: .findPrevious))

        let rootItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        rootItem.submenu = menu
        return rootItem
    }

    func viewMenuItem(using chromeController: KeelChromeController) -> NSMenuItem {
        let menu = NSMenu(title: "View")
        menu.autoenablesItems = false
        menu.addItem(chromeController.menuItem(for: .reload))
        menu.addItem(chromeController.menuItem(for: .reloadFromOrigin))
        menu.addItem(.separator())
        menu.addItem(chromeController.menuItem(for: .zoomIn))
        menu.addItem(chromeController.menuItem(for: .zoomOut))
        menu.addItem(chromeController.menuItem(for: .resetZoom))
        menu.addItem(.separator())
        menu.addItem(chromeController.menuItem(for: .toggleChrome))
        menu.addItem(
            menuItem(
                title: "Enter Full Screen",
                action: #selector(NSWindow.toggleFullScreen(_:)),
                keyEquivalent: "f",
                modifiers: [.command, .control]
            )
        )

        let rootItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        rootItem.submenu = menu
        return rootItem
    }

    func historyMenuItem(using chromeController: KeelChromeController) -> NSMenuItem {
        let menu = NSMenu(title: "History")
        menu.autoenablesItems = false
        menu.addItem(chromeController.menuItem(for: .back))
        menu.addItem(chromeController.menuItem(for: .forward))
        menu.addItem(.separator())
        menu.addItem(chromeController.menuItem(for: .showHome))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Show All History", action: #selector(showHistory(_:)), keyEquivalent: "y", target: self))

        let rootItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        rootItem.submenu = menu
        return rootItem
    }

    /// Keel has no help book, so Help offers the one thing a dogfood build can
    /// answer honestly: what the keys do. The list is generated from the
    /// commands, so it cannot drift from the menus.
    func helpMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Help")
        menu.addItem(
            menuItem(
                title: "Keyboard Shortcuts",
                action: #selector(showKeyboardShortcuts(_:)),
                keyEquivalent: "/",
                target: self
            )
        )
        let rootItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        rootItem.submenu = menu
        return rootItem
    }

    @objc
    func showKeyboardShortcuts(_ sender: Any?) {
        shortcutsWindow.toggle(relativeTo: windowController?.window)
    }

    func windowMenuItem(using chromeController: KeelChromeController) -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(menuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        menu.addItem(menuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), modifiers: []))
        menu.addItem(.separator())
        menu.addItem(chromeController.menuItem(for: .showSoleWindow))
        menu.addItem(
            menuItem(
                title: "Downloads",
                action: #selector(showDownloads(_:)),
                keyEquivalent: "l",
                modifiers: [.command, .option],
                target: self
            )
        )

        let rootItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        rootItem.submenu = menu
        return rootItem
    }

    private func showManagement(_ screen: KeelManagementScreen) {
        guard KeelManagementCommandPolicy.allows(
            modalWindowIsPresented: NSApp.modalWindow != nil,
            attachedSheetIsPresented: windowController?.window?.attachedSheet != nil
        ) else {
            return
        }
        browserController?.showManagement(screen)
    }

    @objc
    private func showHistory(_ sender: Any?) {
        showManagement(.history)
    }

    @objc
    private func showDownloads(_ sender: Any?) {
        showManagement(.downloads)
    }

    @objc
    private func showSettings(_ sender: Any?) {
        showManagement(.settings)
    }

    func installChromeCallbacks(_ chromeController: KeelChromeController) {
        chromeController.onCommand = { [weak self] command in
            self?.performChromeCommand(command)
        }
    }

    func installPaletteCallbacks() {
        addressPalette.onQueryChanged = { [weak self] query, generation in
            self?.addressSuggestionPresenter?.queryDidChange(query, generation: generation)
        }
        addressPalette.onSubmit = { [weak self] submission in
            self?.submitAddressPalette(submission)
        }
        addressPalette.onDismiss = { [weak self] in
            self?.addressSuggestionPresenter?.cancelPendingWork()
            self?.browserController?.focusVisiblePage()
            self?.refreshChromeState()
        }
        addressPalette.onEmbeddedChange = { [weak self] in
            guard let self else { return }
            embeddedPaletteState.isActive = addressPalette.isEmbeddedActive
            embeddedPaletteState.rowsHeight = addressPalette.embeddedRowsHeight
        }
        // A click into Home's capsule takes the same road as Cmd+L.
        addressPalette.onEmbeddedFieldFocused = { [weak self] in
            self?.presentAddressPalette()
        }
        addressSuggestionPresenter?.onSuggestions = { [weak self] suggestions, generation, defaultSelection in
            self?.addressPalette.setSuggestions(
                suggestions,
                forQueryGeneration: generation,
                defaultSelection: defaultSelection
            )
        }
        addressSuggestionPresenter?.onFavicon = { [weak self] id, image, generation, duration in
            self?.addressPalette.replaceSuggestionIcon(
                id: id,
                image: image,
                forQueryGeneration: generation,
                duration: duration
            )
        }
        addressSuggestionPresenter?.onSuggestionAccepted = { [weak self] event in
            self?.browserController?.handle(event)
        }
    }

    func installFindCallbacks() {
        findController.onQueryChanged = { [weak self] query, backwards in
            self?.browserController?.find(query: query, backwards: backwards) { found in
                self?.findController.setMatchFound(found)
            }
        }
        findController.onDismiss = { [weak self] in
            self?.browserController?.focusVisiblePage()
            self?.refreshChromeState()
        }
    }

    func installBrowserCallbacks(
        _ browserController: KeelBrowserController,
        chromeController: KeelChromeController
    ) {
        browserController.onDownloadFileUnavailable = { [weak self] in
            guard let self, presentsWindows else { return }
            errorPresenter.present(
                message: "Keel could not access this download",
                informativeText: "The file may have been moved or deleted, or Keel may no longer have access to its folder. Check the download location in Finder, or download the file again.",
                in: windowController?.window
            )
        }
        browserController.onStartupPersistenceFailure = { [weak self, weak browserController] error in
            guard let self, presentsWindows else { return }
            recoveryController.showStartupFailure(error: error) { [weak browserController] in
                browserController?.start()
            }
        }
        browserController.onTransitionPersistenceFailure = { [weak self] _ in
            self?.onTransitionFailureForTesting?()
            guard let self, presentsWindows, !didExplainTransitionFailure else { return }
            didExplainTransitionFailure = true
            errorPresenter.present(message: "Keel could not save that change",
                informativeText: "Your previous page and queue are unchanged. Try the action again after resolving the storage problem.",
                in: windowController?.window)
        }
        browserController.onHistoryPersistenceFailure = { [weak self] _ in
            guard let self, presentsWindows, !didExplainHistoryFailure, let window = windowController?.window else { return }
            didExplainHistoryFailure = true
            let alert = NSAlert()
            alert.messageText = "History could not be saved"
            alert.informativeText = "You can keep browsing, but some visits may be missing from History. Keel will try to save future visits. Export diagnostics from Settings for more information."
            alert.addButton(withTitle: "Keep browsing")
            alert.addButton(withTitle: "Export diagnostics")
            alert.beginSheetModal(for: window) { [weak browserController] response in
                if response == .alertSecondButtonReturn { browserController?.exportDiagnostics() }
            }
        }
        browserController.onStateChanged = { [weak self] state in
            guard let self else { return }
            let surfaceChanged = coordinatorState?.surface != state.surface
            recoveryController.close()
            didExplainTransitionFailure = false
            coordinatorState = state
            interactionReceipt.updateSurface(isHome: state.surface == .home)
            updateNativeScreens(for: state)
            refreshChromeState()
            refreshDestinationTitles()
            onStateForTesting?(state)
            if presentsWindows, state.surface == .home, !didAttemptFirstLaunchExplanation {
                didAttemptFirstLaunchExplanation = true
                presentFirstLaunchExplanation()
            }
            // Closing a page publishes no new presentation, so the toolbar
            // kept the closed page's address over Home. The surface decides
            // what the bar shows; re-apply whenever it moves.
            if surfaceChanged, let lastPagePresentation {
                applyPagePresentation(lastPagePresentation)
            }
        }
        browserController.onCaptureReceipt = { [weak self] url, added in
            self?.interactionReceipt.capture(url: url, added: added)
        }
        browserController.onFinishReceipt = { [weak self] nextURL in
            self?.interactionReceipt.finish(nextURL: nextURL)
        }
        browserController.onPagePresentationChanged = { [weak self] presentation in
            self?.lastPagePresentation = presentation
            self?.applyPagePresentation(presentation)
        }
        browserController.onNavigationAvailabilityChanged = { availability in
            chromeController.updatePageAvailability(hasActivePage: availability.hasVisiblePage)
            chromeController.updateNavigationAvailability(
                canGoBack: availability.canGoBack,
                canGoForward: availability.canGoForward
            )
        }
        browserController.onDownloadSnapshotsChanged = { [weak self] snapshots in
            self?.liveDownloadSnapshots = snapshots
            self?.downloadShelf.setItems(snapshots.map(KeelDownloadShelfItem.init))
            self?.updateVisibleDownloads()
        }
        browserController.onManagementRequested = { _ in
            // The matching committed state arrives immediately after this callback.
            // Rendering waits for that state so management never shows stale Home/page
            // ownership while WebKit is being detached.
        }
        browserController.onManagementDataRefreshRequested = { [weak self] in
            self?.reloadVisibleManagementData()
        }
        browserController.onDiagnosticsExportRequested = { [weak self] data in
            self?.presentDiagnosticsExport(data)
        }
        browserController.onRevealSoleWindow = { [weak self] in
            self?.windowController?.showSoleWindow()
        }
        browserController.onExternalApplicationApproval = { [weak self] approval, completion in
            guard let handoffController = self?.externalApplicationHandoffController else {
                completion(false)
                return
            }
            handoffController.request(approval, completion: completion)
        }
    }

    func installDownloadShelf() {
        guard let shellView else {
            return
        }
        downloadShelf.attach(to: shellView, contentGuide: shellView.contentGuide)
        downloadShelf.onCancel = { [weak self] id in
            self?.browserController?.cancelDownload(id: id)
            self?.refreshDownloadShelf()
        }
        downloadShelf.onDismiss = { [weak self] id in
            self?.browserController?.dismissDownload(id: id)
            self?.refreshDownloadShelf()
        }
        downloadShelf.onOpen = { [weak self] id in
            self?.browserController?.openDownload(id: id)
        }
        downloadShelf.onRevealInFinder = { [weak self] id in
            self?.browserController?.revealDownload(id: id)
        }
    }

    func performChromeCommand(_ command: KeelChromeCommand) {
        guard let browserController else {
            return
        }
        guard KeelDetourCommandPolicy.allows(command, whileDetourIsActive: coordinatorState?.detour != nil) else {
            return
        }

        switch command {
        case .back:
            browserController.goBack()
        case .forward:
            browserController.goForward()
        case .reload:
            browserController.reload()
        case .reloadFromOrigin:
            browserController.reloadFromOrigin()
        case .showAddressPalette, .newAddress:
            presentAddressPalette()
        case .copyCurrentURL:
            _ = browserController.copyActiveURL()
        case .showHome:
            if coordinatorState?.surface == .home, coordinatorState?.activePage != nil {
                browserController.returnToActivePage()
            } else {
                browserController.showHome()
            }
        case .closePage:
            // Cmd+W was a dead key on Home, because Close Page was disabled and
            // nothing else claimed it. It now falls back to hiding the window.
            if case .management = coordinatorState?.surface {
                // Closing Settings, History or Downloads means "I am done
                // here", not "put the window away".
                browserController.dismissManagement()
            } else if coordinatorState?.activePage == nil {
                windowController?.hideSoleWindow()
            } else {
                browserController.closeActivePage()
            }
        case .requeueAndClosePage:
            browserController.requeueAndCloseActivePage()
        case .restoreCloseUndo:
            browserController.handle(.restoreCloseUndo)
        case .addCurrentURLToQueue:
            if let url = browserController.activeURL ?? coordinatorState?.activePage?.url {
                browserController.handle(.addURLToQueue(url))
            }
        case .startQueue:
            browserController.handle(.openNextQueuedDestination)
        case .findInPage:
            presentFind()
        case .findNext:
            if findController.isPresented {
                findController.findNext()
            } else {
                presentFind()
            }
        case .findPrevious:
            if findController.isPresented {
                findController.findPrevious()
            } else {
                presentFind()
            }
        case .printPage:
            browserController.printPage()
        case .zoomIn:
            _ = browserController.increasePageZoom()
        case .zoomOut:
            _ = browserController.decreasePageZoom()
        case .resetZoom:
            _ = browserController.resetPageZoom()
        case .showSoleWindow:
            windowController?.showSoleWindow()
            browserController.handle(.recoverSoleWindow)
        case .toggleChrome:
            toggleChrome()
        }
        refreshChromeState()
        refreshDownloadShelf()
    }

    func presentAddressPalette() {
        guard let shellView else {
            return
        }
        guard KeelDetourCommandPolicy.allows(.showAddressPalette, whileDetourIsActive: coordinatorState?.detour != nil) else {
            return
        }
        findController.dismiss(notify: false)
        windowController?.showSoleWindow()
        // On Home the palette's field already sits in the layout as the
        // capsule, so it activates in place. A parked page's address is not
        // pre-filled there: the capsule is for going somewhere new.
        if nativeScreenHost.screen == .home, addressPalette.isEmbedded {
            addressPalette.activateEmbedded(initialQuery: "", mode: addressPaletteMode)
            return
        }
        let activeAddress = browserController?.activeURL?.absoluteString
            ?? coordinatorState?.activePage?.url.absoluteString
            ?? ""
        addressPalette.present(
            over: shellView,
            initialQuery: activeAddress,
            mode: addressPaletteMode,
            contentGuide: shellView.contentGuide
        )
    }

    /// Return opens the destination. Command-Return explicitly queues it.
    var addressPaletteMode: KeelAddressPaletteMode {
        .opensNow
    }

    func presentFind() {
        guard let shellView else {
            return
        }
        guard KeelDetourCommandPolicy.allows(.findInPage, whileDetourIsActive: coordinatorState?.detour != nil) else {
            return
        }
        dismissAddressPaletteForTransition()
        findController.present(over: shellView, contentGuide: shellView.contentGuide)
    }

    func dismissAddressPaletteForTransition() {
        addressSuggestionPresenter?.cancelPendingWork()
        addressPalette.dismiss(notify: false)
    }

    func submitAddressPalette(
        _ submission: KeelAddressPaletteSubmission,
        detourIsActiveOverride: Bool? = nil
    ) {
        let detourIsActive = detourIsActiveOverride ?? (coordinatorState?.detour != nil)
        switch submission {
        case let .open(query):
            guard !detourIsActive, addressSubmissionIsAllowed else { return }
            resolveAndOpen(query)
        case let .enqueue(query):
            guard !detourIsActive, addressSubmissionIsAllowed else { return }
            resolveAndEnqueue(query)
        case let .openSuggestion(suggestion, input):
            submitHistorySuggestion(
                suggestion,
                input: input,
                disposition: .open,
                detourIsActiveOverride: detourIsActive
            )
        case let .enqueueSuggestion(suggestion, input):
            submitHistorySuggestion(
                suggestion,
                input: input,
                disposition: .enqueue,
                detourIsActiveOverride: detourIsActive
            )
        }
    }

    func submitHistorySuggestion(
        _ suggestion: KeelAddressPaletteSuggestion,
        input: String,
        disposition: KeelHistorySuggestionDisposition,
        detourIsActiveOverride: Bool? = nil
    ) {
        switch KeelAddressSuggestionSubmissionPolicy.action(
            detourIsActive: detourIsActiveOverride ?? (coordinatorState?.detour != nil),
            addressSubmissionIsAllowed: addressSubmissionIsAllowed
        ) {
        case .blocked:
            return
        case .sendAndKeepPalette:
            addressSuggestionPresenter?.accept(suggestion, input: input, disposition: disposition)
        case .sendAndDismissPalette:
            addressSuggestionPresenter?.accept(suggestion, input: input, disposition: disposition)
            addressPalette.dismiss()
        }
    }

    func resolveAndOpen(_ input: String) {
        guard let store else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self,
                  let state = try? await store.runtimeState(),
                  let resolution = KeelAddressResolver.resolve(input, searchProvider: state.settings.searchProvider)
            else {
                return
            }
            guard self.addressSubmissionIsAllowed else {
                return
            }
            switch resolution {
            case let .navigation(url), let .search(url):
                guard self.addressSubmissionIsAllowed else {
                    return
                }
                self.browserController?.openTypedURL(url)
            }
            guard self.addressSubmissionIsAllowed else {
                return
            }
            self.addressPalette.dismiss()
            self.refreshChromeState()
        }
    }

    func resolveAndEnqueue(_ input: String) {
        guard let store else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self,
                  let state = try? await store.runtimeState(),
                  let resolution = KeelAddressResolver.resolve(input, searchProvider: state.settings.searchProvider)
            else {
                return
            }
            guard self.addressSubmissionIsAllowed else {
                return
            }
            switch resolution {
            case let .navigation(url), let .search(url):
                guard self.addressSubmissionIsAllowed else {
                    return
                }
                self.browserController?.handle(.addURLToQueue(url))
            }
            guard self.addressSubmissionIsAllowed else {
                return
            }
            self.addressPalette.dismiss()
        }
    }

    func toggleChrome() {
        guard let windowController else {
            return
        }
        let nextIsVisible = !(windowController.window?.toolbar?.isVisible ?? true)
        windowController.setChromeVisible(nextIsVisible)
    }

    func refreshChromeState() {
        guard let chromeController = windowController?.chromeController else {
            return
        }
        let hasActivePage = browserController?.activeURL != nil || coordinatorState?.activePage != nil
        chromeController.updatePageAvailability(hasActivePage: hasActivePage)

        let runtime = coordinatorState?.runtimeState
        let isShowingHome = coordinatorState?.surface == .home
        chromeController.updateSurface(
            isShowingHome: isShowingHome,
            queueCount: runtime?.queue.count ?? 0,
            canStartQueue: isShowingHome
                && coordinatorState?.activePage == nil
                && runtime?.resumeCheckpoint == nil
                && !(runtime?.queue.isEmpty ?? true)
        )
        chromeController.applyCommandPolicy { [weak self] command in
            KeelDetourCommandPolicy.allows(
                command,
                whileDetourIsActive: self?.coordinatorState?.detour != nil
            )
        }
        if addressPalette.isPresented {
            addressPalette.setMode(addressPaletteMode)
        }
    }

    /// Feeds the address bar and the window title. Nothing published this before,
    /// which is why the toolbar could not show a URL, a title or progress.
    func applyPagePresentation(_ presentation: KeelPagePresentation) {
        guard let chromeController = windowController?.chromeController else { return }
        let showsPage = coordinatorState?.surface == .page
        // The address stays visible through a failure so Cmd+L prefills the
        // address that failed and a typo can be corrected in place.
        chromeController.updateAddress(
            url: showsPage ? presentation.url : nil,
            title: presentation.isShowingFailure ? nil : presentation.title,
            isSecure: presentation.isSecure
        )
        chromeController.updateLoadingProgress(
            showsPage && !presentation.isShowingFailure ? presentation.loadingProgress : nil
        )
        chromeController.updateAddressFavicon(
            showsPage && !presentation.isShowingFailure
                ? nativeScreenFavicons?.icon(for: presentation.url)?.image
                : nil
        )
        windowController?.updateWindowTitle(showsPage ? (presentation.title ?? presentation.url?.host) : nil)
    }

    var addressSubmissionIsAllowed: Bool {
        KeelDetourCommandPolicy.allows(
            .showAddressPalette,
            whileDetourIsActive: coordinatorState?.detour != nil
        )
    }

    func refreshDownloadShelf() {
        let items = browserController?.downloads.map(KeelDownloadShelfItem.init) ?? []
        downloadShelf.setItems(items)
    }

    func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53,
                  let self,
                  !self.addressPalette.isPresented,
                  !self.findController.isPresented,
                  self.browserController?.dismissTransientForEscape() == true
            else {
                return event
            }
            return nil
        }
    }

    func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }





    func menuItem(
        title: String,
        action: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = .command,
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }
}

private extension KeelDownloadShelfItem {
    init(snapshot: KeelDownloadSnapshot) {
        let state: KeelDownloadShelfState = switch snapshot.state {
        case .inProgress:
            if let expectedBytes = snapshot.expectedBytes, expectedBytes > 0 {
                .receiving(progress: Double(snapshot.receivedBytes) / Double(expectedBytes))
            } else {
                .waiting
            }
        case .completed:
            .completed
        case .cancelled:
            .cancelled
        case let .failed(errorCode):
            .failed(message: errorCode.map(String.init) ?? "Unknown error")
        }
        // The shelf card shows rate and time remaining beside the percentage,
        // so a stalled transfer is distinguishable from a slow one.
        self.init(
            id: snapshot.id,
            filename: snapshot.filename,
            state: state,
            detail: KeelAppPresentationMapper.transferDetail(for: snapshot)
        )
    }
}
