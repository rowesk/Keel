import WebKit

/// Holds navigation policy long enough to exercise restoration on a cold worker.
@MainActor
final class DelayedPolicyWebView: WKWebView {
    private var delayedDelegate: DelayedPolicyDelegate?

    override var navigationDelegate: (any WKNavigationDelegate)? {
        get { super.navigationDelegate }
        set {
            delayedDelegate = newValue.map { DelayedPolicyDelegate(target: $0) }
            super.navigationDelegate = delayedDelegate
        }
    }
}

@MainActor
private final class DelayedPolicyDelegate: NSObject, WKNavigationDelegate {
    private let target: any WKNavigationDelegate

    init(target: any WKNavigationDelegate) { self.target = target }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            target.webView?(webView, decidePolicyFor: action, decisionHandler: decisionHandler)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        target.webView?(webView, decidePolicyFor: response, decisionHandler: decisionHandler)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        target.webView?(webView, didStartProvisionalNavigation: navigation)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        target.webView?(webView, didCommit: navigation)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        target.webView?(webView, didFinish: navigation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        target.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        target.webView?(webView, didFail: navigation, withError: error)
    }
}
