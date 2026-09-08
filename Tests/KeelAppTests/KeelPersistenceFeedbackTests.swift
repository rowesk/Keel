import AppKit
import KeelCoordinator
import KeelFoundation
import KeelStore
import KeelWeb
import WebKit
import XCTest
@testable import KeelApp

@MainActor
final class KeelPersistenceFeedbackTests: XCTestCase {
    func testDownloadFailureExplainsPossibleAccessLossWithoutClaimingDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeelStore(paths: KeelPaths(applicationSupportDirectory: directory))
        let browser = KeelBrowserController(contentView: NSView(), coordinator: KeelCoordinator(store: store),
            store: store, websiteDataStore: .nonPersistent())
        let presenter = FeedbackPresenter()
        let delegate = KeelApplicationDelegate(errorPresenter: presenter)
        delegate.installBrowserCallbacks(browser, chromeController: KeelChromeController())

        browser.onDownloadFileUnavailable?()

        XCTAssertEqual(presenter.messages.count, 1)
        XCTAssertEqual(presenter.messages.first?.0, "Keel could not access this download")
        XCTAssertTrue(presenter.messages.first?.1.contains("may have been moved or deleted") == true)
        XCTAssertTrue(presenter.messages.first?.1.contains("may no longer have access") == true)
    }

    func testSuccessfulCommitRearmsTransitionFailureFeedback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeelStore(paths: KeelPaths(applicationSupportDirectory: directory))
        let coordinator = KeelCoordinator(store: store)
        let browser = KeelBrowserController(contentView: NSView(), coordinator: coordinator,
            store: store, websiteDataStore: .nonPersistent())
        let presenter = FeedbackPresenter()
        let delegate = KeelApplicationDelegate(errorPresenter: presenter)
        delegate.installBrowserCallbacks(browser, chromeController: KeelChromeController())
        let error = NSError(domain: "storage", code: 14)
        browser.onTransitionPersistenceFailure?(error)
        browser.onTransitionPersistenceFailure?(error)
        XCTAssertEqual(presenter.messages.count, 1)

        let result = try await coordinator.start()
        browser.onStateChanged?(try XCTUnwrap(result.state))
        browser.onTransitionPersistenceFailure?(error)
        XCTAssertEqual(presenter.messages.count, 2)
    }
}

@MainActor
private final class FeedbackPresenter: KeelAppErrorPresenting {
    var messages: [(String, String)] = []
    func present(message: String, informativeText: String, in window: NSWindow?) {
        messages.append((message, informativeText))
    }
}
