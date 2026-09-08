import WebKit

@MainActor
public final class KeelMediaController {
    public init() {}

    public func pauseBeforeDetour(
        in webView: WKWebView,
        performDetour: @escaping @MainActor @Sendable () -> Void
    ) {
        webView.setAllMediaPlaybackSuspended(true, completionHandler: performDetour)
    }

    public func pauseBeforeDiscard(
        in webView: WKWebView,
        performDiscard: @escaping @MainActor @Sendable () -> Void
    ) {
        webView.pauseAllMediaPlayback(completionHandler: performDiscard)
    }

    public func resumeAfterDetour(
        in webView: WKWebView,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        webView.setAllMediaPlaybackSuspended(false, completionHandler: completion)
    }
}
