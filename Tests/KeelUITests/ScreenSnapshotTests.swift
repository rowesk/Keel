import AppKit
import SwiftUI
import XCTest
@testable import KeelUI

/// Renders every Keel-owned screen and compares it to a committed baseline.
///
/// Wave 2 shipped a build nobody had looked at, and every visual defect in it
/// was invisible to a suite that only asserted behaviour. These tests fail when
/// pixels move, which is the only kind of test that would have caught them.
///
/// Re-record after an intended visual change:
///
///     KEEL_RECORD_SNAPSHOTS=1 swift test --filter ScreenSnapshotTests
///
/// A failure writes the rendered image and a difference mask next to the
/// baseline so the change can be looked at rather than guessed at.
@MainActor
final class ScreenSnapshotTests: XCTestCase {
    /// Fixed so relative times, countdowns and "just now" render the same every
    /// run. `keelFixedNow` freezes the clock the views read.
    private static let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    private var isRecording: Bool {
        ProcessInfo.processInfo.environment["KEEL_RECORD_SNAPSHOTS"] == "1"
    }

    // MARK: Screens

    func testHomeWithWorkWaiting() throws {
        try assertSnapshot(
            of: HomeView(model: Self.busyHomeModel()),
            named: "home-busy",
            size: NSSize(width: 1120, height: 860)
        )
    }

    func testHomeEmpty() throws {
        try assertSnapshot(
            of: HomeView(model: KeelHomeModel()),
            named: "home-empty",
            size: NSSize(width: 1120, height: 720)
        )
    }

    func testHistory() throws {
        try assertSnapshot(
            of: HistoryView(model: .fixture(sessionCount: 3, visitsPerSession: 4)),
            named: "history",
            size: NSSize(width: 900, height: 760)
        )
    }

    func testHistoryEmpty() throws {
        try assertSnapshot(
            of: HistoryView(model: KeelHistoryModel()),
            named: "history-empty",
            size: NSSize(width: 900, height: 500)
        )
    }

    func testDownloads() throws {
        try assertSnapshot(
            of: DownloadsView(model: KeelDownloadModel.fixture(count: 5)),
            named: "downloads",
            size: NSSize(width: 900, height: 620)
        )
    }

    func testSettings() throws {
        try assertSnapshot(
            of: SettingsView(model: KeelSettingsModel(searchProvider: .custom, hasDiagnostics: true)),
            named: "settings",
            size: NSSize(width: 900, height: 820)
        )
    }

    func testSettingsHomeScenesOnePhoto() throws {
        try assertSnapshot(
            of: SettingsView(model: Self.homeSceneSettingsModel(mode: .onePhoto)),
            named: "settings-home-scenes-one-photo",
            size: NSSize(width: 900, height: 1400)
        )
    }

    func testSettingsHomeScenesRotateMine() throws {
        try assertSnapshot(
            of: SettingsView(model: Self.homeSceneSettingsModel(mode: .rotateMine)),
            named: "settings-home-scenes-rotate-mine",
            size: NSSize(width: 900, height: 1400)
        )
    }

    func testHomeBrightMinimumExpanded() throws {
        let image = Self.solidImage(red: 0.98, green: 0.96, blue: 0.90)
        try assertSnapshot(
            of: HomeView(model: Self.busyHomeModel(),
                         scene: KeelHomeSceneDisplay(image: image, topLuminance: 0.95, bottomLuminance: 0.95),
                         queueInitiallyExpanded: true),
            named: "home-bright-minimum-expanded",
            size: NSSize(width: 720, height: 480)
        )
    }

    func testHomeQueueAndUndo() throws {
        let busy = Self.busyHomeModel()
        try assertSnapshot(
            of: HomeView(model: KeelHomeModel(undo: busy.undo, queue: busy.queue), queueInitiallyExpanded: true),
            named: "home-queue-undo-expanded",
            size: NSSize(width: 1120, height: 720)
        )
    }

    func testUnusualDownloads() throws {
        let states: [(String, KeelDownloadStatus, String?)] = [
            ("Unknown total.zip", .inProgress, nil),
            ("Missing file.pdf", .completed, nil),
            ("Cancelled archive.zip", .cancelled, nil),
            ("Failed transfer.pdf", .failed(message: "The connection was lost. Download the file again from the page."), nil),
        ]
        let items = states.enumerated().map { index, state in
            KeelDownloadItem(id: UUID(), hostname: "downloads.example.test", filename: state.0,
                             path: state.2, receivedBytes: 1024, status: state.1,
                             createdAt: Self.referenceDate.addingTimeInterval(Double(-index)))
        }
        try assertSnapshot(of: DownloadsView(model: KeelDownloadModel(items: items)),
                           named: "downloads-unusual", size: NSSize(width: 720, height: 480))
    }

    func testHomeDarkImportedWide() throws {
        try assertSnapshot(
            of: HomeView(scene: KeelHomeSceneDisplay(image: Self.solidImage(red: 0.04, green: 0.05, blue: 0.03),
                                                    topLuminance: 0.02, bottomLuminance: 0.02)),
            named: "home-dark-import-wide", size: NSSize(width: 1440, height: 600)
        )
    }

    /// Opt-in crop evidence without adding forty photographic baselines to Git.
    func testBundledSceneCropMatrix() throws {
        guard let directory = ProcessInfo.processInfo.environment["KEEL_SCENE_MATRIX_DIRECTORY"] else { return }
        let destination = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for scene in KeelBundledScenes.all {
            let url = try XCTUnwrap(KeelBundledScenes.url(for: scene.id))
            let image = try XCTUnwrap(NSImage(contentsOf: url))
            for size in [NSSize(width: 720, height: 480), NSSize(width: 1440, height: 600)] {
                for appearance in Appearance.allCases {
                    let view = HomeView(scene: KeelHomeSceneDisplay(image: image, topLuminance: scene.topLuminance,
                                                                  bottomLuminance: scene.bottomLuminance))
                    let rep = try render(view, size: size, appearance: appearance)
                    let name = "\(scene.id)-\(Int(size.width))-\(appearance.suffix).png"
                    try rep.pngData().write(to: destination.appendingPathComponent(name))
                }
            }
        }
    }

    /// Review-only edge cases. Export outside the checkout and inspect them;
    /// these are evidence images, not silently accepted baselines.
    func testLongTextEvidence() throws {
        guard let directory = ProcessInfo.processInfo.environment["KEEL_UI_MATRIX_DIRECTORY"] else { return }
        let destination = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let title = "An unusually long document title about an international project specification and its supporting materials"
        let queue = (0..<8).map { index in
            KeelQueueItem(id: UUID(), displayURL: "https://documents.example.test/a/long/path/to/project-specification",
                          hostname: "documents.example.test", title: title, capturedAt: Self.referenceDate,
                          sequence: Int64(index))
        }
        let item = KeelDownloadItem(id: UUID(), hostname: "downloads.example.test",
                                    filename: title + ".zip", receivedBytes: 12_000_000,
                                    expectedBytes: 100_000_000, status: .inProgress,
                                    createdAt: Self.referenceDate, bytesPerSecond: 2_000_000)
        for size in [NSSize(width: 720, height: 480), NSSize(width: 1440, height: 600)] {
            for appearance in Appearance.allCases {
                let home = HomeView(model: KeelHomeModel(queue: queue), queueInitiallyExpanded: true)
                let regular = try render(home, size: size, appearance: appearance)
                try regular.pngData().write(to: destination.appendingPathComponent("home-long-\(Int(size.width))-\(appearance.suffix).png"))
                let downloads = try render(DownloadsView(model: KeelDownloadModel(items: [item])), size: size, appearance: appearance)
                try downloads.pngData().write(to: destination.appendingPathComponent("downloads-long-progress-\(Int(size.width))-\(appearance.suffix).png"))
            }
        }
    }

    // MARK: Fixtures

    /// Fixed ids and flat-colour thumbnails so the grid renders identically
    /// every run without reading anything off disk.
    private static let lakeSceneID = KeelHomeSceneID.user(
        UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    )
    private static let harbourSceneID = KeelHomeSceneID.user(
        UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    )

    private static func homeSceneSettingsModel(mode: KeelHomeSceneMode) -> KeelSettingsModel {
        KeelSettingsModel(
            hasDiagnostics: true,
            homeSceneMode: mode,
            selectedHomeSceneID: lakeSceneID,
            homeScenes: [
                KeelHomeSceneTile(
                    id: .bundled("como"),
                    name: "Como",
                    isBundled: true,
                    thumbnail: solidImage(red: 0.35, green: 0.42, blue: 0.33)
                ),
                KeelHomeSceneTile(
                    id: lakeSceneID,
                    name: "Lake dusk",
                    isBundled: false,
                    thumbnail: solidImage(red: 0.24, green: 0.28, blue: 0.45)
                ),
                KeelHomeSceneTile(
                    id: harbourSceneID,
                    name: "Harbour morning",
                    isBundled: false,
                    thumbnail: solidImage(red: 0.62, green: 0.48, blue: 0.32)
                ),
            ]
        )
    }

    private static func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> NSImage {
        let size = NSSize(width: 160, height: 90)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private static func busyHomeModel() -> KeelHomeModel {
        KeelHomeModel(
            resume: KeelResumeItem(
                displayURL: "https://docs.example.test/project/spec?tab=overview",
                hostname: "docs.example.test",
                title: "Project specification",
                savedAt: referenceDate.addingTimeInterval(-420)
            ),
            undo: KeelUndoItem(
                displayURL: "https://mail.example.test/inbox",
                hostname: "mail.example.test",
                title: "Inbox (12)",
                deadline: referenceDate.addingTimeInterval(480)
            ),
            queue: KeelHomeModel.fixture(count: 12, now: referenceDate).queue,
            queueDeletionUndo: KeelQueueDeletionUndoItem(
                deletedCount: 2,
                deadline: referenceDate.addingTimeInterval(50)
            )
        )
    }

    // MARK: Comparison

    private func assertSnapshot(
        of view: some View,
        named name: String,
        size: NSSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        // Home intentionally falls back to macOS's script face when the user's
        // optional Palace Script font is absent. Compare the actual face against
        // its own reviewed baseline, with the same pixel tolerance.
        let comparisonDirectory: URL
        if name.hasPrefix("home-"), NSFont(name: "PalaceScriptMT-SemiBold", size: 20) == nil {
            let variant = NSFont(name: "SnellRoundhand-Bold", size: 20) == nil ? "serif" : "snell-roundhand"
            comparisonDirectory = Self.baselineDirectory.appendingPathComponent(variant)
        } else {
            comparisonDirectory = Self.baselineDirectory
        }
        for appearance in Appearance.allCases {
            // Compare like with like. A freshly rendered rep and a PNG-decoded
            // one can hold the same picture in different colour spaces, which
            // reads as a few units of drift on most pixels and fails every run.
            let rendered = try Self.normalised(render(view, size: size, appearance: appearance))
            let baselineURL = comparisonDirectory.appendingPathComponent("\(name)-\(appearance.suffix).png")

            guard !isRecording else {
                try FileManager.default.createDirectory(
                    at: comparisonDirectory,
                    withIntermediateDirectories: true
                )
                let data: Data = try rendered.pngData()
                try data.write(to: baselineURL)
                continue
            }

            // NSBitmapImageRep has no contentsOf initialiser, only data.
            guard let baselineData = try? Data(contentsOf: baselineURL),
                  let baseline = NSBitmapImageRep(data: baselineData)
            else {
                try FileManager.default.createDirectory(at: comparisonDirectory, withIntermediateDirectories: true)
                try rendered.pngData().write(to: comparisonDirectory.appendingPathComponent("\(name)-\(appearance.suffix).failed.png"))
                XCTFail(
                    "No baseline for \(name)-\(appearance.suffix). Record with KEEL_RECORD_SNAPSHOTS=1.",
                    file: file,
                    line: line
                )
                continue
            }

            let difference = Self.differingPixelFraction(rendered, baseline)
            if difference > Self.tolerance {
                if let data = try? rendered.pngData() as Data {
                    try? data.write(
                        to: comparisonDirectory.appendingPathComponent("\(name)-\(appearance.suffix).failed.png")
                    )
                }
                XCTFail(
                    String(
                        format: "%@ %@ moved: %.3f%% of pixels differ, over the %.3f%% tolerance. "
                            + "Look at the .failed.png beside the baseline, then re-record if the change was intended.",
                        name, appearance.suffix, difference * 100, Self.tolerance * 100
                    ),
                    file: file,
                    line: line
                )
            }
        }
    }

    /// Rendering is deterministic once both sides go through the same PNG
    /// encode, so this only absorbs the odd pixel a font or OS update moves.
    /// Loose enough to ignore noise, tight enough that a changed corner radius
    /// still fails, which a 0.2 percent tolerance did not.
    private static let tolerance = 0.0002

    /// Round-trips through PNG so both sides of a comparison have been through
    /// the same encode and decode.
    private static func normalised(_ rep: NSBitmapImageRep) throws -> NSBitmapImageRep {
        let data: Data = try rep.pngData()
        guard let decoded = NSBitmapImageRep(data: data) else {
            throw SnapshotError.couldNotRender
        }
        return decoded
    }

    private static var baselineDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__")
    }

    private enum Appearance: CaseIterable {
        case light
        case dark

        var suffix: String {
            switch self {
            case .light: "light"
            case .dark: "dark"
            }
        }

        var nsAppearance: NSAppearance? {
            NSAppearance(named: self == .light ? .aqua : .darkAqua)
        }
    }

    private func render(
        _ view: some View,
        size: NSSize,
        appearance: Appearance
    ) throws -> NSBitmapImageRep {
        let hosting = NSHostingView(
            rootView: AnyView(view.environment(\.keelFixedNow, Self.referenceDate))
        )
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = appearance.nsAppearance
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw SnapshotError.couldNotRender
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    /// Compares channel values with a small per-channel threshold, so a pixel
    /// counts as different only when it is visibly different.
    private static func differingPixelFraction(
        _ left: NSBitmapImageRep,
        _ right: NSBitmapImageRep
    ) -> Double {
        guard left.pixelsWide == right.pixelsWide, left.pixelsHigh == right.pixelsHigh else {
            return 1
        }
        guard let leftData = left.bitmapData, let rightData = right.bitmapData else { return 1 }

        let samples = left.samplesPerPixel
        guard samples == right.samplesPerPixel else { return 1 }

        let pixelCount = left.pixelsWide * left.pixelsHigh
        var differing = 0
        for pixel in 0 ..< pixelCount {
            let offset = pixel * samples
            for channel in 0 ..< min(samples, 3) {
                let delta = Int(leftData[offset + channel]) - Int(rightData[offset + channel])
                if abs(delta) > 8 {
                    differing += 1
                    break
                }
            }
        }
        return Double(differing) / Double(pixelCount)
    }

    private enum SnapshotError: Error {
        case couldNotRender
    }
}

private extension NSBitmapImageRep {
    /// Named distinctly from anything AppKit vends so overload resolution cannot
    /// pick a different member.
    func pngData() throws -> Data {
        guard let data = representation(using: .png, properties: [:]) else {
            throw NSError(domain: "KeelSnapshot", code: 1)
        }
        return data
    }
}
