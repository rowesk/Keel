import AppKit
import Foundation
import KeelFoundation
import KeelUI
import KeelWeb
import SwiftUI
import WebKit

@MainActor
enum FoundationProbe {
    private static let markerName = ".keel-foundation-replacement-probe"
    private static let cookieName = "KeelFoundationReplacementProbe"

    static func run() async {
        let environment = ProcessInfo.processInfo.environment
        let phase = environment["KEEL_PROBE_PHASE"] ?? "inspect"
        let token = environment["KEEL_PROBE_TOKEN"] ?? "inspect"
        let paths: KeelPaths

        do {
            paths = try KeelPathProvider.paths()
            try FileManager.default.createDirectory(
                at: paths.applicationSupportDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            fatalError("Could not resolve the production application-support path: \(error)")
        }

        precondition(KeelIdentity.bundleIdentifier == "com.chrisrowe.keel")
        precondition(paths.databaseURL.deletingLastPathComponent() == paths.applicationSupportDirectory)
        verifyRenderedHome()

        let markerURL = paths.applicationSupportDirectory.appending(path: markerName)
        switch phase {
        case "write":
            writeMarker(token, to: markerURL)
            await writeCookie(token)
            print("PASS replacement-write: signed app wrote container and WebKit profile markers")
        case "verify":
            verifyMarker(token, at: markerURL)
            await verifyAndDeleteCookie(token)
            print("PASS replacement-verify: bundle replacement preserved container and WebKit profile state")
        default:
            break
        }

        print("PASS foundation: production identity and container paths are stable")
        print("PASS home: Rendered Home contains zero WKWebViews")
    }

    private static func verifyRenderedHome() {
        let homeView = NSHostingView(rootView: HomeView())
        homeView.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        homeView.layoutSubtreeIfNeeded()
        precondition(!containsWebView(in: homeView))
    }

    private static func containsWebView(in view: NSView) -> Bool {
        view is WKWebView || view.subviews.contains(where: containsWebView)
    }

    private static func writeMarker(_ token: String, to url: URL) {
        do {
            try Data(token.utf8).write(to: url, options: .atomic)
        } catch {
            fatalError("Could not write the replacement marker: \(error)")
        }
    }

    private static func verifyMarker(_ token: String, at url: URL) {
        do {
            let storedToken = try String(contentsOf: url, encoding: .utf8)
            precondition(storedToken == token)
            try FileManager.default.removeItem(at: url)
        } catch {
            fatalError("Bundle replacement did not preserve the container marker: \(error)")
        }
    }

    private static func writeCookie(_ token: String) async {
        let webView = makeProbeWebView()
        guard let cookie = HTTPCookie(properties: [
            .domain: "keel-probe.invalid",
            .path: "/",
            .name: cookieName,
            .value: token,
            .secure: "TRUE",
            .expires: Date.now.addingTimeInterval(300)
        ]) else {
            fatalError("Could not create the WebKit replacement probe cookie")
        }

        await withCheckedContinuation { continuation in
            KeelWebsiteDataStore.shared.httpCookieStore.setCookie(cookie) {
                continuation.resume()
            }
        }

        let cookies = await allCookies()
        precondition(cookies.contains(where: { $0.name == cookieName && $0.value == token }))
        do {
            try await Task.sleep(for: .seconds(1))
        } catch {
            fatalError("The WebKit replacement probe was interrupted before profile flush: \(error)")
        }
        _ = webView.configuration.websiteDataStore
    }

    private static func verifyAndDeleteCookie(_ token: String) async {
        let webView = makeProbeWebView()
        let cookies = await allCookies()
        guard let cookie = cookies.first(where: { $0.name == cookieName && $0.value == token }) else {
            fatalError("Bundle replacement did not preserve the WebKit profile marker")
        }

        await withCheckedContinuation { continuation in
            KeelWebsiteDataStore.shared.httpCookieStore.delete(cookie) {
                continuation.resume()
            }
        }
        _ = webView.configuration.websiteDataStore
    }

    private static func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            KeelWebsiteDataStore.shared.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private static func makeProbeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = KeelWebsiteDataStore.shared
        return WKWebView(frame: .zero, configuration: configuration)
    }
}
