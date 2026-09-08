import WebKit
import XCTest
@testable import KeelWeb

@MainActor
final class KeelMediaControllerTests: XCTestCase {
    func testDetourSuspensionCompletesBeforeTheCallerCanShowTheOverlay() async {
        let webView = offscreenWebView()
        let media = KeelMediaController()
        await withCheckedContinuation { continuation in
            media.pauseBeforeDetour(in: webView) {
                continuation.resume()
            }
        }

        let state = await mediaPlaybackState(of: webView)
        XCTAssertNotEqual(state, .playing)
    }

    func testDiscardPausesAnyPubliclyReportedPlaybackBeforeTheViewIsReleased() async {
        let webView = offscreenWebView()
        let media = KeelMediaController()
        await withCheckedContinuation { continuation in
            media.pauseBeforeDiscard(in: webView) {
                continuation.resume()
            }
        }

        let state = await mediaPlaybackState(of: webView)
        XCTAssertNotEqual(state, .playing)
    }

    private func offscreenWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func mediaPlaybackState(of webView: WKWebView) async -> WKMediaPlaybackState {
        await withCheckedContinuation { continuation in
            webView.requestMediaPlaybackState { state in
                continuation.resume(returning: state)
            }
        }
    }
}
