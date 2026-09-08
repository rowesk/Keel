import AppKit
import Darwin
import Foundation
import KeelFoundation
import KeelStore
import KeelUI
import ImageIO
import WebKit

/// Runs the real Home wiring offscreen with disposable data. It never measures
/// keyboard usability or claims to include WebKit child-process memory.
@MainActor
enum KeelPerformanceProbe {
    static func run(startedAt: ContinuousClock.Instant) async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "keel-performance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let paths = KeelPaths(applicationSupportDirectory: directory)
            let store = try KeelStore(paths: paths)
            let imported = ProcessInfo.processInfo.environment["KEEL_PERFORMANCE_SCENE"] == "imported"
            if imported { try await seedImportedScene(store: store, paths: paths) }
            let expectedScene = try await store.runtimeState().settings.selectedHomeSceneID ?? "bundled:como"
            let fixtureReadyMilliseconds = milliseconds(since: startedAt)
            let delegate = KeelApplicationDelegate(makeStore: { store })
            var homeReady = false
            delegate.onStateForTesting = { state in
                if state.surface == .home { homeReady = true }
            }
            try delegate.configureProductionApp(presentsWindow: false, isolatedScenePaths: paths)
            let configuredMilliseconds = milliseconds(since: startedAt)
            try await waitUntil { homeReady }
            let stateReadyMilliseconds = milliseconds(since: startedAt)
            try await waitUntil { delegate.storedPreferencesApplied && delegate.homeSceneController?.currentDisplay.image != nil }
            guard delegate.homeSceneController?.currentSceneID?.storedValue == expectedScene else { throw ProbeError.wrongScene }
            let preferencesReadyMilliseconds = milliseconds(since: startedAt)
            let windows = NSApplication.shared.windows
            guard windows.allSatisfy({ !$0.isVisible }) else { throw ProbeError.visibleWindow }
            for window in windows {
                window.layoutIfNeeded()
                if let view = window.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                }
            }
            let renderMilliseconds = milliseconds(since: startedAt)
            let webViewCount = windows.reduce(0) { $0 + countWebViews(in: $1.contentView) }
            guard webViewCount == 0 else { throw ProbeError.homeCreatedWebView }
            emit([
                "event": "home-rendered",
                "millisecondsFromMain": renderMilliseconds,
                "homeWebViewCount": webViewCount,
                "visibleWindowCount": windows.filter(\.isVisible).count,
                "fixtureReadyMillisecondsFromMain": fixtureReadyMilliseconds,
                "configuredMillisecondsFromMain": configuredMilliseconds,
                "stateReadyMillisecondsFromMain": stateReadyMilliseconds,
                "preferencesAndSceneReadyMillisecondsFromMain": preferencesReadyMilliseconds,
                "sceneScenario": imported ? "synthetic-imported" : "bundled-como",
            ])

            // Let image decoding and initial layout finish before measuring idle.
            try await Task.sleep(for: .seconds(2))
            let requestedSeconds = Double(ProcessInfo.processInfo.environment["KEEL_PERFORMANCE_IDLE_SECONDS"] ?? "60") ?? 60
            let seconds = min(60, max(1, requestedSeconds))
            let cpuBefore = cpuSeconds()
            let idleStart = ContinuousClock.now
            try await Task.sleep(for: .seconds(seconds))
            let elapsedSeconds = milliseconds(since: idleStart) / 1_000
            let idleCPU = (cpuSeconds() - cpuBefore) / elapsedSeconds * 100
            let homePeakResidentBytes = peakResidentBytes()

            var navigationStarted = false
            delegate.onStateForTesting = { state in
                if state.surface == .page { navigationStarted = true }
            }
            let navigationStart = ContinuousClock.now
            // A local refused connection needs neither network access nor a server.
            let baseURL = ProcessInfo.processInfo.environment["KEEL_PERFORMANCE_URL"] ?? "http://127.0.0.1:9/keel-performance"
            guard let target = URL(string: baseURL), target.host == "127.0.0.1", target.scheme == "http" else {
                throw ProbeError.nonLocalURL
            }
            delegate.submitAddressPalette(.open(query: baseURL))
            try await waitUntil { navigationStarted }
            let navigationMilliseconds = milliseconds(since: navigationStart)
            try await waitUntil { visibleWebViews().contains { $0.url?.host == "127.0.0.1" && !$0.isLoading } }
            let pagePeakResidentBytes = peakResidentBytes()
            let cycleStart = ContinuousClock.now
            let requestedCycles = Int(ProcessInfo.processInfo.environment["KEEL_PERFORMANCE_CYCLES"] ?? "20") ?? 20
            let cycles = min(100, max(1, requestedCycles))
            for index in 0..<cycles {
                guard let pageID = delegate.coordinatorState?.activePage?.id else { throw ProbeError.missingPage }
                delegate.handlePerformanceEvent(.closePage(pageID: pageID))
                try await waitUntil { delegate.coordinatorState?.activePage == nil }
                delegate.handlePerformanceEvent(.restoreCloseUndo)
                try await waitUntil { delegate.coordinatorState?.activePage?.id == pageID }
                delegate.submitAddressPalette(.open(query: baseURL + "?cycle=\(index)"))
                try await waitUntil { visibleWebViews().contains { $0.url?.query == "cycle=\(index)" && !$0.isLoading } }
            }
            guard NSApplication.shared.windows.allSatisfy({ !$0.isVisible }) else { throw ProbeError.visibleWindow }
            emit([
                "event": "complete",
                "scope": "offscreen app wiring; process memory excludes WebKit children; navigation excludes response",
                "sceneScenario": imported ? "synthetic-imported" : "bundled-como",
                "fixturePreparationMilliseconds": fixtureReadyMilliseconds,
                "homeRenderMillisecondsFromMain": renderMilliseconds,
                "navigationDispatchMilliseconds": navigationMilliseconds,
                "idleSampleSeconds": elapsedSeconds,
                "idleCPUPercent": idleCPU,
                "homeMainProcessPeakResidentBytes": homePeakResidentBytes,
                "mainProcessPeakResidentBytesAfterNavigation": peakResidentBytes(),
                "mainProcessPeakResidentBytesFirstPage": pagePeakResidentBytes,
                "completedCloseUndoNavigationCycles": cycles,
                "cycleWorkloadMilliseconds": milliseconds(since: cycleStart),
                "homeWebViewCount": webViewCount,
                "visibleWindowCount": 0,
            ])
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            withExtendedLifetime(delegate) {}
        } catch {
            emit(["event": "failed", "error": String(describing: error)])
        }
    }

    private static func visibleWebViews() -> [WKWebView] {
        func descend(_ view: NSView) -> [WKWebView] {
            (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(descend)
        }
        return NSApplication.shared.windows.compactMap(\.contentView).flatMap(descend)
    }

    /// A generated image keeps private photo libraries out of the probe.
    private static func seedImportedScene(store: KeelStore, paths: KeelPaths) async throws {
        let scene = UserHomeScene(fileName: "probe.png", displayName: "Probe", topLuminance: 0.4, bottomLuminance: 0.4, addedAt: .now)
        try FileManager.default.createDirectory(at: paths.homeScenesDirectory, withIntermediateDirectories: true)
        guard let context = CGContext(data: nil, width: 2400, height: 1600, bitsPerComponent: 8,
                                      bytesPerRow: 2400 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ProbeError.fixture }
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
        guard let image = context.makeImage(),
              let writer = CGImageDestinationCreateWithURL(paths.homeScenesDirectory.appending(path: scene.fileName) as CFURL,
                                                           "public.png" as CFString, 1, nil) else { throw ProbeError.fixture }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw ProbeError.fixture }
        try await store.insertUserHomeScene(scene)
        _ = try await store.apply([.replaceSettings(KeelSettings(appearance: .dark,
            selectedHomeSceneID: "user:\(scene.id.uuidString.lowercased())"))])
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let start = ContinuousClock.now
        while !condition() {
            guard milliseconds(since: start) < 10_000 else { throw ProbeError.timeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func peakResidentBytes() -> Int {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Int(usage.ru_maxrss)
    }

    private static func countWebViews(in view: NSView?) -> Int {
        guard let view else { return 0 }
        return (view is WKWebView ? 1 : 0) + view.subviews.reduce(0) { $0 + countWebViews(in: $1) }
    }

    private static func emit(_ values: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              var text = String(data: data, encoding: .utf8) else { return }
        text += "\n"
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private enum ProbeError: Error {
        case timeout
        case visibleWindow
        case homeCreatedWebView
        case nonLocalURL
        case missingPage
        case fixture
        case wrongScene
    }
}
