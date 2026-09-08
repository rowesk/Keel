@testable import KeelWeb
import WebKit
import XCTest

@MainActor
final class KeelHistoryBridgeTests: XCTestCase {
    func testAcceptsOnlyMainFrameHTTPHistoryLocations() {
        let change = KeelHistoryBridge.change(
            body: ["url": "https://shop.example/admin", "kind": "pushState"],
            isMainFrame: true
        )

        XCTAssertEqual(change?.url.absoluteString, "https://shop.example/admin")
        XCTAssertEqual(change?.kind, .pushState)
        XCTAssertNil(
            KeelHistoryBridge.change(
                body: ["url": "https://shop.example/admin", "kind": "pushState"],
                isMainFrame: false
            )
        )
        XCTAssertNil(
            KeelHistoryBridge.change(
                body: ["url": "file:///private/secret", "kind": "pushState"],
                isMainFrame: true
            )
        )
    }

    func testRepeatedInstallationReplacesTheHandlerWithoutDuplicatingTheBridgeScript() {
        let configuration = WKWebViewConfiguration()
        let firstReceiver = NoOpHistoryReceiver()
        let secondReceiver = NoOpHistoryReceiver()

        KeelHistoryBridge.install(in: configuration, receiver: firstReceiver)
        KeelHistoryBridge.install(in: configuration, receiver: secondReceiver)

        let scripts = configuration.userContentController.userScripts.filter {
            $0.source.contains("__keelHistoryLocationBridgeInstalled")
        }
        XCTAssertEqual(scripts.count, 1)
    }
}

@MainActor
private final class NoOpHistoryReceiver: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
}
