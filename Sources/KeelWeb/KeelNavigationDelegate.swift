import AppKit
import Foundation
import WebKit

@MainActor
final class KeelNavigationDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private weak var owner: KeelBrowserController?

    init(owner: KeelBrowserController) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receiveHistoryBridgeMessage(message)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        owner?.createPopup(from: webView, configuration: configuration, navigationAction: navigationAction)
    }

    func webViewDidClose(_ webView: WKWebView) {
        owner?.closeScriptedDetour(webView)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        owner?.handleNavigationAction(in: webView, action: navigationAction, decisionHandler: decisionHandler)
            ?? decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        owner?.handleNavigationResponse(in: webView, response: navigationResponse, decisionHandler: decisionHandler)
            ?? decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        owner?.navigationDidStart(in: webView, navigation: navigation)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        owner?.navigationDidCommit(in: webView, navigation: navigation)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        owner?.navigationDidFinish(in: webView, navigation: navigation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        owner?.navigationFailed(in: webView, navigation: navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        owner?.navigationFailed(in: webView, navigation: navigation, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        owner?.webContentProcessDidTerminate(webView)
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        owner?.validateCertificate(challenge, completionHandler: completionHandler)
            ?? completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        owner?.runOpenPanel(parameters: parameters, completionHandler: completionHandler) ?? completionHandler(nil)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        owner?.adopt(download: download, sourceURL: navigationAction.request.url)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        owner?.adopt(download: download, sourceURL: navigationResponse.response.url)
    }
}
