import AppKit
import Foundation
@testable import KeelCoordinator
@testable import KeelStore
@testable import KeelWeb
import WebKit
import XCTest

/// Focused production-adapter checks that run without a window, application launch,
/// browser profile, or external network access.
@MainActor
final class KeelWebOffscreenIntegrationMatrixTests: XCTestCase {
    func testLoopbackNavigationFinishesInsideTheFocusedBudget() async throws {
        let fixture = try KeelOffscreenLoopbackFixture(routes: [
            "/warm": .init(body: "<title>Warm</title><p>Keel</p>"),
            "/fast": .init(body: "<title>Fast</title><p>Keel</p>"),
        ])
        let (body, response) = try await URLSession.shared.data(from: fixture.url(path: "/fast"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "<title>Fast</title><p>Keel</p>")
        let webView = isolatedWebView()
        let window = attachOffscreen(webView)
        defer { window.close() }
        let probe = NavigationProbe()
        webView.navigationDelegate = probe

        let warmed = expectation(description: "WebKit content process warmed")
        probe.onFinish = { warmed.fulfill() }
        webView.load(URLRequest(url: fixture.url(path: "/warm")))
        await fulfillment(of: [warmed], timeout: 2)

        let started = expectation(description: "committed navigation started")
        let finished = expectation(description: "loopback page finished")
        probe.onStart = { started.fulfill() }
        probe.onFinish = { finished.fulfill() }

        let startedAt = Date()
        webView.load(URLRequest(url: fixture.url(path: "/fast")))
        await fulfillment(of: [started], timeout: 1)
        let initiationTime = Date().timeIntervalSince(startedAt)
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertLessThan(initiationTime, 0.15)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        XCTAssertEqual(webView.url, fixture.url(path: "/fast"))
    }

    func testFactoryDoesNotOverrideRootOrFrameScrollbars() async throws {
        let fixture = try KeelOffscreenLoopbackFixture(routes: [
            "/root": .init(body: """
            <!doctype html>
            <html><head></head><body>
              <iframe src="/frame"></iframe>
            </body></html>
            """),
            "/frame": .init(body: "<!doctype html><html><head></head><body>nested</body></html>"),
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = KeelWebViewFactory.make(configuration: configuration, websiteDataStore: .nonPersistent())
        let window = attachOffscreen(webView)
        defer { window.close() }
        let probe = NavigationProbe()
        let finished = expectation(description: "root page finished")
        probe.onFinish = { finished.fulfill() }
        webView.navigationDelegate = probe

        webView.load(URLRequest(url: fixture.url(path: "/root")))
        await fulfillment(of: [finished], timeout: 2)
        // WebKit updates public interactionState asynchronously after a scroll.
        try await Task.sleep(for: .milliseconds(50))

        let result = try await webView.evaluateString("""
        JSON.stringify({
          root: document.querySelector('#keel-root-scrollbar-hiding') !== null,
          frame: document.querySelector('iframe').contentDocument.querySelector('#keel-root-scrollbar-hiding') !== null
        })
        """)
        XCTAssertEqual(result, #"{"root":false,"frame":false}"#)
    }

    func testHistoryFailuresReportOnceAndSuccessfulWritesRecoverRecording() async throws {
        let fixture = try KeelOffscreenLoopbackFixture(routes: Dictionary(uniqueKeysWithValues: (1...4).map {
            ("/page-\($0)", .init(body: "<title>Page \($0)</title><p id='ready'>ready</p>"))
        }))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeelStore(databaseURL: directory.appendingPathComponent("Keel.sqlite3"))
        let history = FailingHistoryPersistence(store: store)
        let factory = RecordingWebViewFactory(websiteDataStore: .nonPersistent())
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = attachOffscreen(host)
        defer { window.close() }
        let browser = KeelBrowserController(contentView: host, coordinator: KeelCoordinator(store: store), store: store,
            webViewFactory: { factory.make(configuration: $0) }, media: RecordingMediaController(), uploadPresenter: NoopUploadPresenter(), historyPersistence: history)
        var reports: [String] = []
        browser.onHistoryPersistenceFailure = { reports.append($0) }
        browser.start()
        await browser.waitForIdleForTesting()
        for index in 1...4 {
            if index == 3 { await history.setFailing(false) }
            if index == 4 { await history.setTitleFailing(true) }
            browser.openTypedURL(fixture.url(path: "/page-\(index)"))
            await browser.waitForIdleForTesting()
            let webView = try XCTUnwrap(factory.webViews.first)
            try await waitForURL(webView, fixture.url(path: "/page-\(index)"))
            try await waitUntil { !webView.isLoading }
            await browser.context(for: webView)?.historyTail?.value
            XCTAssertEqual(reports.count, index == 4 ? 2 : 1)
            XCTAssertEqual(browser.debugSnapshotForTesting().liveWebViewCount, 1)
        }
        XCTAssertTrue(reports.allSatisfy { !$0.contains("secret") && $0.contains("123") })
    }

    func testResumeRedirectToSimulatedExpiredLoginKeepsSessionAndQueue() async throws {
        let fixture = try KeelOffscreenLoopbackFixture(routes: [
            "/unfinished": .init(status: "302 Found", headers: ["Location": "/login"], body: ""),
            "/login": .init(body: "<title>Sign in</title><p id='login'>Your session expired. Sign in again.</p>"),
        ])
        defer { withExtendedLifetime(fixture) {} }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeelStore(databaseURL: directory.appendingPathComponent("Keel.sqlite3"))
        let session = BrowsingSession(id: UUID(), startedAt: Date())
        _ = try await store.apply([
            .upsertSession(session),
            .replaceResumeCheckpoint(ResumeCheckpoint(url: fixture.url(path: "/unfinished"), sessionID: session.id, savedAt: Date())),
        ])
        let coordinator = KeelCoordinator(store: store)
        let factory = RecordingWebViewFactory(websiteDataStore: .nonPersistent())
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = attachOffscreen(host)
        defer { window.close() }
        let browser = KeelBrowserController(contentView: host, coordinator: coordinator, store: store,
            webViewFactory: { factory.make(configuration: $0) }, media: RecordingMediaController(), uploadPresenter: NoopUploadPresenter())
        browser.start()
        await browser.waitForIdleForTesting()
        browser.handle(.addURLToQueue(fixture.url(path: "/queued")))
        await browser.waitForIdleForTesting()
        let before = await coordinator.state()
        browser.handle(.resumeCheckpoint)
        await browser.waitForIdleForTesting()
        let webView = try XCTUnwrap(factory.webViews.first)
        try await waitForElement("#login", in: webView)
        try await waitUntil { !webView.isLoading }
        await browser.waitForIdleForTesting()
        let after = await coordinator.state()
        XCTAssertEqual(after?.activePage?.url, fixture.url(path: "/login"))
        XCTAssertEqual(after?.activePage?.sessionID, session.id)
        XCTAssertEqual(after?.runtimeState.queue, before?.runtimeState.queue)
        XCTAssertNil(after?.undoPage)
        XCTAssertEqual(browser.liveWebViewCount, 1)
    }

    func testFailedResumeSeedPreservesOriginalURLAndLoadsRequestedTarget() async throws {
        try await assertFailedResumeSeedLoadsLatestTarget(supersedesTarget: false)
    }

    func testNewOpenDuringFailedResumeSeedCannotBeReplacedByStaleTarget() async throws {
        try await assertFailedResumeSeedLoadsLatestTarget(supersedesTarget: true)
    }

    private func assertFailedResumeSeedLoadsLatestTarget(supersedesTarget: Bool) async throws {
        let fixture = try KeelOffscreenLoopbackFixture(routes: [
            "/latest": .init(body: "<title>Latest</title><p id='ready'>latest</p>"),
            "/target": .init(body: "<title>Target</title><p id='ready'>target</p>"),
        ])
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeelStore(databaseURL: directory.appendingPathComponent("Keel.sqlite3"))
        let sessionID = UUID()
        var unavailableServer: KeelOffscreenLoopbackFixture? = try KeelOffscreenLoopbackFixture(routes: [:])
        let unavailable = try XCTUnwrap(unavailableServer).url(path: "/unfinished")
        unavailableServer = nil
        _ = try await store.apply([
            .upsertSession(BrowsingSession(id: sessionID, startedAt: Date(), hostname: "127.0.0.1")),
            .replaceResumeCheckpoint(ResumeCheckpoint(url: unavailable, sessionID: sessionID, savedAt: Date())),
        ])
        let coordinator = KeelCoordinator(store: store)
        let factory = RecordingWebViewFactory(websiteDataStore: .nonPersistent())
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = attachOffscreen(host)
        defer { window.close() }
        let browser = KeelBrowserController(contentView: host, coordinator: coordinator, store: store,
            webViewFactory: { factory.make(configuration: $0) }, media: RecordingMediaController(), uploadPresenter: NoopUploadPresenter())
        browser.start()
        await browser.waitForIdleForTesting()
        browser.openTypedURL(fixture.url(path: "/target"))
        await browser.waitForIdleForTesting()
        let expected = fixture.url(path: supersedesTarget ? "/latest" : "/target")
        if supersedesTarget {
            browser.openTypedURL(expected)
            await browser.waitForIdleForTesting()
        }
        let webView = try XCTUnwrap(factory.webViews.first)
        try await waitForURL(webView, expected)
        try await waitUntil { !webView.isLoading }
        await browser.waitForIdleForTesting()
        let currentState = await coordinator.state()
        let state = try XCTUnwrap(currentState)
        XCTAssertEqual(state.activePage?.url, expected)
        XCTAssertEqual(state.activePage?.sessionID, sessionID)
        XCTAssertEqual(state.runtimeState.queue.map(\.url), [unavailable])
        XCTAssertNil(webView.backForwardList.backItem, "Unexpected back URL: \(String(describing: webView.backForwardList.backItem?.url))")
        XCTAssertEqual(browser.debugSnapshotForTesting().liveWebViewCount, 1)
    }

    func testExplicitOpenFromResumePreservesBackNavigationWithAndWithoutInteractionState() async throws {
        let fixture = try KeelOffscreenLoopbackFixture(routes: [
            "/unfinished": .init(body: "<title>Unfinished</title><p id='ready'>work</p>"),
            "/target": .init(body: "<title>Target</title><p id='ready'>target</p>"),
        ])
        let seed = isolatedWebView()
        let seedWindow = attachOffscreen(seed)
        defer { seedWindow.close() }
        seed.load(URLRequest(url: fixture.url(path: "/unfinished")))
        try await waitForElement("#ready", in: seed)
        try await Task.sleep(for: .milliseconds(100))
        let state = try NSKeyedArchiver.archivedData(withRootObject: XCTUnwrap(seed.interactionState), requiringSecureCoding: false)
        for interactionState in [nil, state] as [Data?] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try KeelStore(databaseURL: directory.appendingPathComponent("Keel.sqlite3"))
            let sessionID = UUID()
            _ = try await store.apply([
                .upsertSession(BrowsingSession(id: sessionID, startedAt: Date(), hostname: "127.0.0.1")),
                .replaceResumeCheckpoint(ResumeCheckpoint(url: fixture.url(path: "/unfinished"), sessionID: sessionID, savedAt: Date(), interactionState: interactionState)),
            ])
            let factory = RecordingWebViewFactory(websiteDataStore: .nonPersistent())
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
            let window = attachOffscreen(host)
            defer { window.close() }
            let browser = KeelBrowserController(contentView: host, coordinator: KeelCoordinator(store: store), store: store,
                webViewFactory: { factory.make(configuration: $0) }, media: RecordingMediaController(), uploadPresenter: NoopUploadPresenter())
            browser.start()
            await browser.waitForIdleForTesting()
            browser.openTypedURL(fixture.url(path: "/target"))
            await browser.waitForIdleForTesting()
            let webView = try XCTUnwrap(factory.webViews.first)
            try await waitForURL(webView, fixture.url(path: "/target"))
            try await waitUntil { !webView.isLoading }
            XCTAssertEqual(webView.backForwardList.backItem?.url, fixture.url(path: "/unfinished"))
            webView.goBack()
            try await waitForURL(webView, fixture.url(path: "/unfinished"))
            XCTAssertEqual(browser.debugSnapshotForTesting().liveWebViewCount, 1)
        }
    }

    func testClientGeneratedAndDownloadAttributeFilesUseRealDownloadDelegates() async throws {
        let fixture = try KeelOffscreenLoopbackFixture(routes: [
            "/exports": .init(body: "<title>Exports</title><p id='ready'>ready</p>"),
            "/plain": .init(headers: ["Content-Type": "text/plain", "Content-Disposition": "attachment; filename=plain.txt"], body: Data("plain export".utf8)),
        ])
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeelStore(databaseURL: directory.appendingPathComponent("Keel.sqlite3"))
        let factory = RecordingWebViewFactory(websiteDataStore: .nonPersistent())
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = attachOffscreen(host)
        defer { window.close() }
        let browser = KeelBrowserController(contentView: host, coordinator: KeelCoordinator(store: store), store: store,
            webViewFactory: { factory.make(configuration: $0) }, media: RecordingMediaController(),
            uploadPresenter: NoopUploadPresenter(), downloadDestinationDirectory: directory)
        var completed: [KeelDownloadSnapshot] = []
        browser.onDownloadSnapshotsChanged = { completed = $0.filter { $0.state == .completed } }
        browser.start()
        await browser.waitForIdleForTesting()
        browser.openTypedURL(fixture.url(path: "/exports"))
        await browser.waitForIdleForTesting()
        let webView = try XCTUnwrap(factory.webViews.first)
        try await waitForElement("#ready", in: webView)
        for (index, href) in ["URL.createObjectURL(new Blob(['blob export'], {type:'text/plain'}))", "'data:text/plain,data%20export'", "'/plain'"].enumerated() {
            _ = try await webView.evaluateString("""
            { const a = document.createElement('a'); a.href = \(href); a.download = ''; document.body.appendChild(a); a.click(); a.remove(); } 'requested'
            """)
            try await waitUntil(timeout: 4) { completed.count == index + 1 }
            await browser.waitForIdleForTesting()
            XCTAssertNil(browser.activePageFailureForTesting())
        }
        XCTAssertEqual(Set(try completed.map { try String(contentsOf: XCTUnwrap($0.destinationURL), encoding: .utf8) }), Set(["blob export", "data export", "plain export"]))
        XCTAssertEqual(webView.url, fixture.url(path: "/exports"))
        XCTAssertEqual(browser.debugSnapshotForTesting().liveWebViewCount, 1)
    }

    func testAttachmentNavigationDoesNotPresentPageFailure() async throws {
        let fixture = try KeelOffscreenLoopbackFixture(routes: [
            "/source": .init(body: "<title>Download source</title><p id='ready'>Keep this page</p>"),
            "/attachment": .init(headers: ["Content-Type": "application/octet-stream",
                "Content-Disposition": "attachment; filename=handoff.txt"], body: "download handoff"),
            "/redirect": .init(status: "302 Found", headers: ["Location": "/attachment"], body: ""),
            "/text-attachment": .init(headers: ["Content-Type": "text/plain",
                "Content-Disposition": "attachment; filename=readable.txt"], body: "download handoff"),
        ])
        defer { withExtendedLifetime(fixture) {} }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeelStore(databaseURL: directory.appendingPathComponent("Keel.sqlite3"))
        let coordinator = KeelCoordinator(store: store)
        let factory = RecordingWebViewFactory(websiteDataStore: .nonPersistent())
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = attachOffscreen(host)
        defer { window.close() }
        let browser = KeelBrowserController(contentView: host, coordinator: coordinator, store: store,
            webViewFactory: { factory.make(configuration: $0) }, media: RecordingMediaController(),
            uploadPresenter: NoopUploadPresenter(), downloadDestinationDirectory: directory)
        var completed: [KeelDownloadSnapshot] = []
        browser.onDownloadSnapshotsChanged = { completed = $0.filter { $0.state == .completed } }
        browser.start()
        await browser.waitForIdleForTesting()
        browser.handle(.addURLToQueue(fixture.url(path: "/queued")))
        await browser.waitForIdleForTesting()
        let before = await coordinator.state()
        for (index, path) in ["/attachment", "/redirect", "/text-attachment"].enumerated() {
            if index == 1 {
                browser.openTypedURL(fixture.url(path: "/source"))
                await browser.waitForIdleForTesting()
                try await waitForElement("#ready", in: XCTUnwrap(factory.webViews.first))
            }
            browser.openTypedURL(fixture.url(path: path))
            await browser.waitForIdleForTesting()
            try await waitUntil(timeout: 4) { completed.count == index + 1 }
            await browser.waitForIdleForTesting()
            XCTAssertNil(browser.activePageFailureForTesting(), "Successful attachment must not show Frame load interrupted")
            let state = await coordinator.state()
            XCTAssertEqual(state?.activePage?.status, .ready)
            XCTAssertEqual(state?.runtimeState.queue, before?.runtimeState.queue)
            if index > 0 {
                let webView = try XCTUnwrap(factory.webViews.first)
                let title = try await webView.evaluateString("document.title")
                XCTAssertEqual(title, "Download source")
            }
        }
        XCTAssertEqual(try completed.map { try String(contentsOf: XCTUnwrap($0.destinationURL), encoding: .utf8) },
            ["download handoff", "download handoff", "download handoff"])
    }

    func testRepeatedDownloadsPreserveExistingFiles() async throws {
        let fixture = try KeelOffscreenLoopbackFixture(routes: [
            "/attachment": .init(headers: ["Content-Type": "application/octet-stream",
                "Content-Disposition": "attachment; filename=handoff.txt"], body: "download handoff"),
        ])
        defer { withExtendedLifetime(fixture) {} }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for folder in ["Downloads", "Downloads with spaces #1%"] {
            let destination = directory.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            // Existing files must survive both duplicate naming and encoded path characters.
            for name in ["handoff.txt", "handoff (2).txt"] {
                try Data("existing file".utf8).write(to: destination.appendingPathComponent(name))
            }
            let store = try KeelStore(databaseURL: destination.appendingPathComponent("Keel.sqlite3"))
            let coordinator = KeelCoordinator(store: store)
            let factory = RecordingWebViewFactory(websiteDataStore: .nonPersistent())
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
            let window = attachOffscreen(host)
            defer { window.close() }
            let browser = KeelBrowserController(contentView: host, coordinator: coordinator, store: store,
                webViewFactory: { factory.make(configuration: $0) }, media: RecordingMediaController(),
                uploadPresenter: NoopUploadPresenter(), downloadDestinationDirectory: destination)
            var completed: [UUID: KeelDownloadSnapshot] = [:]
            var failed: [KeelDownloadSnapshot] = []
            browser.onDownloadSnapshotsChanged = { snapshots in
                for snapshot in snapshots where snapshot.state == .completed { completed[snapshot.id] = snapshot }
                failed = snapshots.filter { if case .failed = $0.state { return true }; return false }
            }
            browser.start()
            await browser.waitForIdleForTesting()
            for index in 0..<6 {
                browser.openTypedURL(fixture.url(path: "/attachment"))
                await browser.waitForIdleForTesting()
                try await waitUntil(timeout: 4) { completed.count == index + 1 || !failed.isEmpty }
                guard failed.isEmpty else { return XCTFail("Repeated transfer failed: \(failed.map(\.state))") }
                XCTAssertEqual(completed.count, index + 1)
                XCTAssertNil(browser.activePageFailureForTesting())
                // Exercise the same cleanup as the terminal shelf timeout.
                for snapshot in browser.downloads where snapshot.state.isTerminal { browser.dismissDownload(id: snapshot.id) }
            }
            XCTAssertEqual(Set(completed.values.compactMap { $0.destinationURL?.lastPathComponent }),
                Set((3...8).map { "handoff (\($0)).txt" }))
            for snapshot in completed.values {
                XCTAssertEqual(try String(contentsOf: XCTUnwrap(snapshot.destinationURL), encoding: .utf8), "download handoff")
            }
            for name in ["handoff.txt", "handoff (2).txt"] {
                XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(name), encoding: .utf8), "existing file")
            }
        }
    }

    func testAttachmentDestinationFailureStaysInDownloads() async throws {
        let fixture = try KeelOffscreenLoopbackFixture(routes: [
            "/attachment": .init(headers: ["Content-Type": "application/octet-stream",
                "Content-Disposition": "attachment; filename=handoff.txt"], body: "download handoff"),
        ])
        defer { withExtendedLifetime(fixture) {} }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidDirectory = directory.appendingPathComponent("regular-file")
        try Data("not a directory".utf8).write(to: invalidDirectory)
        let store = try KeelStore(databaseURL: directory.appendingPathComponent("Keel.sqlite3"))
        let coordinator = KeelCoordinator(store: store)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = attachOffscreen(host)
        defer { window.close() }
        let factory = RecordingWebViewFactory(websiteDataStore: .nonPersistent())
        let browser = KeelBrowserController(contentView: host, coordinator: coordinator, store: store,
            webViewFactory: { factory.make(configuration: $0) }, media: RecordingMediaController(),
            uploadPresenter: NoopUploadPresenter(), downloadDestinationDirectory: invalidDirectory)
        var terminal: KeelDownloadSnapshot?
        browser.onDownloadSnapshotsChanged = { terminal = $0.first { $0.state.isTerminal } }
        browser.start()
        await browser.waitForIdleForTesting()
        browser.openTypedURL(fixture.url(path: "/attachment"))
        await browser.waitForIdleForTesting()
        try await waitUntil(timeout: 4) { terminal != nil }
        await browser.waitForIdleForTesting()
        guard case .failed = terminal?.state else { return XCTFail("Destination failure must remain visible") }
        XCTAssertNil(browser.activePageFailureForTesting())
        let state = await coordinator.state()
        XCTAssertEqual(state?.runtimeState.downloads.first?.state, .failed)
        XCTAssertEqual(state?.activePage?.status, .ready)
    }

    func testCertificateValidationRejectsAnUnverifiableServerTrust() throws {
        let (browser, directory) = try makeBrowser()
        defer { try? FileManager.default.removeItem(at: directory) }
        let space = URLProtectionSpace(
            host: "untrusted.invalid",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: ChallengeSender()
        )
        let completed = expectation(description: "certificate decision")

        browser.validateCertificate(challenge) { disposition, credential in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
            XCTAssertNil(credential)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
    }

    func testTechnicalFailureLeavesQueuedWorkUntouched() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeelStore(databaseURL: directory.appendingPathComponent("Keel.sqlite3"))
        let coordinator = KeelCoordinator(store: store)
        let first = try XCTUnwrap(URL(string: "https://first.invalid"))
        let queued = try XCTUnwrap(URL(string: "https://queued.invalid"))

        _ = try await coordinator.start()
        _ = try await coordinator.handle(KeelCoordinatorEvent.openTypedURL(first))
        _ = try await coordinator.handle(KeelCoordinatorEvent.addURLToQueue(queued))
        let stateBeforeFailure = await coordinator.state()
        let before = try XCTUnwrap(stateBeforeFailure).runtimeState.queue
        let active = try XCTUnwrap(stateBeforeFailure?.activePage)

        let result = try await coordinator.handle(
            KeelCoordinatorEvent.technicalFailure(pageID: active.id, navigationID: active.currentNavigationID)
        )
        let stateAfterFailure = await coordinator.state()
        let after = try XCTUnwrap(stateAfterFailure).runtimeState.queue

        XCTAssertEqual(result.disposition, KeelCoordinatorDisposition.applied)
        XCTAssertEqual(after, before)
        XCTAssertEqual(stateAfterFailure?.activePage?.status, KeelPageStatus.technicalFailure)
    }

    func testOffscreenBrowserHomeHasNoAttachedWebViewsWithUndoRetained() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeelStore(databaseURL: directory.appendingPathComponent("Keel.sqlite3"))
        let coordinator = KeelCoordinator(store: store)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let browser = KeelBrowserController(contentView: host, coordinator: coordinator, store: store)

        browser.start()
        await browser.waitForIdleForTesting()
        browser.handle(KeelCoordinatorEvent.openTypedURL(try XCTUnwrap(URL(string: "https://one.invalid"))))
        await browser.waitForIdleForTesting()
        browser.closeActivePage()
        await browser.waitForIdleForTesting()

        XCTAssertEqual(browser.liveWebViewCount, 1)
        XCTAssertFalse(containsWebView(host))
    }

    func testBrowserUsesAnInjectedNonPersistentStoreAndSuspendsUndoBeforeRestore() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeelStore(databaseURL: directory.appendingPathComponent("Keel.sqlite3"))
        let coordinator = KeelCoordinator(store: store)
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let factory = RecordingWebViewFactory(websiteDataStore: websiteDataStore)
        let media = RecordingMediaController()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let browser = KeelBrowserController(
            contentView: host,
            coordinator: coordinator,
            store: store,
            webViewFactory: { factory.make(configuration: $0) },
            media: media,
            uploadPresenter: NoopUploadPresenter()
        )

        browser.start()
        await browser.waitForIdleForTesting()
        browser.handle(KeelCoordinatorEvent.openTypedURL(try XCTUnwrap(URL(string: "https://one.invalid"))))
        await browser.waitForIdleForTesting()
        browser.closeActivePage()
        await browser.waitForIdleForTesting()

        XCTAssertTrue(factory.webViews.allSatisfy { $0.configuration.websiteDataStore === websiteDataStore })
        XCTAssertEqual(media.events, [.suspend])
        let closed = browser.debugSnapshotForTesting()
        XCTAssertEqual(closed.liveWebViewCount, 1)
        XCTAssertNotNil(closed.undoPageID)

        browser.handle(KeelCoordinatorEvent.restoreCloseUndo)
        await browser.waitForIdleForTesting()

        XCTAssertEqual(media.events, [.suspend, .resume])
        let restored = browser.debugSnapshotForTesting()
        XCTAssertEqual(restored.liveWebViewCount, 1)
        XCTAssertNotNil(restored.activePageID)
        XCTAssertNil(restored.undoPageID)
    }

    func testScriptedPopupPreservesOpenerThenClosesWithoutExceedingTwoViews() async throws {
        let fixture = try KeelOffscreenLoopbackFixture(routes: [
            "/opener": .init(body: """
            <!doctype html><title>Opener</title>
            <script>setTimeout(() => { const popup = window.open('about:blank', 'keel-detour'); setTimeout(() => popup.location.href = '/popup', 50); }, 0)</script>
            """),
            "/popup": .init(body: "<!doctype html><title>Popup</title>"),
        ])
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeelStore(databaseURL: directory.appendingPathComponent("Keel.sqlite3"))
        let coordinator = KeelCoordinator(store: store)
        let factory = RecordingWebViewFactory(websiteDataStore: .nonPersistent(), allowsScriptedPopups: true)
        let media = RecordingMediaController()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = attachOffscreen(host)
        defer { window.close() }
        let browser = KeelBrowserController(
            contentView: host,
            coordinator: coordinator,
            store: store,
            webViewFactory: { factory.make(configuration: $0) },
            media: media,
            uploadPresenter: NoopUploadPresenter()
        )

        browser.start()
        await browser.waitForIdleForTesting()
        browser.handle(KeelCoordinatorEvent.openTypedURL(fixture.url(path: "/opener")))
        await browser.waitForIdleForTesting()
        let opener = try XCTUnwrap(factory.webViews.first)
        try await waitForURL(opener, fixture.url(path: "/opener"))

        try await waitUntil { factory.webViews.count == 2 }
        await browser.waitForIdleForTesting()
        let detour = try XCTUnwrap(factory.webViews.last)
        try await waitForURL(detour, fixture.url(path: "/popup"))

        let openSnapshot = browser.debugSnapshotForTesting()
        XCTAssertEqual(openSnapshot.liveWebViewCount, 2)
        XCTAssertNotNil(openSnapshot.detourID)
        let hasOpener = try await detour.evaluateString("String(window.opener !== null)")
        XCTAssertEqual(hasOpener, "true")
        _ = try await detour.evaluateString("window.opener.document.title = 'callback received'; 'sent'")
        let callback = try await opener.evaluateString("document.title")
        XCTAssertEqual(callback, "callback received")

        let didClose = try await detour.evaluateString("window.close(); 'closed'")
        XCTAssertEqual(didClose, "closed")
        await browser.waitForIdleForTesting()
        try await waitUntil { browser.debugSnapshotForTesting().detourID == nil }

        let closedSnapshot = browser.debugSnapshotForTesting()
        XCTAssertEqual(closedSnapshot.liveWebViewCount, 1)
        XCTAssertNotNil(closedSnapshot.activePageID)
        XCTAssertEqual(media.events, [.suspend, .pause, .resume])
    }

    func testScriptedExternalPopupIsInterceptedBeforeDetourReservation() async throws {
        let fixture = try KeelOffscreenLoopbackFixture(routes: [
            "/external-popup": .init(body: """
            <!doctype html><title>External popup</title>
            <script>setTimeout(() => window.open('mailto:orders@example.com', 'external-app'), 0)</script>
            """),
        ])
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeelStore(databaseURL: directory.appendingPathComponent("Keel.sqlite3"))
        let coordinator = KeelCoordinator(store: store)
        let factory = RecordingWebViewFactory(websiteDataStore: .nonPersistent(), allowsScriptedPopups: true)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = attachOffscreen(host)
        defer { window.close() }
        let browser = KeelBrowserController(
            contentView: host,
            coordinator: coordinator,
            store: store,
            webViewFactory: { factory.make(configuration: $0) },
            media: RecordingMediaController(),
            uploadPresenter: NoopUploadPresenter()
        )
        let intercepted = expectation(description: "external popup intercepted")
        var receivedApproval: KeelExternalApplicationApproval?
        browser.onExternalApplicationApproval = { approval, completion in
            receivedApproval = approval
            completion(false)
            intercepted.fulfill()
        }

        browser.start()
        await browser.waitForIdleForTesting()
        browser.openTypedURL(fixture.url(path: "/external-popup"))
        await browser.waitForIdleForTesting()
        let opener = try XCTUnwrap(factory.webViews.first)
        try await waitForURL(opener, fixture.url(path: "/external-popup"))
        await fulfillment(of: [intercepted], timeout: 2)
        await browser.waitForIdleForTesting()

        XCTAssertEqual(receivedApproval?.target.scheme, "mailto")
        XCTAssertEqual(receivedApproval?.trigger, .automaticPage)
        XCTAssertEqual(factory.webViews.count, 1)
        let snapshot = browser.debugSnapshotForTesting()
        XCTAssertEqual(snapshot.liveWebViewCount, 1)
        XCTAssertNil(snapshot.detourID)
        XCTAssertFalse(snapshot.hasDetourReservation)
    }

    func testNamedPDFDownloadRetainsServerFilename() {
        XCTAssertEqual(
            KeelDownloadNaming.filename(
                suggestedFilename: "RoyalMail-postage.pdf",
                mimeType: "application/pdf"
            ),
            "RoyalMail-postage.pdf"
        )
    }

    func testLoopbackWKDownloadWritesContentDispositionPDFBytes() async throws {
        let expected = Data(repeating: 0xA5, count: 32 * 1_024)
        let fixture = try KeelOffscreenLoopbackFixture(routes: [
            "/postage": .init(
                headers: [
                    "Content-Type": "application/pdf",
                    "Content-Disposition": "attachment; filename=RoyalMail-postage.pdf",
                ],
                body: expected
            ),
        ])
        let downloadsDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: downloadsDirectory) }
        let finished = expectation(description: "PDF download finished")
        var terminal: KeelDownloadSnapshot?
        let manager = KeelDownloadManager(destinationDirectory: downloadsDirectory, lifecycleSink: { event in
            guard case let .finished(snapshot) = event else { return }
            terminal = snapshot
            finished.fulfill()
        })
        let probe = DownloadNavigationProbe(manager: manager)
        let webView = isolatedWebView()
        let window = attachOffscreen(webView)
        defer { window.close() }
        webView.navigationDelegate = probe

        webView.load(URLRequest(url: fixture.url(path: "/postage")))
        await fulfillment(of: [finished], timeout: 3)

        let snapshot = try XCTUnwrap(terminal)
        XCTAssertEqual(snapshot.state, .completed)
        XCTAssertEqual(snapshot.filename, "RoyalMail-postage.pdf")
        XCTAssertEqual(snapshot.receivedBytes, Int64(expected.count))
        let destination = try XCTUnwrap(snapshot.destinationURL)
        XCTAssertEqual(try Data(contentsOf: destination), expected)
    }

    func testWKDownloadContinuesAfterBrowserDiscardsItsSourceOwnership() async throws {
        let expected = Data(repeating: 0x5A, count: 256 * 1_024)
        let fixture = try KeelOffscreenLoopbackFixture(routes: [
            "/export": .init(
                headers: [
                    "Content-Type": "application/octet-stream",
                    "Content-Disposition": "attachment; filename=export.pdf",
                ],
                body: expected,
                bodyChunkSize: 8 * 1_024,
                bodyChunkDelay: 0.004
            ),
        ])
        defer { withExtendedLifetime(fixture) {} }
        let downloadsDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: downloadsDirectory) }
        let started = expectation(description: "download registered")
        let finished = expectation(description: "discarded-source download finished")
        var terminal: KeelDownloadSnapshot?
        var hasStarted = false
        let store = try KeelStore(databaseURL: downloadsDirectory.appendingPathComponent("Keel.sqlite3"))
        _ = try await store.apply([.replaceSettings(KeelSettings(keepsClosedPageReady: false))])
        let coordinator = KeelCoordinator(store: store)
        let factory = WeakRecordingWebViewFactory(websiteDataStore: .nonPersistent())
        var host: NSView? = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let browser = KeelBrowserController(
            contentView: try XCTUnwrap(host),
            coordinator: coordinator,
            store: store,
            webViewFactory: { factory.make(configuration: $0) },
            media: RecordingMediaController(),
            uploadPresenter: NoopUploadPresenter(),
            downloadDestinationDirectory: downloadsDirectory
        )
        var window: NSWindow? = attachOffscreen(try XCTUnwrap(host))
        host = nil
        browser.onDownloadSnapshotsChanged = { snapshots in
            guard let snapshot = snapshots.first else { return }
            if !hasStarted {
                hasStarted = true
                started.fulfill()
            }
            if snapshot.state.isTerminal {
                terminal = snapshot
                finished.fulfill()
            }
        }

        browser.start()
        await browser.waitForIdleForTesting()
        browser.handle(KeelCoordinatorEvent.openTypedURL(fixture.url(path: "/export")))
        await browser.waitForIdleForTesting()
        weak var sourceWebView: WKWebView?
        sourceWebView = factory.firstWebView
        XCTAssertNotNil(sourceWebView)
        await fulfillment(of: [started], timeout: 2)
        browser.closeActivePage()
        await browser.waitForIdleForTesting()

        let ownership = browser.debugSnapshotForTesting()
        XCTAssertEqual(ownership.liveWebViewCount, 0)
        XCTAssertEqual(ownership.pageContextCount, 0)
        XCTAssertEqual(ownership.delegateCount, 0)
        XCTAssertNil(ownership.activePageID)
        XCTAssertNotNil(ownership.undoPageID)
        window?.close()
        window = nil
        await fulfillment(of: [finished], timeout: 4)

        let snapshot = try XCTUnwrap(terminal)
        XCTAssertEqual(snapshot.state, .completed)
        let destination = try XCTUnwrap(snapshot.destinationURL)
        XCTAssertEqual(try Data(contentsOf: destination), expected)
    }

    func testFileInputForwardsRealOpenPanelRequestToInjectedPresenterWithoutShowingNSOpenPanel() async throws {
        let fixture = try KeelOffscreenLoopbackFixture(routes: [
            "/upload": .init(body: """
            <!doctype html><title>Upload</title>
            <input id="upload" type="file">
            """),
        ])
        defer { withExtendedLifetime(fixture) {} }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selectedFile = directory.appendingPathComponent("fixture.txt")
        try Data("uploaded through Keel".utf8).write(to: selectedFile)
        let store = try KeelStore(databaseURL: directory.appendingPathComponent("Keel.sqlite3"))
        let coordinator = KeelCoordinator(store: store)
        let factory = RecordingWebViewFactory(websiteDataStore: .nonPersistent())
        let uploadPresenter = RecordingUploadPresenter(selection: [selectedFile])
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = attachOffscreen(host)
        defer { window.close() }
        let browser = KeelBrowserController(
            contentView: host,
            coordinator: coordinator,
            store: store,
            webViewFactory: { factory.make(configuration: $0) },
            media: RecordingMediaController(),
            uploadPresenter: uploadPresenter
        )

        browser.start()
        await browser.waitForIdleForTesting()
        browser.handle(KeelCoordinatorEvent.openTypedURL(fixture.url(path: "/upload")))
        await browser.waitForIdleForTesting()
        let webView = try XCTUnwrap(factory.webViews.first)
        try await waitForURL(webView, fixture.url(path: "/upload"))
        try await waitForElement("#upload", in: webView)
        let clickResult: String
        do {
            clickResult = try await webView.evaluateString("document.querySelector('#upload').click(); 'clicked'")
        } catch {
            XCTFail("WebKit could not dispatch the offscreen file-input click: \(error)")
            return
        }
        XCTAssertEqual(clickResult, "clicked")
        try await waitUntil { uploadPresenter.callCount == 1 }

        XCTAssertTrue(try XCTUnwrap(uploadPresenter.presentedWindows.first) === window)
        XCTAssertEqual(uploadPresenter.requests, [.init(allowsMultipleSelection: false, allowsDirectories: false)])
        XCTAssertEqual(uploadPresenter.completedSelections, [[selectedFile]])
        // WebKit calls the delegate above, but deliberately refuses to populate a
        // file input after a synthetic JavaScript click. A visible trusted gesture
        // would be required to observe `input.files` and would violate this suite's
        // no-window rule.
    }

    func testInteractionStateRestoresNavigationAndScrollAfterNonRetainedUndo() async throws {
        let fixture = try KeelOffscreenLoopbackFixture(routes: [
            "/state": .init(body: """
            <!doctype html><title>State</title>
            <div id="scroll-target" style="height: 3000px"></div>
            """),
        ])
        defer { withExtendedLifetime(fixture) {} }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeelStore(databaseURL: directory.appendingPathComponent("Keel.sqlite3"))
        _ = try await store.apply([.replaceSettings(KeelSettings(keepsClosedPageReady: false))])
        let coordinator = KeelCoordinator(store: store)
        let factory = RecordingWebViewFactory(websiteDataStore: .nonPersistent())
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = attachOffscreen(host)
        window.setContentSize(NSSize(width: 640, height: 480))
        defer { window.close() }
        let browser = KeelBrowserController(
            contentView: host,
            coordinator: coordinator,
            store: store,
            webViewFactory: { factory.make(configuration: $0) },
            media: RecordingMediaController(),
            uploadPresenter: NoopUploadPresenter()
        )

        browser.start()
        await browser.waitForIdleForTesting()
        browser.handle(KeelCoordinatorEvent.openTypedURL(fixture.url(path: "/state")))
        await browser.waitForIdleForTesting()
        let original = try XCTUnwrap(factory.webViews.first)
        try await waitForURL(original, fixture.url(path: "/state"))
        try await waitForElement("#scroll-target", in: original)
        try await waitUntil { !original.isLoading }
        let configured: String
        do {
            configured = try await original.evaluateString("""
            void document.body.offsetHeight;
            window.scrollTo(0, 900);
            'configured'
            """)
        } catch {
            XCTFail("WebKit could not set the scroll state: \(error)")
            return
        }
        XCTAssertEqual(configured, "configured")
        try await Task.sleep(for: .milliseconds(500))
        let originalScroll = try await original.evaluateString("String(window.scrollY)")
        XCTAssertEqual(originalScroll, "900")

        browser.closeActivePage()
        await browser.waitForIdleForTesting()
        XCTAssertEqual(browser.debugSnapshotForTesting().liveWebViewCount, 0)

        browser.handle(KeelCoordinatorEvent.restoreCloseUndo)
        await browser.waitForIdleForTesting()
        try await waitUntil { factory.webViews.count == 2 }
        let restored = factory.webViews[1]
        try await waitForURL(restored, fixture.url(path: "/state"))
        try await waitForElement("#scroll-target", in: restored)
        try await Task.sleep(for: .milliseconds(300))
        let state: String
        do {
            state = try await restored.evaluateString("""
            JSON.stringify({
              scrollY: Math.round(window.scrollY)
            })
            """)
        } catch {
            XCTFail("WebKit could not read the restored scroll state: \(error)")
            return
        }

        XCTAssertEqual(state, #"{"scrollY":900}"#)
    }

    func testFourLoopbackDownloadsFinishWithOneTerminalPublishEach() async throws {
        let payload = Data(repeating: 0xCC, count: 16 * 1_024)
        let routes = Dictionary(uniqueKeysWithValues: (0 ..< 4).map { index in
            (
                "/export-\(index)",
                KeelOffscreenLoopbackFixture.Response(
                    headers: [
                        "Content-Type": "application/pdf",
                        "Content-Disposition": "attachment; filename=export-\(index).pdf",
                    ],
                    body: payload
                )
            )
        })
        let fixture = try KeelOffscreenLoopbackFixture(routes: routes)
        let downloadsDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: downloadsDirectory) }
        let allFinished = expectation(description: "four terminal download updates")
        allFinished.expectedFulfillmentCount = 4
        allFinished.assertForOverFulfill = true
        var terminalIDs = Set<UUID>()
        let manager = KeelDownloadManager(destinationDirectory: downloadsDirectory, lifecycleSink: { event in
            guard case let .finished(snapshot) = event else { return }
            XCTAssertTrue(terminalIDs.insert(snapshot.id).inserted)
            allFinished.fulfill()
        })
        let webViews = (0 ..< 4).map { _ in isolatedWebView() }
        let windows = webViews.map(attachOffscreen)
        defer { windows.forEach { $0.close() } }
        let probes = webViews.map { _ in DownloadNavigationProbe(manager: manager) }
        for (index, webView) in webViews.enumerated() {
            webView.navigationDelegate = probes[index]
        }

        let startedAt = Date()
        for index in 0 ..< 4 {
            webViews[index].load(URLRequest(url: fixture.url(path: "/export-\(index)")))
        }
        await fulfillment(of: [allFinished], timeout: 4)

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        let snapshots = manager.snapshots
        XCTAssertEqual(snapshots.count, 4)
        XCTAssertEqual(Set(snapshots.map(\.filename)), Set((0 ..< 4).map { "export-\($0).pdf" }))
        XCTAssertTrue(snapshots.allSatisfy { $0.state == .completed && $0.receivedBytes == Int64(payload.count) })
    }

    private func isolatedWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
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

    private func waitForURL(_ webView: WKWebView, _ url: URL) async throws {
        try await waitUntil { webView.url == url }
    }

    private func waitForElement(_ selector: String, in webView: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let found = try? await webView.evaluateString("String(Boolean(document.querySelector(\(selector.debugDescription))))")
            if found == "true" { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WaitError.timedOut
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                throw WaitError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeBrowser() throws -> (KeelBrowserController, URL) {
        let directory = try temporaryDirectory()
        let store = try KeelStore(databaseURL: directory.appendingPathComponent("Keel.sqlite3"))
        return (
            KeelBrowserController(
                contentView: NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480)),
                coordinator: KeelCoordinator(store: store),
                store: store
            ),
            directory
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KeelWebOffscreenIntegrationMatrixTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func containsWebView(_ view: NSView) -> Bool {
        view is WKWebView || view.subviews.contains(where: containsWebView)
    }
}

@MainActor
private final class NavigationProbe: NSObject, WKNavigationDelegate {
    var onStart: (() -> Void)?
    var onFinish: (() -> Void)?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        onStart?()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        onFinish?()
    }
}

@MainActor
private final class DownloadNavigationProbe: NSObject, WKNavigationDelegate {
    private let manager: KeelDownloadManager

    init(manager: KeelDownloadManager) {
        self.manager = manager
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(.download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        manager.register(download: download, sourceURL: navigationResponse.response.url)
    }
}

@MainActor
private final class RecordingWebViewFactory {
    let websiteDataStore: WKWebsiteDataStore
    let allowsScriptedPopups: Bool
    private(set) var webViews: [WKWebView] = []

    init(websiteDataStore: WKWebsiteDataStore, allowsScriptedPopups: Bool = false) {
        self.websiteDataStore = websiteDataStore
        self.allowsScriptedPopups = allowsScriptedPopups
    }

    func make(configuration: WKWebViewConfiguration) -> WKWebView {
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = allowsScriptedPopups
        let webView = KeelWebViewFactory.make(
            configuration: configuration,
            websiteDataStore: websiteDataStore
        )
        webViews.append(webView)
        return webView
    }
}

/// Records creation without retaining the source view. BrowserController owns the view
/// until its discard path clears the registry, delegate, and page-context maps.
@MainActor
private final class WeakRecordingWebViewFactory {
    private final class Reference {
        weak var webView: WKWebView?

        init(_ webView: WKWebView) {
            self.webView = webView
        }
    }

    let websiteDataStore: WKWebsiteDataStore
    private var references: [Reference] = []

    init(websiteDataStore: WKWebsiteDataStore) {
        self.websiteDataStore = websiteDataStore
    }

    var firstWebView: WKWebView? {
        references.first?.webView
    }

    func make(configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = KeelWebViewFactory.make(
            configuration: configuration,
            websiteDataStore: websiteDataStore
        )
        references.append(Reference(webView))
        return webView
    }
}

@MainActor
private final class RecordingMediaController: KeelMediaControlling {
    enum Event: Equatable {
        case suspend
        case pause
        case resume
    }

    private(set) var events: [Event] = []

    func pauseBeforeDetour(in webView: WKWebView, performDetour: @escaping @MainActor @Sendable () -> Void) {
        events.append(.suspend)
        performDetour()
    }

    func pauseBeforeDiscard(in webView: WKWebView, performDiscard: @escaping @MainActor @Sendable () -> Void) {
        events.append(.pause)
        performDiscard()
    }

    func resumeAfterDetour(in webView: WKWebView, completion: (@MainActor @Sendable () -> Void)?) {
        events.append(.resume)
        completion?()
    }
}

@MainActor
private final class NoopUploadPresenter: KeelUploadPresenting {
    func present(
        parameters: WKOpenPanelParameters,
        in window: NSWindow?,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        completionHandler(nil)
    }
}

@MainActor
private final class RecordingUploadPresenter: KeelUploadPresenting {
    struct Request: Equatable {
        let allowsMultipleSelection: Bool
        let allowsDirectories: Bool
    }

    let selection: [URL]
    private(set) var callCount = 0
    private(set) var presentedWindows: [NSWindow?] = []
    private(set) var completedSelections: [[URL]?] = []
    private(set) var requests: [Request] = []

    init(selection: [URL]) {
        self.selection = selection
    }

    func present(
        parameters: WKOpenPanelParameters,
        in window: NSWindow?,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        callCount += 1
        presentedWindows.append(window)
        requests.append(
            Request(
                allowsMultipleSelection: parameters.allowsMultipleSelection,
                allowsDirectories: parameters.allowsDirectories
            )
        )
        completedSelections.append(selection)
        completionHandler(selection)
    }
}

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

private extension WKWebView {
    @MainActor
    func evaluateString(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            evaluateJavaScript(source) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result = result as? String {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: EvaluationError.unexpectedResult)
                }
            }
        }
    }
}

private enum EvaluationError: Error {
    case unexpectedResult
}

private enum WaitError: Error {
    case timedOut
}

private actor FailingHistoryPersistence: KeelHistoryPersisting {
    let store: KeelStore
    var failing = true
    var titleFailing = true
    init(store: KeelStore) { self.store = store }
    func setFailing(_ value: Bool) { failing = value; titleFailing = value }
    func setTitleFailing(_ value: Bool) { titleFailing = value }
    func recordHistoryVisit(_ event: HistoryVisitEvent) async throws -> HistoryVisit {
        if failing { throw NSError(domain: "secret SQL and URL", code: 123) }
        return try await store.recordHistoryVisit(event)
    }
    func updateHistoryTitle(visitID: UUID, title: String?) async throws {
        if titleFailing { throw NSError(domain: "secret title", code: 123) }
        try await store.updateHistoryTitle(visitID: visitID, title: title)
    }
}
