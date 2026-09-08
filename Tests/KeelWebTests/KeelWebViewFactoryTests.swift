import Testing
import WebKit
@testable import KeelWeb

@MainActor
struct KeelWebViewFactoryTests {
    @Test("factory uses Keel's shared persistent website data store")
    func usesSharedWebsiteDataStore() {
        let configuration = WKWebViewConfiguration()
        let webView = KeelWebViewFactory.make(configuration: configuration)

        #expect(webView.configuration.websiteDataStore === KeelWebsiteDataStore.shared)
    }

    @Test("factory accepts an isolated WebKit data store for matrix runs")
    func acceptsInjectedWebsiteDataStore() {
        let isolatedDataStore = WKWebsiteDataStore.nonPersistent()
        let popupConfiguration = WKWebViewConfiguration()
        popupConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = KeelWebViewFactory.make(
            configuration: popupConfiguration,
            websiteDataStore: isolatedDataStore
        )

        #expect(webView.configuration.websiteDataStore === isolatedDataStore)
        #expect(webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
    }

    @Test("factory keeps a supplied popup configuration while applying Keel defaults")
    func preservesSuppliedConfiguration() {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = KeelWebViewFactory.make(configuration: configuration)

        #expect(webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(webView.configuration.websiteDataStore === KeelWebsiteDataStore.shared)
        #expect(webView.configuration.applicationNameForUserAgent == KeelWebViewFactory.safariCompatibilityToken)
    }

    @Test("factory suspends inactive WebKit work for retained Undo")
    func suspendsInactiveWebViews() {
        let webView = KeelWebViewFactory.make(websiteDataStore: .nonPersistent())

        #expect(webView.configuration.preferences.inactiveSchedulingPolicy == .suspend)
    }

    @Test("Safari compatibility token preserves the proven Safari-shaped format")
    func usesProvenSafariCompatibilityToken() {
        #expect(
            KeelWebViewFactory.compatibilityToken(safariVersion: "26.5", fallbackVersion: "26.4")
                == "Version/26.5 Safari/605.1.15 Keel/0.1"
        )
    }

    @Test("Safari compatibility token falls back to the macOS version")
    func fallsBackWhenSafariMetadataIsUnavailable() {
        #expect(
            KeelWebViewFactory.compatibilityToken(safariVersion: nil, fallbackVersion: "26.4")
                == "Version/26.4 Safari/605.1.15 Keel/0.1"
        )
        #expect(
            KeelWebViewFactory.compatibilityToken(safariVersion: "  ", fallbackVersion: "26.4")
                == "Version/26.4 Safari/605.1.15 Keel/0.1"
        )
    }

    @Test("factory leaves page scrollbars under WebKit and system control")
    func doesNotInjectScrollbarStyles() {
        let webView = KeelWebViewFactory.make(websiteDataStore: .nonPersistent())
        #expect(webView.configuration.userContentController.userScripts.isEmpty)
    }
}
