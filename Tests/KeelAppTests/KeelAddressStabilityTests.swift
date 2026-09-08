import AppKit
import KeelStore
import XCTest
@testable import KeelApp

@MainActor
final class KeelAddressStabilityTests: XCTestCase {
    func testLateRowsPreserveEnqueueAction() {
        let palette = KeelAddressPaletteController()
        palette.updateQuery("query")
        _ = palette.performKeyboardCommandForTesting("moveDown:")
        palette.setSuggestions([row("a")], forQueryGeneration: palette.queryGeneration)
        XCTAssertEqual(palette.selectedActionForTesting, "enqueue")
        var submitted = false
        palette.onSubmit = { if case .enqueue(query: "query") = $0 { submitted = true } }
        _ = palette.performKeyboardCommandForTesting("insertNewline:")
        XCTAssertTrue(submitted)
    }

    func testReorderRemovalAndDuplicateIDsPreserveExactSelectedDestination() {
        let palette = KeelAddressPaletteController()
        palette.updateQuery("query")
        palette.setSuggestions([row("a"), row("b")], forQueryGeneration: palette.queryGeneration)
        _ = palette.performKeyboardCommandForTesting("moveUp:")
        palette.setSuggestions([row("b"), row("a")], forQueryGeneration: palette.queryGeneration)
        XCTAssertEqual(palette.selectedSuggestionIDForTesting, "b")
        palette.setSuggestions([.init(id: "b", historyURLID: 99, title: "Changed", address: "https://changed.invalid")],
            forQueryGeneration: palette.queryGeneration)
        palette.setSuggestions([row("c"), row("c")], forQueryGeneration: palette.queryGeneration)
        XCTAssertEqual(palette.visibleSuggestionIDsForTesting, ["b", "c"])
        var destination: String?
        palette.onSubmit = { if case let .openSuggestion(row, _) = $0 { destination = row.address } }
        _ = palette.performKeyboardCommandForTesting("insertNewline:")
        XCTAssertEqual(destination, "https://b.invalid/path")
    }

    func testDismissAndImmediateReopenRejectOldRows() {
        let palette = KeelAddressPaletteController()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 600))
        palette.present(over: host, initialQuery: "old")
        let old = palette.queryGeneration
        palette.dismiss(notify: false)
        palette.present(over: host, initialQuery: "new")
        palette.setSuggestions([row("stale")], forQueryGeneration: old)
        XCTAssertTrue(palette.isPresented)
        XCTAssertEqual(palette.visibleSuggestionIDsForTesting, [])
        palette.dismiss(notify: false)
    }

    func testControlledProviderRejectsOldQueryAfterNewAndAfterCancellation() async {
        let provider = DelayedHistoryProvider()
        let presenter = KeelAddressSuggestionPresenter(lookup: { await provider.lookup($0) })
        var received: [Int] = []
        presenter.onSuggestions = { _, generation, _ in received.append(generation) }
        presenter.queryDidChange("old", generation: 1)
        await provider.waitForRequest("old")
        presenter.queryDidChange("new", generation: 2)
        await provider.waitForRequest("new")
        provider.resolve("new")
        await presenter.waitForIdleForTesting()
        provider.resolve("old")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(received, [2])
        presenter.queryDidChange("dismissed", generation: 3)
        await provider.waitForRequest("dismissed")
        presenter.cancelPendingWork()
        provider.resolve("dismissed")
        await presenter.waitForIdleForTesting()
        XCTAssertEqual(received, [2])
        presenter.queryDidChange("", generation: 4)
        XCTAssertEqual(received, [2, 4])
    }

    private func row(_ id: String) -> KeelAddressPaletteSuggestion {
        .init(id: id, historyURLID: 1, title: id, address: "https://\(id).invalid/path")
    }
}

@MainActor
private final class DelayedHistoryProvider {
    private var requests: [String: CheckedContinuation<[HistorySuggestion], Never>] = [:]
    func lookup(_ query: String) async -> [HistorySuggestion] {
        await withCheckedContinuation { requests[query] = $0 }
    }
    func waitForRequest(_ query: String) async {
        while requests[query] == nil { await Task.yield() }
    }
    func resolve(_ query: String) { requests.removeValue(forKey: query)?.resume(returning: []) }
}
