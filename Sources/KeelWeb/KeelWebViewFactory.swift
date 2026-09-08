import Foundation
import WebKit

@MainActor
public enum KeelWebViewFactory {
    /// A stable Safari-shaped marker appended to WebKit's native user agent.
    ///
    /// It comes from Safari's public bundle metadata, with the current macOS version
    /// as a fallback when Safari is unavailable.
    public static let safariCompatibilityToken: String = installedSafariCompatibilityToken()

    public static func make(
        configuration suppliedConfiguration: WKWebViewConfiguration? = nil,
        websiteDataStore: WKWebsiteDataStore = KeelWebsiteDataStore.shared,
        frame: CGRect = .zero
    ) -> WKWebView {
        let configuration = suppliedConfiguration ?? WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.applicationNameForUserAgent = safariCompatibilityToken
        configuration.preferences.inactiveSchedulingPolicy = .suspend

        let webView = WKWebView(frame: frame, configuration: configuration)
        // Swipe to go back, and the snapshot WebKit paints over the swap so a
        // cached page comes back without a blank frame first.
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    /// Captures only WebKit's public restoration data. Keel does not inspect or
    /// supplement it with page scripts because that would risk persisting secrets.
    public static func interactionState(of webView: WKWebView) -> Any? {
        webView.interactionState
    }

    public static func restoreInteractionState(_ interactionState: Any?, in webView: WKWebView) {
        webView.interactionState = interactionState
    }

    static func compatibilityToken(safariVersion: String?, fallbackVersion: String) -> String {
        guard let safariVersion else {
            return "Version/\(fallbackVersion) Safari/605.1.15 Keel/0.1"
        }

        let trimmedVersion = safariVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVersion.isEmpty else {
            return "Version/\(fallbackVersion) Safari/605.1.15 Keel/0.1"
        }

        return "Version/\(trimmedVersion) Safari/605.1.15 Keel/0.1"
    }

    private static func installedSafariCompatibilityToken() -> String {
        let safariPaths = [
            "/System/Applications/Safari.app",
            "/Applications/Safari.app",
        ]

        for path in safariPaths {
            guard let bundle = Bundle(path: path),
                  let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  !version.isEmpty else {
                continue
            }

            return compatibilityToken(safariVersion: version, fallbackVersion: operatingSystemVersion())
        }

        return compatibilityToken(safariVersion: nil, fallbackVersion: operatingSystemVersion())
    }

    private static func operatingSystemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

}
