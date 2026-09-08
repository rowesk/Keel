import AppKit
import KeelStore
import KeelWeb
import XCTest
@testable import KeelApp
@testable import KeelStore

@MainActor
final class KeelExternalApplicationHandoffTests: XCTestCase {
    func testTypedRTSPPromptsWithKeelAsTheSourceAndAllowsOnce() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let workspace = WorkspaceSpy()
        let presenter = PromptSpy()
        let controller = makeController(store: store, workspace: workspace, presenter: presenter)
        let url = try XCTUnwrap(URL(string: "rtsp://camera.example/live?token=private"))
        var completion: Bool?

        controller.request(approval(url: url, source: "Keel", trigger: .typed)) { completion = $0 }
        await waitUntil { presenter.pendingPrompt != nil }

        XCTAssertEqual(presenter.pendingPrompt?.source, "Keel")
        XCTAssertEqual(presenter.pendingPrompt?.scheme, "rtsp")
        XCTAssertFalse(presenter.promptContainsTargetURL)
        presenter.respond(.allowOnce)

        XCTAssertEqual(workspace.openedURLs, [url])
        XCTAssertEqual(completion, true)
    }

    func testPageActivatedMailtoPromptsWithSourceHostname() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let workspace = WorkspaceSpy()
        let presenter = PromptSpy()
        let controller = makeController(store: store, workspace: workspace, presenter: presenter)
        let url = try XCTUnwrap(URL(string: "mailto:orders@example.com"))

        controller.request(approval(url: url, source: "shop.example", trigger: .userActivatedPage)) { _ in }
        await waitUntil { presenter.pendingPrompt != nil }

        XCTAssertEqual(presenter.pendingPrompt?.source, "shop.example")
        XCTAssertEqual(presenter.pendingPrompt?.scheme, "mailto")
        presenter.respond(.cancel)
        XCTAssertTrue(workspace.openedURLs.isEmpty)
    }

    func testUnregisteredCustomSchemeShowsAnInWindowErrorWithoutOpeningAnything() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let workspace = WorkspaceSpy(resolvedTarget: nil)
        let presenter = PromptSpy()
        let controller = makeController(store: store, workspace: workspace, presenter: presenter)
        let url = try XCTUnwrap(URL(string: "unregistered-example://secret"))
        var completion: Bool?

        controller.request(approval(url: url, source: "shop.example", trigger: .automaticPage)) { completion = $0 }

        XCTAssertEqual(presenter.errors, [.noRegisteredHandler(scheme: "unregistered-example")])
        XCTAssertTrue(workspace.openedURLs.isEmpty)
        XCTAssertEqual(completion, false)
    }

    func testAutomaticRepeatsAreSuppressedWhileTheFirstPromptIsOpen() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let workspace = WorkspaceSpy()
        let presenter = PromptSpy()
        let controller = makeController(store: store, workspace: workspace, presenter: presenter)
        let url = try XCTUnwrap(URL(string: "mailto:orders@example.com"))
        let request = approval(url: url, source: "shop.example", trigger: .automaticPage)
        var secondCompletion: Bool?

        controller.request(request) { _ in }
        await waitUntil { presenter.pendingPrompt != nil }
        controller.request(request) { secondCompletion = $0 }

        XCTAssertEqual(presenter.presentCount, 1)
        XCTAssertEqual(secondCompletion, false)
        presenter.respond(.cancel)
    }

    func testCancelDoesNotOpenTheResolvedApplication() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let workspace = WorkspaceSpy()
        let presenter = PromptSpy()
        let controller = makeController(store: store, workspace: workspace, presenter: presenter)
        let url = try XCTUnwrap(URL(string: "mailto:orders@example.com"))
        var completion: Bool?

        controller.request(approval(url: url, source: "shop.example", trigger: .userActivatedPage)) { completion = $0 }
        await waitUntil { presenter.pendingPrompt != nil }
        presenter.respond(.cancel)

        XCTAssertTrue(workspace.openedURLs.isEmpty)
        XCTAssertEqual(completion, false)
    }

    func testAlwaysAllowPersistsTheSourceAndSchemePairThenOpens() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let workspace = WorkspaceSpy()
        let presenter = PromptSpy()
        let controller = makeController(store: store, workspace: workspace, presenter: presenter)
        let url = try XCTUnwrap(URL(string: "mailto:orders@example.com"))
        let request = approval(url: url, source: "shop.example", trigger: .userActivatedPage)

        controller.request(request) { _ in }
        await waitUntil { presenter.pendingPrompt != nil }
        presenter.respond(.alwaysAllow)
        await waitUntil { !workspace.openedURLs.isEmpty }

        let key = try ExternalApplicationApprovalKey(principal: .websiteHostname("shop.example"), scheme: "mailto")
        let isRemembered = try await store.hasExternalApplicationApproval(for: key)
        XCTAssertTrue(isRemembered)
        XCTAssertEqual(workspace.openedURLs, [url])
    }

    func testRememberedApprovalDoesNotPromptAgain() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let key = try ExternalApplicationApprovalKey(principal: .websiteHostname("shop.example"), scheme: "mailto")
        _ = try await store.apply([.rememberExternalApplicationApproval(key)])
        let workspace = WorkspaceSpy()
        let presenter = PromptSpy()
        let controller = makeController(store: store, workspace: workspace, presenter: presenter)
        let url = try XCTUnwrap(URL(string: "mailto:orders@example.com"))
        let pageID = UUID()
        let request = approval(
            url: url,
            source: "shop.example",
            trigger: .automaticPage,
            sourcePageID: pageID
        )

        controller.request(request) { _ in }
        await waitUntil { !workspace.openedURLs.isEmpty }
        var repeatedCompletion: Bool?
        controller.request(request) { repeatedCompletion = $0 }

        XCTAssertEqual(presenter.presentCount, 0)
        XCTAssertEqual(workspace.openedURLs, [url])
        XCTAssertEqual(repeatedCompletion, false)
    }

    func testCompletedAutomaticAllowOnceCannotLaunchTheSamePageTwice() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let workspace = WorkspaceSpy()
        let presenter = PromptSpy()
        let controller = makeController(store: store, workspace: workspace, presenter: presenter)
        let url = try XCTUnwrap(URL(string: "mailto:orders@example.com"))
        let request = approval(
            url: url,
            source: "shop.example",
            trigger: .automaticPage,
            sourcePageID: UUID()
        )

        controller.request(request) { _ in }
        await waitUntil { presenter.pendingPrompt != nil }
        presenter.respond(.allowOnce)
        XCTAssertEqual(workspace.openedURLs, [url])

        var repeatedCompletion: Bool?
        controller.request(request) { repeatedCompletion = $0 }
        XCTAssertEqual(presenter.presentCount, 1)
        XCTAssertEqual(workspace.openedURLs, [url])
        XCTAssertEqual(repeatedCompletion, false)
    }

    func testExplicitUserActivationRemainsUsableAfterAnAutomaticAttempt() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let workspace = WorkspaceSpy()
        let presenter = PromptSpy()
        let controller = makeController(store: store, workspace: workspace, presenter: presenter)
        let url = try XCTUnwrap(URL(string: "mailto:orders@example.com"))

        controller.request(approval(url: url, source: "shop.example", trigger: .automaticPage, sourcePageID: UUID())) { _ in }
        await waitUntil { presenter.pendingPrompt != nil }
        presenter.respond(.cancel)
        controller.request(approval(url: url, source: "shop.example", trigger: .userActivatedPage)) { _ in }
        await waitUntil { presenter.pendingPrompt != nil }

        XCTAssertEqual(presenter.presentCount, 2)
        presenter.respond(.cancel)
    }

    func testPresentationRequestsAVisibleWindowThroughTheInjectedProvider() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let workspace = WorkspaceSpy()
        let presenter = PromptSpy()
        var presentationWindowRequests = 0
        let controller = KeelExternalApplicationHandoffController(
            store: store,
            workspace: workspace,
            promptPresenter: presenter,
            windowProvider: {
                presentationWindowRequests += 1
                return nil
            }
        )
        let url = try XCTUnwrap(URL(string: "mailto:orders@example.com"))

        controller.request(approval(url: url, source: "Keel", trigger: .typed)) { _ in }
        await waitUntil { presenter.pendingPrompt != nil }

        XCTAssertEqual(presentationWindowRequests, 1)
        presenter.respond(.cancel)
    }

    func testLaunchFailureShowsAnInWindowError() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let workspace = WorkspaceSpy(openError: HandoffFailure.failed)
        let presenter = PromptSpy()
        let controller = makeController(store: store, workspace: workspace, presenter: presenter)
        let url = try XCTUnwrap(URL(string: "mailto:orders@example.com"))
        var completion: Bool?

        controller.request(approval(url: url, source: "shop.example", trigger: .userActivatedPage)) { completion = $0 }
        await waitUntil { presenter.pendingPrompt != nil }
        presenter.respond(.allowOnce)

        XCTAssertEqual(presenter.errors, [.launchFailed(applicationName: "Mail")])
        XCTAssertEqual(completion, false)
    }

    func testJavaScriptStaysBlockedBeforeResolutionOrPresentation() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let workspace = WorkspaceSpy()
        let presenter = PromptSpy()
        let controller = makeController(store: store, workspace: workspace, presenter: presenter)
        let url = try XCTUnwrap(URL(string: "javascript:alert('private')"))
        var completion: Bool?

        controller.request(approval(url: url, source: "shop.example", trigger: .automaticPage, scheme: "javascript")) { completion = $0 }

        XCTAssertEqual(workspace.resolveCount, 0)
        XCTAssertEqual(presenter.presentCount, 0)
        XCTAssertEqual(completion, false)
    }

    private func makeController(
        store: KeelStore,
        workspace: WorkspaceSpy,
        presenter: PromptSpy
    ) -> KeelExternalApplicationHandoffController {
        KeelExternalApplicationHandoffController(
            store: store,
            workspace: workspace,
            promptPresenter: presenter,
            windowProvider: { nil }
        )
    }

    private func approval(
        url: URL,
        source: String,
        trigger: KeelExternalApplicationTrigger,
        scheme: String? = nil,
        sourcePageID: UUID? = nil
    ) -> KeelExternalApplicationApproval {
        KeelExternalApplicationApproval(
            sourceHostname: source,
            url: url,
            target: KeelExternalApplicationTarget(scheme: scheme ?? url.scheme ?? "unknown"),
            trigger: trigger,
            sourcePageID: sourcePageID
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0 ..< 100 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for condition")
    }
}

@MainActor
private final class WorkspaceSpy: KeelExternalApplicationWorkspace {
    let resolvedTarget: KeelExternalApplicationResolvedTarget?
    let openError: Error?
    private(set) var resolveCount = 0
    private(set) var openedURLs: [URL] = []

    init(
        resolvedTarget: KeelExternalApplicationResolvedTarget? = KeelExternalApplicationResolvedTarget(
            applicationURL: URL(fileURLWithPath: "/Applications/Mail.app"),
            applicationName: "Mail",
            bundleIdentifier: "com.apple.mail"
        ),
        openError: Error? = nil
    ) {
        self.resolvedTarget = resolvedTarget
        self.openError = openError
    }

    func resolveApplication(for _: URL) -> KeelExternalApplicationResolvedTarget? {
        resolveCount += 1
        return resolvedTarget
    }

    func open(
        _ url: URL,
        with _: KeelExternalApplicationResolvedTarget,
        completion: @escaping @MainActor (Error?) -> Void
    ) {
        openedURLs.append(url)
        completion(openError)
    }
}

@MainActor
private final class PromptSpy: KeelExternalApplicationPromptPresenting {
    private(set) var pendingPrompt: KeelExternalApplicationPrompt?
    private(set) var presentCount = 0
    private(set) var errors: [KeelExternalApplicationHandoffError] = []
    private var pendingCompletion: (@MainActor (KeelExternalApplicationPromptDecision) -> Void)?

    var promptContainsTargetURL: Bool {
        guard let pendingPrompt else { return false }
        return pendingPrompt.source.contains("://")
            || pendingPrompt.scheme.contains("://")
            || pendingPrompt.applicationName.contains("://")
    }

    func present(
        _ prompt: KeelExternalApplicationPrompt,
        in _: NSWindow?,
        completion: @escaping @MainActor (KeelExternalApplicationPromptDecision) -> Void
    ) {
        presentCount += 1
        pendingPrompt = prompt
        pendingCompletion = completion
    }

    func presentError(
        _ error: KeelExternalApplicationHandoffError,
        in _: NSWindow?,
        completion: @escaping @MainActor () -> Void
    ) {
        errors.append(error)
        completion()
    }

    func respond(_ decision: KeelExternalApplicationPromptDecision) {
        let completion = pendingCompletion
        pendingCompletion = nil
        pendingPrompt = nil
        completion?(decision)
    }
}

private enum HandoffFailure: Error {
    case failed
}

private final class StoreFixture {
    let directory: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "KeelExternalHandoffTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        databaseURL = directory.appending(path: "Keel.sqlite3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
