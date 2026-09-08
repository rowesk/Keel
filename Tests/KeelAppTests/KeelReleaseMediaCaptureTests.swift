import AppKit
import SwiftUI
import KeelUI
import XCTest
@testable import KeelApp

/// Opt-in release artwork, rendered from current views with fictional data.
/// Never opens a window, reads the browser profile, or records test baselines.
@MainActor
final class KeelReleaseMediaCaptureTests: XCTestCase {
    func testCaptureReleaseMedia() throws {
        guard let directory = ProcessInfo.processInfo.environment["KEEL_RELEASE_MEDIA_DIRECTORY"] else {
            throw XCTSkip("Set KEEL_RELEASE_MEDIA_DIRECTORY to export release artwork")
        }
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let titles = ["A weekend by the coast", "The walking route", "A place for lunch"]
        let paths = ["coast", "walk", "lunch"]
        let queue = titles.enumerated().map { index, title in
            KeelQueueItem(id: UUID(), displayURL: "https://example.com/\(paths[index])",
                          hostname: "example.com", title: title,
                          capturedAt: now.addingTimeInterval(Double(index - 3) * 60),
                          sequence: Int64(index))
        }
        for dark in [false, true] {
            for queued in [false, true] {
                let palette = KeelAddressPaletteController()
                let state = KeelEmbeddedPaletteState()
                let view = HomeView(
                    model: KeelHomeModel(queue: queued ? queue : []),
                    addressField: AnyView(KeelEmbeddedAddressField(state: state, palette: palette)),
                    queueInitiallyExpanded: queued
                )
                .environment(\.keelFixedNow, now)
                .environment(\.colorScheme, dark ? .dark : .light)
                .transaction { $0.disablesAnimations = true }
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 1120, height: 720)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded()
                XCTAssertNil(host.window)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let name = "\(queued ? "queue" : "home")-\(dark ? "dark" : "light").png"
                try data.write(to: destination.appendingPathComponent(name))
                XCTAssertGreaterThan(data.count, 10_000)
                palette.dismiss(notify: false)
            }
        }
    }
}
