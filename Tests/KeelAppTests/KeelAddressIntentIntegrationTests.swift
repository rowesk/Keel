import AppKit
import KeelCoordinator
import KeelFoundation
import KeelStore
import XCTest
@testable import KeelApp

@MainActor
final class KeelAddressIntentIntegrationTests: XCTestCase {
    func testReturnAndCommandReturnThroughRealPaletteDelegateAndCoordinator() async throws {
        for surface in ["empty", "queued", "resume", "parked", "active"] {
            for suggestion in [false, true] {
                for enqueue in [false, true] {
                    try await check(surface: surface, suggestion: suggestion, enqueue: enqueue)
                }
            }
        }
    }

    private func check(surface: String, suggestion: Bool, enqueue: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KeelStore(paths: KeelPaths(applicationSupportDirectory: directory))
        let target = URL(string: "https://selected.invalid/destination")!
        let original = URL(string: "https://unfinished.invalid/form")!
        let waiting = URL(string: "https://waiting.invalid/first")!
        let sessionID = UUID()
        _ = try await store.apply([.upsertSession(BrowsingSession(id: sessionID, startedAt: .now))])
        _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: target, visitedAt: .now,
            browsingSessionID: sessionID, source: .typedAddress))
        let matches = try await store.addressSuggestions(for: "selected")
        let match = try XCTUnwrap(matches.suggestions.first)
        if surface != "empty" { _ = try await store.apply([.captureQueuedDestination(waiting)]) }
        if surface == "resume" {
            _ = try await store.apply([.replaceResumeCheckpoint(ResumeCheckpoint(url: original,
                sessionID: sessionID, savedAt: .now))])
        }
        let palette = KeelAddressPaletteController()
        let delegate = KeelApplicationDelegate(makeStore: { store }, addressPalette: palette)
        try delegate.configureProductionApp(presentsWindow: false)
        try await wait(delegate) { $0.surface == .home }
        if surface == "active" || surface == "parked" {
            delegate.submitAddressPalette(.open(query: original.absoluteString))
            try await wait(delegate) { $0.activePage?.url == original }
            if surface == "parked" {
                delegate.performChromeCommand(.showHome)
                try await wait(delegate) { $0.surface == .home }
            }
        }
        let before = try XCTUnwrap(delegate.coordinatorState)
        palette.updateQuery(target.absoluteString)
        if suggestion {
            palette.setSuggestions([KeelAddressPaletteSuggestion(id: "selected", historyURLID: match.historyURLID,
                title: "Selected", address: target.absoluteString)], forQueryGeneration: palette.queryGeneration,
                defaultSelection: .firstSuggestion)
        }
        if suggestion {
            // A refresh removes the chosen row and introduces a different URL.
            // Return must still submit the visible retained selection.
            palette.setSuggestions([KeelAddressPaletteSuggestion(id: "replacement", historyURLID: match.historyURLID + 1000,
                title: "Other result", address: "https://replacement.invalid/")],
                forQueryGeneration: palette.queryGeneration)
            XCTAssertEqual(palette.selectedSuggestionIDForTesting, "selected")
        } else {
            let stale = palette.queryGeneration
            palette.updateQuery("a rapid intermediate query")
            palette.updateQuery(target.absoluteString)
            palette.setSuggestions([KeelAddressPaletteSuggestion(id: "stale", historyURLID: match.historyURLID + 1000,
                title: "Old result", address: "https://stale.invalid/")], forQueryGeneration: stale,
                defaultSelection: .firstSuggestion)
        }
        XCTAssertTrue(palette.performKeyboardCommandForTesting("insertNewline:", commandKey: enqueue))
        try await wait(delegate) { state in
            enqueue ? state.runtimeState.queue.last?.url == target : state.activePage?.url == target
        }
        let after = try XCTUnwrap(delegate.coordinatorState)
        let context = "\(surface), suggestion=\(suggestion), enqueue=\(enqueue)"
        if enqueue {
            XCTAssertEqual(after.surface, before.surface, context)
            // The intentionally invalid URL may fail while the queue write awaits
            // storage. Enqueue must preserve page/navigation identity, regardless
            // of that independent network status update.
            XCTAssertEqual(after.activePage?.id, before.activePage?.id, context)
            XCTAssertEqual(after.activePage?.sessionID, before.activePage?.sessionID, context)
            XCTAssertEqual(after.activePage?.currentNavigationID, before.activePage?.currentNavigationID, context)
            XCTAssertEqual(after.activePage?.url, before.activePage?.url, context)
            XCTAssertEqual(after.runtimeState.queue.map(\.url), before.runtimeState.queue.map(\.url) + [target], context)
        } else {
            XCTAssertEqual(after.surface, .page, context)
            XCTAssertEqual(after.activePage?.url, target, context)
            XCTAssertEqual(after.runtimeState.queue, before.runtimeState.queue, context)
            if let page = before.activePage {
                XCTAssertEqual(after.activePage?.id, page.id, context)
                XCTAssertEqual(after.activePage?.sessionID, page.sessionID, context)
            }
            if surface == "resume" { XCTAssertEqual(after.activePage?.sessionID, sessionID, context) }
        }
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }

    private func wait(_ delegate: KeelApplicationDelegate, until predicate: (KeelCoordinatorState) -> Bool) async throws {
        for _ in 0..<200 {
            if let state = delegate.coordinatorState, predicate(state) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The submitted intent did not reach the expected visible state")
    }
}
