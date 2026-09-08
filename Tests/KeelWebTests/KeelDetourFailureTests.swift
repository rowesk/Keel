import AppKit
import Foundation
@testable import KeelCoordinator
@testable import KeelStore
@testable import KeelWeb
import WebKit
import XCTest

@MainActor
final class KeelDetourFailureTests: XCTestCase {
    func testDetourFailureOffersOnlyRetryAndClose() {
        let view = KeelPageErrorView()
        let failure = KeelPageFailure(
            host: "checkout.example",
            code: NSURLErrorCannotFindHost,
            underlyingDescription: "A server with the specified hostname could not be found."
        )

        view.present(failure: failure, exits: .transactionalDetour)
        XCTAssertEqual(view.visibleExitTitlesForTesting(), ["Try Again", "Close"])

        view.present(failure: failure, exits: .activePage)
        XCTAssertEqual(view.visibleExitTitlesForTesting(), ["Try Again", "Close and Continue", "Go to Keel Home"])
    }

    func testDetourPanelStopsLoadingWhenTheFailureAppears() {
        let overlay = KeelDetourOverlay(id: UUID(), hostname: "checkout.example")
        let failure = KeelPageFailure(
            host: "checkout.example",
            code: NSURLErrorTimedOut,
            underlyingDescription: "The request timed out."
        )

        overlay.beginLoading()
        XCTAssertTrue(overlay.isLoading)
        XCTAssertNil(overlay.presentedFailure)

        overlay.presentFailure(failure)
        XCTAssertFalse(overlay.isLoading)
        XCTAssertEqual(overlay.presentedFailure, failure)

        // A failure on screen blocks the spinner until a retry clears it.
        overlay.beginLoading()
        XCTAssertFalse(overlay.isLoading)

        overlay.clearFailure()
        overlay.beginLoading()
        XCTAssertTrue(overlay.isLoading)
        XCTAssertNil(overlay.presentedFailure)
    }

    func testFailedDetourDrawsInsideThePanelAndLeavesTheActivePageAlone() async throws {
        let fixture = try KeelOffscreenLoopbackFixture(routes: [
            "/opener": .init(body: """
            <!doctype html><title>Opener</title>
            <script>setTimeout(() => window.open('http://keel-detour-failure.invalid/pay', 'keel-detour'), 0)</script>
            """),
        ])
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeelStore(databaseURL: directory.appending(path: "Keel.sqlite3"))
        let coordinator = KeelCoordinator(store: store)
        let factory = PopupWebViewFactory(websiteDataStore: .nonPersistent())
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = attachOffscreen(host)
        defer { window.close() }
        let browser = KeelBrowserController(
            contentView: host,
            coordinator: coordinator,
            store: store,
            webViewFactory: { factory.make(configuration: $0) },
            media: ImmediateMediaController(),
            uploadPresenter: SilentUploadPresenter()
        )

        browser.start()
        await browser.waitForIdleForTesting()
        browser.handle(KeelCoordinatorEvent.openTypedURL(fixture.url(path: "/opener")))
        await browser.waitForIdleForTesting()
        let activePageID = try XCTUnwrap(browser.debugSnapshotForTesting().activePageID)

        try await waitUntil(timeout: 10) { browser.detourPresentationForTesting().failure != nil }
        await browser.waitForIdleForTesting()

        let presentation = browser.detourPresentationForTesting()
        XCTAssertNotNil(presentation.detourID)
        XCTAssertFalse(presentation.isLoading)
        XCTAssertEqual(presentation.failure?.host, "keel-detour-failure.invalid")

        // The page underneath keeps its own state: no error screen over it, no
        // technical failure in the coordinator, and it is still the active page.
        XCTAssertNil(browser.activePageFailureForTesting())
        XCTAssertFalse(browser.activePageErrorViewIsVisibleForTesting())
        XCTAssertEqual(browser.debugSnapshotForTesting().activePageID, activePageID)
        let state = await coordinator.state()
        XCTAssertNotEqual(state?.activePage?.status, KeelPageStatus.technicalFailure)

        browser.handle(KeelCoordinatorEvent.closeTransactionalDetour(detourID: try XCTUnwrap(presentation.detourID)))
        await browser.waitForIdleForTesting()
        try await waitUntil { browser.detourPresentationForTesting().detourID == nil }
        XCTAssertEqual(browser.debugSnapshotForTesting().activePageID, activePageID)
    }

    /// WebKit needs an AppKit host to start a content process. This window never orders
    /// front, becomes key, or joins the user's window list.
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
            guard Date() < deadline else { throw DetourWaitError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "KeelDetourFailureTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private enum DetourWaitError: Error {
    case timedOut
}

@MainActor
private final class PopupWebViewFactory {
    private let websiteDataStore: WKWebsiteDataStore
    private(set) var webViews: [WKWebView] = []

    init(websiteDataStore: WKWebsiteDataStore) {
        self.websiteDataStore = websiteDataStore
    }

    func make(configuration: WKWebViewConfiguration) -> WKWebView {
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = KeelWebViewFactory.make(configuration: configuration, websiteDataStore: websiteDataStore)
        webViews.append(webView)
        return webView
    }
}

@MainActor
private final class ImmediateMediaController: KeelMediaControlling {
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
