import AppKit
import Foundation
import ImageIO
import KeelFoundation
import KeelStore
import KeelUI

/// Owns the photograph behind Home: the library, the rotation, and the decoded
/// pixels.
///
/// The controller is the only place that knows a scene id can name either a
/// bundled resource or a file in the container, so Home and Settings both get
/// plain values and never touch the disk.
@MainActor
final class KeelHomeSceneController {
    /// The result of one import, so the caller can word a single alert rather
    /// than one per file.
    struct ImportOutcome: Equatable {
        var imported: Int = 0
        var failures: [String] = []
    }

    typealias PersistSettings = @MainActor (KeelSettings) -> Void

    private let decodeImage: @Sendable (URL, Int) -> KeelHomeSceneDecoder.Decoded?
    private let store: KeelStore
    private let paths: KeelPaths
    private let persistSettings: PersistSettings
    private let window: @MainActor () -> NSWindow?

    /// What Home draws now. Home re-renders through `onDisplayChange`.
    private(set) var currentDisplay: KeelHomeSceneDisplay = .como
    var onDisplayChange: (@MainActor () -> Void)?
    /// Fired when the library itself changed, so a visible Settings screen can
    /// pick up a new tile or a new thumbnail.
    var onLibraryChange: (@MainActor () -> Void)?

    private var settings = KeelSettings()
    private var userScenes: [UserHomeScene] = []
    /// The scene showing now. Tests read it; nothing outside sets it.
    private(set) var currentSceneID: KeelHomeSceneID?
    private var images: [KeelHomeSceneID: NSImage] = [:]
    private var thumbnails: [KeelHomeSceneID: NSImage] = [:]
    private var pendingThumbnails: Set<KeelHomeSceneID> = []
    private var displayGeneration = 0
    /// The candidate `prefetchNext` decoded, together with the state it was
    /// computed from. Arrival reuses it only when nothing moved underneath.
    private var prefetched: Prefetched?
    /// Launch renders Home before the store has answered. An arrival that
    /// lands then would shuffle a library of one, so it waits for the rows.
    private var libraryLoaded = false
    private var arrivalPending = false

    private struct Prefetched {
        var available: [String]
        var fromState: HomeSceneRotationState
        var current: String?
        var result: (id: String?, state: HomeSceneRotationState)
    }

    init(
        store: KeelStore,
        paths: KeelPaths,
        window: @escaping @MainActor () -> NSWindow? = { NSApp.mainWindow },
        persistSettings: @escaping PersistSettings,
        decodeImage: @escaping @Sendable (URL, Int) -> KeelHomeSceneDecoder.Decoded? = KeelHomeSceneDecoder.decode
    ) {
        self.decodeImage = decodeImage
        self.store = store
        self.paths = paths
        self.window = window
        self.persistSettings = persistSettings
    }

    // MARK: - Library

    /// Reads the imported scenes and drops any whose file went missing, which
    /// happens when a container is restored without its photographs.
    func loadLibrary() async {
        let rows = (try? await store.userHomeScenes()) ?? []
        var kept: [UserHomeScene] = []
        for row in rows {
            let url = paths.homeScenesDirectory.appending(path: row.fileName)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                kept.append(row)
            } else {
                try? await store.deleteUserHomeScene(id: row.id)
                noteMissingScene()
            }
        }
        userScenes = kept
        libraryLoaded = true
        // Preferences may arrive before imported rows. Replace that temporary
        // bundled fallback once the selected photo becomes available.
        if settings.homeSceneMode == .onePhoto, currentSceneID != selectedScene.id {
            show(scene: selectedScene)
        }
        // A dropped row may have been the selection or the scene on screen.
        if let currentSceneID, !library.contains(where: { $0.id == currentSceneID }) {
            show(scene: selectedScene)
        }
        onLibraryChange?()
        if arrivalPending {
            arrivalPending = false
            arriveAtHome()
        }
    }

    func settingsDidChange(_ newSettings: KeelSettings) {
        let previous = settings
        settings = newSettings
        guard previous.homeSceneMode != newSettings.homeSceneMode
            || previous.selectedHomeSceneID != newSettings.selectedHomeSceneID
        else { return }
        prefetched = nil
        // Changing the picture in one-photo mode should show it at once. A mode
        // that rotates waits for the next arrival, so Home does not flicker
        // while Settings is open.
        if newSettings.homeSceneMode == .onePhoto {
            show(scene: selectedScene)
        }
    }

    /// The whole library, bundled first, then imported in the order added.
    var library: [KeelHomeScene] {
        KeelBundledScenes.all.map(\.scene) + userScenes.map(Self.scene(for:))
    }

    var selectedSceneID: KeelHomeSceneID {
        settings.selectedHomeSceneID.flatMap(KeelHomeSceneID.init(storedValue:)) ?? .bundled("como")
    }

    private var selectedScene: KeelHomeScene {
        library.first { $0.id == selectedSceneID } ?? .como
    }

    /// Tiles for the settings grid. Thumbnails arrive asynchronously; the grid
    /// re-renders through `onLibraryChange` as each one lands.
    func tiles() -> [KeelHomeSceneTile] {
        library.map { scene in
            if thumbnails[scene.id] == nil { loadThumbnail(for: scene.id) }
            return KeelHomeSceneTile(
                id: scene.id,
                name: scene.name,
                isBundled: scene.id.isBundled,
                thumbnail: thumbnails[scene.id]
            )
        }
    }

    // MARK: - Arrival

    /// Called once each time Home comes into view. Rotation advances here and
    /// nowhere else, so sitting on Home never changes the photograph.
    func arriveAtHome() {
        guard settings.homeSceneMode != .onePhoto else {
            show(scene: selectedScene)
            return
        }
        guard libraryLoaded else {
            arrivalPending = true
            return
        }

        let available = rotationCandidates
        guard !available.isEmpty else {
            show(scene: .como)
            return
        }

        let state = settings.homeSceneRotation
        let current = currentSceneID?.storedValue
        let result: (id: String?, state: HomeSceneRotationState)
        if let prefetched,
           prefetched.available == available,
           prefetched.fromState == state,
           prefetched.current == current {
            result = prefetched.result
        } else {
            result = HomeSceneRotation.next(available: available, state: state, current: current)
        }
        prefetched = nil

        settings.homeSceneRotation = result.state
        persistSettings(settings)

        let id = result.id.flatMap(KeelHomeSceneID.init(storedValue:))
        show(scene: library.first { $0.id == id } ?? .como)
    }

    /// Decodes the scene the next arrival will show, while Home is off screen.
    /// The rotation state is left alone: `arriveAtHome` advances it, and it
    /// recomputes the same candidate from the same state.
    func prefetchNext() {
        guard settings.homeSceneMode != .onePhoto else { return }
        let available = rotationCandidates
        guard !available.isEmpty else { return }

        let state = settings.homeSceneRotation
        let current = currentSceneID?.storedValue
        let result = HomeSceneRotation.next(available: available, state: state, current: current)
        prefetched = Prefetched(available: available, fromState: state, current: current, result: result)

        guard let id = result.id.flatMap(KeelHomeSceneID.init(storedValue:)),
              images[id] == nil,
              let scene = library.first(where: { $0.id == id })
        else { return }
        loadImage(for: scene, generation: nil)
    }

    /// `rotateMine` with nothing imported would have nothing to show, so it
    /// falls back to the whole library.
    private var rotationCandidates: [String] {
        switch settings.homeSceneMode {
        case .onePhoto:
            []
        case .rotateMine:
            userScenes.isEmpty
                ? library.map(\.id.storedValue)
                : userScenes.map { KeelHomeSceneID.user($0.id).storedValue }
        case .rotateAll:
            library.map(\.id.storedValue)
        }
    }

    // MARK: - Import and removal

    func importScenes(_ urls: [URL]) async -> ImportOutcome {
        guard !urls.isEmpty else { return ImportOutcome() }
        let directory = paths.homeScenesDirectory
        let results = await Task.detached(priority: .userInitiated) { () -> [Result<KeelImportedScene, any Error>] in
            urls.map { url in
                // One bad file does not stop the rest of a multiple selection.
                Result { try KeelSceneImporter.importScene(from: url, into: directory) }
            }
        }.value

        var outcome = ImportOutcome()
        for (url, result) in zip(urls, results) {
            switch result {
            case let .success(imported):
                let row = UserHomeScene(
                    fileName: imported.fileName,
                    displayName: imported.displayName,
                    topLuminance: imported.topLuminance,
                    bottomLuminance: imported.bottomLuminance
                )
                do {
                    try await store.insertUserHomeScene(row)
                    outcome.imported += 1
                } catch {
                    try? FileManager.default.removeItem(at: directory.appending(path: imported.fileName))
                    outcome.failures.append(Self.failure(for: url, error: error))
                }
            case let .failure(error):
                outcome.failures.append(Self.failure(for: url, error: error))
            }
        }

        if outcome.imported > 0 {
            prefetched = nil
            await loadLibrary()
        }
        return outcome
    }

    /// Removes an imported scene. The row goes first: a row without its file is
    /// the state the loader already knows how to repair.
    func remove(_ id: KeelHomeSceneID) async {
        guard case let .user(uuid) = id, let row = userScenes.first(where: { $0.id == uuid }) else { return }
        try? await store.deleteUserHomeScene(id: uuid)
        try? FileManager.default.removeItem(at: paths.homeScenesDirectory.appending(path: row.fileName))
        images[id] = nil
        thumbnails[id] = nil
        prefetched = nil

        if selectedSceneID == id {
            settings.selectedHomeSceneID = nil
            persistSettings(settings)
        }
        await loadLibrary()
        if currentSceneID == id { show(scene: selectedScene) }
    }

    // MARK: - Display

    private func show(scene: KeelHomeScene) {
        currentSceneID = scene.id
        displayGeneration &+= 1
        publish(
            KeelHomeSceneDisplay(
                image: images[scene.id],
                topLuminance: scene.topLuminance,
                bottomLuminance: scene.bottomLuminance
            )
        )
        guard images[scene.id] == nil else { return }
        loadImage(for: scene, generation: displayGeneration)
    }

    private func publish(_ display: KeelHomeSceneDisplay) {
        guard currentDisplay != display else { return }
        currentDisplay = display
        onDisplayChange?()
    }

    /// Decodes at the window's backing pixel size. A `generation` means the
    /// result should be shown when it arrives; nil is a prefetch that only
    /// fills the cache.
    private func loadImage(for scene: KeelHomeScene, generation: Int?) {
        guard let url = fileURL(for: scene.id) else { return }
        let pixelWidth = backingPixelWidth
        let decodeImage = decodeImage
        Task { @MainActor [weak self] in
            // Requests can be superseded before their task starts. Do not launch
            // a costly decode for a discarded controller or an obsolete display.
            guard self != nil,
                  generation == nil || generation == self?.displayGeneration
            else { return }
            let decoded = await Task.detached(priority: generation == nil ? .utility : .userInitiated) {
                decodeImage(url, pixelWidth)
            }.value
            guard let self, let image = decoded?.image else { return }
            self.images[scene.id] = image
            guard let generation, generation == self.displayGeneration else { return }
            self.publish(
                KeelHomeSceneDisplay(
                    image: image,
                    topLuminance: scene.topLuminance,
                    bottomLuminance: scene.bottomLuminance
                )
            )
        }
    }

    private func loadThumbnail(for id: KeelHomeSceneID) {
        guard !pendingThumbnails.contains(id), let url = fileURL(for: id) else { return }
        pendingThumbnails.insert(id)
        Task { @MainActor [weak self] in
            guard self != nil else { return }
            let decoded = await Task.detached(priority: .utility) {
                KeelHomeSceneDecoder.decode(url: url, maximumPixelSize: Self.thumbnailPixelWidth)
            }.value
            guard let self else { return }
            self.pendingThumbnails.remove(id)
            guard let image = decoded?.image else { return }
            self.thumbnails[id] = image
            self.onLibraryChange?()
        }
    }

    private func fileURL(for id: KeelHomeSceneID) -> URL? {
        switch id {
        case let .bundled(name):
            KeelBundledScenes.url(for: name)
        case let .user(uuid):
            userScenes.first { $0.id == uuid }
                .map { paths.homeScenesDirectory.appending(path: $0.fileName) }
        }
    }

    private var backingPixelWidth: Int {
        guard let window = window(), window.frame.width > 0 else { return 2_560 }
        return max(1_280, Int((window.frame.width * window.backingScaleFactor).rounded()))
    }

    /// Roughly two of the widest tiles across, so a Retina grid stays sharp.
    nonisolated static let thumbnailPixelWidth = 320

    private static func scene(for row: UserHomeScene) -> KeelHomeScene {
        KeelHomeScene(
            id: .user(row.id),
            name: row.displayName,
            topLuminance: row.topLuminance,
            bottomLuminance: row.bottomLuminance
        )
    }

    private static func failure(for url: URL, error: any Error) -> String {
        let name = url.lastPathComponent
        if let importError = error as? KeelSceneImportError, let description = importError.errorDescription {
            return "\(name): \(description)"
        }
        return "\(name): \(String(describing: error))"
    }

    /// A photograph that vanished from the container is worth a line when
    /// diagnostics are on, and nothing at all when they are off.
    private func noteMissingScene() {
        guard let hostname = try? DiagnosticHostname("home-scene.keel") else { return }
        let record = DiagnosticRecord(
            timestamp: Date(),
            eventType: .processEvent,
            hostname: hostname,
            result: .failed
        )
        Task { [store] in
            _ = try? await store.apply([.recordDiagnostic(record)])
        }
    }
}

/// ImageIO decoding, off the main actor. NSImage is not `Sendable`, so the
/// decoded picture crosses back inside a box.
enum KeelHomeSceneDecoder {
    struct Decoded: @unchecked Sendable {
        let image: NSImage
    }

    static func decode(url: URL, maximumPixelSize: Int) -> Decoded? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
              ] as CFDictionary)
        else { return nil }
        return Decoded(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
    }
}

private extension KeelHomeSceneID {
    var isBundled: Bool {
        if case .bundled = self { return true }
        return false
    }
}
