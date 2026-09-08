import AppKit
import Foundation
@testable import KeelCoordinator
@testable import KeelStore
@testable import KeelWeb
import WebKit
import XCTest

@MainActor
final class KeelDownloadDestinationTests: XCTestCase {
    func testChangingTheFolderMovesOnlyLaterDownloads() async throws {
        let payload = Data(repeating: 0xAB, count: 4 * 1_024)
        let fixture = try KeelOffscreenLoopbackFixture(routes: [
            "/first": attachment(named: "first.bin", body: payload),
            "/second": attachment(named: "second.bin", body: payload),
        ])
        let supportDirectory = try temporaryDirectory()
        let firstFolder = try temporaryDirectory()
        let secondFolder = try temporaryDirectory()
        defer {
            for directory in [supportDirectory, firstFolder, secondFolder] {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        let store = try KeelStore(databaseURL: supportDirectory.appending(path: "Keel.sqlite3"))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = attachOffscreen(host)
        defer { window.close() }
        let browser = KeelBrowserController(
            contentView: host,
            coordinator: KeelCoordinator(store: store),
            store: store,
            webViewFactory: { KeelWebViewFactory.make(configuration: $0, websiteDataStore: .nonPersistent()) },
            media: PassthroughMediaController(),
            uploadPresenter: SilentUploadPresenter(),
            downloadDestinationDirectory: firstFolder
        )

        browser.start()
        await browser.waitForIdleForTesting()
        browser.handle(KeelCoordinatorEvent.openTypedURL(fixture.url(path: "/first")))
        try await waitUntil(timeout: 6) { browser.downloads.contains { $0.filename == "first.bin" && $0.state == .completed } }
        let firstDestination = try XCTUnwrap(browser.downloads.first { $0.filename == "first.bin" }?.destinationURL)
        XCTAssertTrue(firstDestination.path.hasPrefix(firstFolder.path + "/"))

        browser.setDownloadDestinationDirectory(secondFolder)
        browser.handle(KeelCoordinatorEvent.openTypedURL(fixture.url(path: "/second")))
        try await waitUntil(timeout: 6) { browser.downloads.contains { $0.filename == "second.bin" && $0.state == .completed } }

        let secondDestination = try XCTUnwrap(browser.downloads.first { $0.filename == "second.bin" }?.destinationURL)
        XCTAssertTrue(secondDestination.path.hasPrefix(secondFolder.path + "/"))
        // The finished transfer keeps the file it already wrote.
        XCTAssertEqual(browser.downloads.first { $0.filename == "first.bin" }?.destinationURL, firstDestination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstDestination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondDestination.path))
    }

    func testNilFolderFallsBackToTheSystemDownloadsFolder() async throws {
        let supportDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let store = try KeelStore(databaseURL: supportDirectory.appending(path: "Keel.sqlite3"))
        let browser = KeelBrowserController(
            contentView: NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480)),
            coordinator: KeelCoordinator(store: store),
            store: store,
            webViewFactory: { KeelWebViewFactory.make(configuration: $0, websiteDataStore: .nonPersistent()) },
            media: PassthroughMediaController(),
            uploadPresenter: SilentUploadPresenter(),
            downloadDestinationDirectory: supportDirectory
        )

        browser.setDownloadDestinationDirectory(nil)

        XCTAssertEqual(
            browser.downloadDestinationDirectoryForTesting(),
            KeelDownloadManager.defaultDestinationDirectory()
        )
    }

    private func attachment(named name: String, body: Data) -> KeelOffscreenLoopbackFixture.Response {
        KeelOffscreenLoopbackFixture.Response(
            headers: [
                "Content-Type": "application/octet-stream",
                "Content-Disposition": "attachment; filename=\(name)",
            ],
            body: body
        )
    }

    private func attachOffscreen(_ contentView: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        return window
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw DownloadDestinationWaitError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "KeelDownloadDestinationTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private enum DownloadDestinationWaitError: Error {
    case timedOut
}

@MainActor
private final class PassthroughMediaController: KeelMediaControlling {
    func pauseBeforeDetour(in webView: WKWebView, performDetour: @escaping @MainActor @Sendable () -> Void) {
        performDetour()
    }

    func pauseBeforeDiscard(in webView: WKWebView, performDiscard: @escaping @MainActor @Sendable () -> Void) {
        performDiscard()
    }

    func resumeAfterDetour(in webView: WKWebView, completion: (@MainActor @Sendable () -> Void)?) {
        completion?()
    }
}

@MainActor
private final class SilentUploadPresenter: KeelUploadPresenting {
    func present(
        parameters: WKOpenPanelParameters,
        in window: NSWindow?,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        completionHandler(nil)
    }
}
