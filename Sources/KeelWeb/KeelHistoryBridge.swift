import Foundation
import WebKit

/// Reports only main-frame location changes that WebKit does not expose as document commits.
/// It never reads page fields, text, cookies, or response content.
@MainActor
enum KeelHistoryBridge {
    static let messageName = "keelHistoryLocationChanged"

    enum ChangeKind: String, Sendable {
        case pushState
        case replaceState
        case popState
        case hashNavigation
    }

    struct Change: Sendable {
        let url: URL
        let kind: ChangeKind
    }

    static func install(
        in configuration: WKWebViewConfiguration,
        receiver: WKScriptMessageHandler
    ) {
        let controller = configuration.userContentController
        // WebKit supplies popup configurations that can share this controller with the
        // opener. Replace only Keel's handler, then keep one exact bridge script.
        controller.removeScriptMessageHandler(forName: messageName)
        controller.add(WeakScriptMessageHandler(receiver), name: messageName)
        guard !controller.userScripts.contains(where: { $0.source == source }) else { return }
        controller.addUserScript(
            WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
    }

    static func change(from message: WKScriptMessage) -> Change? {
        guard message.name == messageName else { return nil }
        return change(body: message.body, isMainFrame: message.frameInfo.isMainFrame)
    }

    static func change(body: Any, isMainFrame: Bool) -> Change? {
        guard isMainFrame,
              let value = body as? [String: Any],
              let address = value["url"] as? String,
              let kindValue = value["kind"] as? String,
              let url = URL(string: address),
              let kind = ChangeKind(rawValue: kindValue),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return nil
        }
        return Change(url: url, kind: kind)
    }

    private static let source =
        """
        (() => {
          if (window.__keelHistoryLocationBridgeInstalled) return;
          Object.defineProperty(window, '__keelHistoryLocationBridgeInstalled', {
            value: true,
            configurable: false,
            enumerable: false
          });

          let previousURL = location.href;
          const report = (kind) => {
            const currentURL = location.href;
            if (currentURL === previousURL) return;
            previousURL = currentURL;
            window.webkit?.messageHandlers?.keelHistoryLocationChanged?.postMessage({
              url: currentURL,
              kind
            });
          };

          for (const [methodName, kind] of [['pushState', 'pushState'], ['replaceState', 'replaceState']]) {
            const original = history[methodName];
            history[methodName] = function(...argumentsList) {
              const result = Reflect.apply(original, this, argumentsList);
              queueMicrotask(() => report(kind));
              return result;
            };
          }

          addEventListener('popstate', () => report('popState'), true);
          addEventListener('hashchange', () => report('hashNavigation'), true);
        })();
        """
}

@MainActor
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var receiver: WKScriptMessageHandler?

    init(_ receiver: WKScriptMessageHandler) {
        self.receiver = receiver
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        receiver?.userContentController(userContentController, didReceive: message)
    }
}
