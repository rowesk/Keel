import AppKit
import XCTest
import KeelFoundation
@testable import KeelStore
import KeelCoordinator
import WebKit
@testable import KeelApp

@MainActor
final class KeelInteractionReceiptTests: XCTestCase {
    func testProductionReceiptsPreserveFocusAndRenderOverHomeAndPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = KeelPaths(applicationSupportDirectory: directory)
        let faults = ReceiptFaults()
        let store = try KeelStore(databaseURL: directory.appendingPathComponent("Keel.sqlite3"), now: { .now }, faultInjector: faults.inject)
        let delegate = KeelApplicationDelegate(makeStore: { store })
        var failures = 0
        delegate.onTransitionFailureForTesting = { failures += 1 }
        try delegate.configureProductionApp(presentsWindow: false, isolatedScenePaths: paths)
        try await wait { delegate.storedPreferencesApplied && delegate.coordinatorState?.surface == .home }
        let shell = try XCTUnwrap(delegate.shellViewForTesting)
        let window = try XCTUnwrap(shell.window)
        let receipt = delegate.interactionReceiptForTesting
        var announcements: [String] = []
        receipt.announce = { announcements.append($0) }
        let focus = window.firstResponder
        let fixtureHTML = "<html><body style='background:#f8f5ef;color:#26231c;font:20px Georgia;padding:70px'><h1>Local reading fixture</h1><p>This ordinary page stays in place while a destination joins the queue.</p><input placeholder='Unfinished page input'></body></html>"
        let server = try KeelReceiptLoopbackFixture(routes: ["/active": .init(body: fixtureHTML), "/next-destination": .init(body: "<h1>Next destination</h1>")])
        let nextURL = server.url(path: "/next-destination")
        delegate.handlePerformanceEvent(.addURLToQueue(nextURL))
        try await wait { receipt.message?.hasPrefix("Added to queue") == true }
        XCTAssertTrue(window.firstResponder === focus)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(delegate.coordinatorState?.surface, .home)
        for width in [720, 1120] {
            try await render(shell: shell, receipt: receipt.viewForTesting, width: width, name: "home-capture")
        }
        delegate.handlePerformanceEvent(.addURLToQueue(nextURL))
        try await wait { receipt.message?.hasPrefix("Already in queue") == true }
        XCTAssertEqual(announcements.count, 2)
        receipt.dismiss(generation: receipt.generation)
        faults.enabled = true
        delegate.handlePerformanceEvent(.addURLToQueue(URL(string: "about:blank#failed")!))
        try await wait { failures == 1 }
        XCTAssertNil(receipt.message)
        XCTAssertEqual(announcements.count, 2)
        XCTAssertEqual(delegate.coordinatorState?.runtimeState.queue.count, 1)
        faults.enabled = false

        delegate.handlePerformanceEvent(.openTypedURL(server.url(path: "/active")))
        try await wait { delegate.coordinatorState?.surface == .page }
        let pageView = try XCTUnwrap(webView(in: shell))

        var fixtureLoaded = false
        for _ in 0..<100 {
            if let text = try? await pageView.evaluateJavaScript("document.body.innerText") as? String,
               text.contains("Local reading fixture") { fixtureLoaded = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(fixtureLoaded)

        delegate.handlePerformanceEvent(.addURLToQueue(nextURL))
        try await wait { receipt.message?.hasPrefix("Already in queue") == true }
        for width in [720, 1120] {
            try await render(shell: shell, receipt: receipt.viewForTesting, width: width, name: "page-capture")
        }
        let page = try XCTUnwrap(delegate.coordinatorState?.activePage)
        delegate.handlePerformanceEvent(.closePage(pageID: page.id))
        try await wait { receipt.message == "Next: \(nextURL.absoluteString)" }
        XCTAssertEqual(delegate.coordinatorState?.activePage?.url, nextURL)
        try await render(shell: shell, receipt: receipt.viewForTesting, width: 1120, name: "page-next")
        let next = try XCTUnwrap(delegate.coordinatorState?.activePage)
        delegate.handlePerformanceEvent(.closePage(pageID: next.id))
        try await wait { receipt.message == "Finished. Queue empty." }
        try await render(shell: shell, receipt: receipt.viewForTesting, width: 1120, name: "home-empty")
        XCTAssertFalse(window.isVisible)
        receipt.dismiss(generation: receipt.generation)
    }

    private func wait(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for production receipt state", file: file, line: line)
        throw NSError(domain: "receipt-timeout", code: 1)
    }

    private func webView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.compactMap { webView(in: $0) }.first
    }

    private func render(shell: KeelShellView, receipt: NSView, width: Int, name: String) async throws {
        shell.window?.setContentSize(NSSize(width: width, height: width == 720 ? 480 : 700))
        try await Task.sleep(for: .milliseconds(350))
        shell.window?.layoutIfNeeded()
        shell.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(shell.bitmapImageRepForCachingDisplay(in: shell.bounds))
        shell.cacheDisplay(in: shell.bounds, to: bitmap)
        // AppKit cannot cache WebKit remote layers. Compose WebKit's own snapshot
        // and the native receipt bitmap at their actual shell coordinates.
        if name.hasPrefix("page"), let web = webView(in: shell) {
            let pageImage = try await web.takeSnapshot(configuration: nil)
            let nativeReceipt = receipt
            let receiptBitmap = try XCTUnwrap(nativeReceipt.bitmapImageRepForCachingDisplay(in: nativeReceipt.bounds))
            nativeReceipt.cacheDisplay(in: nativeReceipt.bounds, to: receiptBitmap)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            pageImage.draw(in: web.convert(web.bounds, to: shell))
            NSImage(cgImage: try XCTUnwrap(receiptBitmap.cgImage), size: nativeReceipt.bounds.size)
                .draw(in: nativeReceipt.convert(nativeReceipt.bounds, to: shell))
            NSGraphicsContext.restoreGraphicsState()
        }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/keel-receipt-production-\(name)-\(width).png"))
    }

    func testRapidCapturesReplaceReceiptAndRejectObsoleteDismissals() {
        let controller = KeelInteractionReceiptController()
        var announcements: [String] = []
        controller.announce = { announcements.append($0) }
        let url = URL(string: "https://example.com/one")!
        controller.capture(url: url, added: true)
        let first = controller.generation
        controller.capture(url: url, added: false)
        let second = controller.generation
        controller.dismiss(generation: first)
        XCTAssertEqual(controller.message, "Already in queue: https://example.com/one")
        controller.capture(url: url, added: false)
        XCTAssertEqual(announcements.count, 2)
        controller.dismiss(generation: second)
        XCTAssertNotNil(controller.message)
        controller.dismiss(generation: controller.generation)
        XCTAssertNil(controller.message)
    }

    func testOffscreenReceiptPlacementDoesNotChangeContentLayout() throws {
        let shell = KeelShellView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        let content = NSView()
        shell.addSubview(content)
        shell.pinToContentArea(content)
        shell.layoutSubtreeIfNeeded()
        let before = content.frame
        let controller = KeelInteractionReceiptController()
        controller.announce = { _ in }
        controller.install(in: shell)
        let cases: [(String, URL?)] = [
            ("capture", URL(string: "https://example.com/research")),
            ("next", URL(string: "https://example.com/next")),
            ("empty", nil),
        ]
        for (name, url) in cases {
            if name == "capture" { controller.capture(url: try XCTUnwrap(url), added: true) }
            else { controller.finish(nextURL: url) }
            shell.layoutSubtreeIfNeeded()
            XCTAssertEqual(content.frame, before)
            let bitmap = try XCTUnwrap(shell.bitmapImageRepForCachingDisplay(in: shell.bounds))
            shell.cacheDisplay(in: shell.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/keel-receipt-\(name).png"))
        }
        controller.dismiss(generation: controller.generation)
    }

    func testFinishNamesExactNextDestinationAndEmptyQueue() {
        let controller = KeelInteractionReceiptController()
        controller.announce = { _ in }
        controller.finish(nextURL: URL(string: "https://example.com/next"))
        XCTAssertEqual(controller.message, "Next: https://example.com/next")
        controller.finish(nextURL: nil)
        XCTAssertEqual(controller.message, "Finished. Queue empty.")
        controller.dismiss(generation: controller.generation)
    }
}

private final class ReceiptFaults: @unchecked Sendable {
    var enabled = false
    func inject(_ index: Int) throws {
        if enabled { throw NSError(domain: "receipt-store-failure", code: 1) }
    }
}
