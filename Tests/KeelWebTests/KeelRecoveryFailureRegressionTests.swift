import AppKit
import Foundation
@testable import KeelCoordinator
@testable import KeelStore
@testable import KeelWeb
import WebKit
import XCTest

@MainActor
final class KeelRecoveryFailureRegressionTests: XCTestCase {
    func testCommittedReceiptsReachAppWithoutRevealingAWindow() async throws {
        try await withBrowser { browser, coordinator, _ in
            let url = URL(string: "https://recovery.invalid/receipt")!
            var receipts: [(URL, Bool)] = []
            var finished: [URL?] = []
            var reveals = 0
            browser.onCaptureReceipt = { receipts.append(($0, $1)) }
            browser.onFinishReceipt = { finished.append($0) }
            browser.onRevealSoleWindow = { reveals += 1 }
            browser.handle(.addURLToQueue(url))
            browser.handle(.addURLToQueue(url))
            await browser.waitForIdleForTesting()
            XCTAssertEqual(receipts.map(\.0), [url, url])
            XCTAssertEqual(receipts.map(\.1), [true, false])
            XCTAssertEqual(reveals, 0)
            XCTAssertNil(browser.contentView.window)
            let beforeClose = await coordinator.state()
            browser.closeActivePage()
            await browser.waitForIdleForTesting()
            XCTAssertEqual(finished.count, 1)
            XCTAssertEqual(finished.first!, beforeClose?.runtimeState.queue.first?.url)
            XCTAssertEqual(reveals, 0)
        }
    }

    func testSupersededNavigationFailureCannotCoverNewerWork() async throws {
        try await withBrowser { browser, coordinator, webView in
            let state = await coordinator.state()
            let page = try XCTUnwrap(state?.activePage)
            let context = try XCTUnwrap(browser.context(for: webView))
            let stale = try XCTUnwrap(webView.loadHTMLString("old", baseURL: nil))
            context.bind(NavigationBinding(pageID: page.id, navigationID: UUID(), source: .link,
                kind: .document, detourID: nil), to: stale)
            context.bind(NavigationBinding(pageID: page.id, navigationID: page.currentNavigationID,
                source: .link, kind: .document, detourID: nil), to: try XCTUnwrap(webView.loadHTMLString("new", baseURL: nil)))

            browser.navigationFailed(in: webView, navigation: stale,
                error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
            await browser.waitForIdleForTesting()

            XCTAssertNil(browser.activePageFailureForTesting())
            let after = await coordinator.state()
            XCTAssertEqual(after?.activePage, page)
            XCTAssertEqual(after?.runtimeState.queue, state?.runtimeState.queue)
        }
    }

    func testResumeSeedFailureCannotCoverTargetWithSameProductNavigationID() async throws {
        try await withBrowser { browser, coordinator, webView in
            let before = await coordinator.state()
            let page = try XCTUnwrap(before?.activePage)
            let context = try XCTUnwrap(browser.context(for: webView))
            let seed = try XCTUnwrap(webView.loadHTMLString("seed", baseURL: nil))
            context.bind(NavigationBinding(pageID: page.id, navigationID: page.currentNavigationID,
                source: .resume, kind: .document, detourID: nil), to: seed)
            let target = try XCTUnwrap(webView.loadHTMLString("target", baseURL: nil))
            context.bind(NavigationBinding(pageID: page.id, navigationID: page.currentNavigationID,
                source: .link, kind: .document, detourID: nil), to: target)
            browser.navigationFailed(in: webView, navigation: seed,
                error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))
            await browser.waitForIdleForTesting()
            XCTAssertNil(browser.activePageFailureForTesting())
            let after = await coordinator.state()
            XCTAssertEqual(after?.activePage, page)
            XCTAssertEqual(after?.runtimeState.queue, before?.runtimeState.queue)
        }
    }

    func testDownloadHandoffDoesNotHideUnrelatedFailures() async throws {
        for (marked, domain, code) in [
            (false, "WebKitErrorDomain", 102),
            (true, NSURLErrorDomain, 102),
            (true, NSURLErrorDomain, NSURLErrorNotConnectedToInternet),
            (true, "OtherDomain", NSURLErrorCancelled),
        ] {
            try await withBrowser { browser, coordinator, webView in
                let state = await coordinator.state()
                let page = try XCTUnwrap(state?.activePage)
                let context = try XCTUnwrap(browser.context(for: webView))
                let navigation = try XCTUnwrap(webView.loadHTMLString("controlled", baseURL: nil))
                context.bind(NavigationBinding(pageID: page.id, navigationID: page.currentNavigationID,
                    source: .link, kind: .document, detourID: nil), to: navigation)
                if marked { context.markDownloadHandoff() }
                browser.navigationFailed(in: webView, navigation: navigation,
                    error: NSError(domain: domain, code: code))
                await browser.waitForIdleForTesting()
                XCTAssertEqual(browser.activePageFailureForTesting()?.code, code)
                let after = await coordinator.state()
                XCTAssertEqual(after?.activePage?.status, .technicalFailure)
                XCTAssertEqual(after?.runtimeState.queue, state?.runtimeState.queue)
            }
        }
    }

    func testDownloadHandoffDoesNotSuppressNextNavigationPolicyError() async throws {
        try await withBrowser { browser, coordinator, webView in
            let state = await coordinator.state()
            let page = try XCTUnwrap(state?.activePage)
            let context = try XCTUnwrap(browser.context(for: webView))
            context.markDownloadHandoff()
            let navigation = try XCTUnwrap(webView.loadHTMLString("next", baseURL: nil))
            context.bind(NavigationBinding(pageID: page.id, navigationID: page.currentNavigationID,
                source: .link, kind: .document, detourID: nil), to: navigation)
            browser.navigationFailed(in: webView, navigation: navigation,
                error: NSError(domain: "WebKitErrorDomain", code: 102))
            await browser.waitForIdleForTesting()
            XCTAssertEqual(browser.activePageFailureForTesting()?.code, 102)
        }
    }

    func testRetryAfterPrecommitTerminationCommitsNewCheckpoint() async throws {
        try await withBrowser { browser, coordinator, webView in
            let before = await coordinator.state()
            let page = try XCTUnwrap(before?.activePage)
            let controlled = try XCTUnwrap(webView as? RecoveryWebView)
            let context = try XCTUnwrap(browser.context(for: webView))
            XCTAssertNil(context.lastCommittedBinding)
            browser.webContentProcessDidTerminate(webView)
            await browser.waitForIdleForTesting()
            let errorView = try XCTUnwrap(browser.contentView.subviews.compactMap { $0 as? KeelPageErrorView }.first)
            errorView.onRetry?()
            let retry = try XCTUnwrap(controlled.lastReloadNavigation)
            browser.navigationDidStart(in: webView, navigation: retry)
            await browser.waitForIdleForTesting()
            browser.navigationDidCommit(in: webView, navigation: retry)
            await browser.waitForIdleForTesting()
            let after = await coordinator.state()
            XCTAssertNotEqual(after?.activePage?.currentNavigationID, page.currentNavigationID)
            XCTAssertEqual(after?.activePage?.currentNavigationID, context.binding(for: retry)?.navigationID)
            XCTAssertEqual(after?.activePage?.sessionID, page.sessionID)
            XCTAssertEqual(after?.activePage?.status, .ready)
            XCTAssertEqual(after?.runtimeState.resumeCheckpoint?.url, controlled.url)
            XCTAssertEqual(after?.runtimeState.resumeCheckpoint?.sessionID, page.sessionID)
            XCTAssertEqual(after?.runtimeState.queue, before?.runtimeState.queue)
            XCTAssertNil(browser.activePageFailureForTesting())
        }
    }

    func testProcessTerminationBeforeFirstCommitLeavesQueueAndSessionInPlace() async throws {
        try await withBrowser { browser, coordinator, webView in
            let before = await coordinator.state()
            let page = try XCTUnwrap(before?.activePage)
            let context = try XCTUnwrap(browser.context(for: webView))
            XCTAssertNil(context.lastCommittedBinding)
            browser.webContentProcessDidTerminate(webView)
            await browser.waitForIdleForTesting()

            let after = await coordinator.state()
            XCTAssertEqual(after?.activePage?.id, page.id)
            XCTAssertEqual(after?.activePage?.sessionID, page.sessionID)
            XCTAssertEqual(after?.activePage?.status, .technicalFailure)
            XCTAssertEqual(after?.runtimeState.queue, before?.runtimeState.queue)
            XCTAssertEqual(browser.activePageFailureForTesting()?.code, KeelPageFailure.webContentProcessTerminated)
            XCTAssertLessThanOrEqual(browser.liveWebViewCount, 2)
        }
    }

    func testOfflineCallbackKeepsQueueWithoutCreatingUndo() async throws {
        try await withBrowser { browser, coordinator, webView in
            let before = await coordinator.state()
            let page = try XCTUnwrap(before?.activePage)
            let context = try XCTUnwrap(browser.context(for: webView))
            let navigation = try XCTUnwrap(webView.loadHTMLString("offline", baseURL: nil))
            context.bind(NavigationBinding(pageID: page.id, navigationID: page.currentNavigationID,
                source: .link, kind: .document, detourID: nil), to: navigation)
            browser.navigationFailed(in: webView, navigation: navigation,
                error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
            await browser.waitForIdleForTesting()
            let after = await coordinator.state()
            XCTAssertEqual(after?.activePage?.status, .technicalFailure)
            XCTAssertEqual(after?.runtimeState.queue, before?.runtimeState.queue)
            XCTAssertNil(after?.undoPage)
            XCTAssertEqual(browser.activePageFailureForTesting()?.title, "You are offline")
        }
    }

    private func withBrowser(
        _ body: (KeelBrowserController, KeelCoordinator, WKWebView) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "KeelRecovery-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeelStore(databaseURL: directory.appending(path: "Keel.sqlite3"))
        let coordinator = KeelCoordinator(store: store)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let browser = KeelBrowserController(contentView: host, coordinator: coordinator, store: store,
            webViewFactory: { configuration in
                configuration.websiteDataStore = .nonPersistent()
                return RecoveryWebView(frame: .zero, configuration: configuration)
            }, media: KeelMediaController(), uploadPresenter: RecoveryUploadPresenter())
        browser.start()
        await browser.waitForIdleForTesting()
        browser.openTypedURL(URL(string: "https://recovery.invalid/unfinished")!)
        browser.handle(.addURLToQueue(URL(string: "https://recovery.invalid/queued")!))
        await browser.waitForIdleForTesting()
        let webView = try XCTUnwrap(host.subviews.compactMap { $0 as? WKWebView }.first)
        webView.stopLoading()
        try await body(browser, coordinator, webView)
    }
}

@MainActor
private final class RecoveryWebView: WKWebView {
    var lastReloadNavigation: WKNavigation?
    override var url: URL? { URL(string: "https://recovery.invalid/unfinished") }
    override func reload() -> WKNavigation? {
        let navigation = loadHTMLString("recovered", baseURL: url)
        lastReloadNavigation = navigation
        return navigation
    }
}

@MainActor
private final class RecoveryUploadPresenter: KeelUploadPresenting {
    func present(parameters: WKOpenPanelParameters, in window: NSWindow?,
                 completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        completionHandler(nil)
    }
}
