import AppKit
import KeelCoordinator
import KeelStore
import KeelWeb
import XCTest
@testable import KeelApp

@MainActor
final class KeelAddressPaletteTests: XCTestCase {
    func testPresentingOverAWideWindowLeavesTheWindowTheSizeTheUserChose() {
        let shell = KeelShellView()
        let controller = KeelWindowController(shellView: shell, permitsWindowPresentation: false)
        let window = try! XCTUnwrap(controller.window)
        window.layoutIfNeeded() // Keep unattended tests offscreen.

        // Wider than 720 / 0.52, the point at which the palette's maximum width
        // used to become a maximum width for the whole window.
        let chosen = NSRect(x: 100, y: 100, width: 1_600, height: 900)
        window.setFrame(chosen, display: false)
        window.layoutIfNeeded()

        let palette = KeelAddressPaletteController()
        palette.present(over: shell, initialQuery: "", contentGuide: shell.contentGuide)
        window.layoutIfNeeded()

        XCTAssertEqual(window.frame.width, chosen.width, accuracy: 0.5)
        XCTAssertEqual(window.frame.height, chosen.height, accuracy: 0.5)

        palette.dismiss(notify: false)
        controller.removeHiddenChromeDragMonitor()
        window.orderOut(nil)
    }

    func testThePanelSitsInTheMiddleOfThePageArea() {
        let shell = KeelShellView()
        let controller = KeelWindowController(shellView: shell, permitsWindowPresentation: false)
        let window = try! XCTUnwrap(controller.window)
        window.layoutIfNeeded() // Keep unattended tests offscreen.
        window.setFrame(NSRect(x: 100, y: 100, width: 1_200, height: 900), display: false)
        window.layoutIfNeeded()

        let palette = KeelAddressPaletteController()
        palette.present(over: shell, initialQuery: "", contentGuide: shell.contentGuide)
        window.layoutIfNeeded()

        let panel = palette.panelFrameForTesting
        let backdrop = palette.backdropFrameForTesting
        // Near enough the middle that it reads as centred, without demanding a
        // particular panel height.
        XCTAssertEqual(panel.midY, backdrop.height / 2, accuracy: 60)

        palette.dismiss(notify: false)
        controller.removeHiddenChromeDragMonitor()
        window.orderOut(nil)
    }

    func testEmbeddingOnHomeMovesTheFieldIntoHomeAndActivatesInPlace() {
        let shell = KeelShellView()
        let controller = KeelWindowController(shellView: shell, permitsWindowPresentation: false)
        let window = try! XCTUnwrap(controller.window)
        window.layoutIfNeeded() // Keep unattended tests offscreen.
        window.setFrame(NSRect(x: 100, y: 100, width: 1_120, height: 760), display: false)

        // Stand-ins for the two slots Home lays out: the capsule and the dropdown.
        let fieldSlot = NSView(frame: NSRect(x: 280, y: 300, width: 560, height: 52))
        let rowsSlot = NSView(frame: NSRect(x: 280, y: 100, width: 560, height: 200))
        shell.addSubview(fieldSlot)
        shell.addSubview(rowsSlot)

        let palette = KeelAddressPaletteController()
        palette.embed(fieldIn: fieldSlot)
        palette.embed(rowsIn: rowsSlot)
        XCTAssertTrue(palette.isEmbedded)
        XCTAssertFalse(palette.isPresented, "Embedding alone must not count as presenting")

        var changes = 0
        palette.onEmbeddedChange = { changes += 1 }
        palette.activateEmbedded(initialQuery: "", mode: .opensNow)
        window.layoutIfNeeded()

        XCTAssertTrue(palette.isEmbeddedActive)
        XCTAssertTrue(palette.isPresented)
        XCTAssertGreaterThan(changes, 0)
        // Open and Add to queue rows, plus the dropdown's padding.
        XCTAssertEqual(palette.embeddedRowsHeight, 2 * 38 + 1 + 10, accuracy: 0.5)
        XCTAssertEqual(palette.backdropFrameForTesting.size, .zero, "No floating backdrop while embedded")

        palette.dismiss(notify: false)
        XCTAssertFalse(palette.isEmbeddedActive)
        XCTAssertFalse(palette.isPresented)

        // Home goes away: everything returns to the floating panel and the
        // floating presentation works again.
        palette.unembedRows(from: rowsSlot)
        palette.unembedField(from: fieldSlot)
        XCTAssertFalse(palette.isEmbedded)
        palette.present(over: shell, initialQuery: "", contentGuide: shell.contentGuide)
        window.layoutIfNeeded()
        XCTAssertGreaterThan(palette.panelFrameForTesting.height, 52)

        palette.dismiss(notify: false)
        controller.removeHiddenChromeDragMonitor()
        window.orderOut(nil)
    }

    func testTheFieldStaysPutWhileSuggestionsArrive() {
        let shell = KeelShellView()
        let controller = KeelWindowController(shellView: shell, permitsWindowPresentation: false)
        let window = try! XCTUnwrap(controller.window)
        window.layoutIfNeeded() // Keep unattended tests offscreen.
        window.setFrame(NSRect(x: 100, y: 100, width: 1_200, height: 900), display: false)
        window.layoutIfNeeded()

        let palette = KeelAddressPaletteController()
        palette.present(over: shell, initialQuery: "", contentGuide: shell.contentGuide)
        window.layoutIfNeeded()
        let emptyTop = palette.panelFrameForTesting.maxY

        palette.updateQuery("news")
        palette.setSuggestions(
            [suggestion(id: "one"), suggestion(id: "two"), suggestion(id: "three")],
            forQueryGeneration: palette.queryGeneration
        )
        window.layoutIfNeeded()

        // The list grows downwards. Centring the panel instead would lift the
        // field half a row per suggestion, out from under the cursor.
        XCTAssertEqual(palette.panelFrameForTesting.maxY, emptyTop, accuracy: 0.5)
        XCTAssertGreaterThan(palette.panelFrameForTesting.height, 0)

        palette.dismiss(notify: false)
        controller.removeHiddenChromeDragMonitor()
        window.orderOut(nil)
    }

    func testAShortWindowKeepsThePanelClearOfTheToolbar() {
        let shell = KeelShellView()
        let controller = KeelWindowController(shellView: shell, permitsWindowPresentation: false)
        let window = try! XCTUnwrap(controller.window)
        window.layoutIfNeeded() // Keep unattended tests offscreen.
        window.setFrame(NSRect(x: 100, y: 100, width: 900, height: 480), display: false)
        window.layoutIfNeeded()

        let palette = KeelAddressPaletteController()
        palette.present(over: shell, initialQuery: "", contentGuide: shell.contentGuide)
        window.layoutIfNeeded()

        let panel = palette.panelFrameForTesting
        let backdrop = palette.backdropFrameForTesting
        XCTAssertLessThanOrEqual(panel.maxY, backdrop.height - 23)

        palette.dismiss(notify: false)
        controller.removeHiddenChromeDragMonitor()
        window.orderOut(nil)
    }

    func testTheBackdropDoesNotTintThePageBehindThePalette() {
        let backdrop = KeelPaletteBackdropView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let alpha = backdrop.layer?.backgroundColor?.alpha ?? 1

        // A scrim over the page made every site look grey while the palette was
        // open. Elevation comes from the panel shadow, not from dimming.
        XCTAssertEqual(alpha, 0, accuracy: 0.001)
    }

    func testClickingOutsideTheInvisibleBackdropStillDismisses() {
        let backdrop = KeelPaletteBackdropView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertIdentical(backdrop.hitTest(NSPoint(x: 10, y: 10)), backdrop)
    }

    func testNormalMultiWordSearchKeepsRawOpenSelected() {
        let palette = KeelAddressPaletteController()
        palette.updateQuery("write a listing")
        palette.setSuggestions([suggestion(id: "one")], forQueryGeneration: palette.queryGeneration)

        XCTAssertEqual(palette.selectedActionForTesting, "open")
        XCTAssertNil(palette.selectedSuggestionIDForTesting)
    }

    func testKeyboardMovesSelectionAndReturnOpensHighlightedSuggestion() {
        let palette = KeelAddressPaletteController()
        palette.updateQuery("shop")
        palette.setSuggestions(
            [suggestion(id: "one"), suggestion(id: "two")],
            forQueryGeneration: palette.queryGeneration,
            defaultSelection: .firstSuggestion
        )
        XCTAssertEqual(palette.selectedSuggestionIDForTesting, "one")

        XCTAssertTrue(palette.performKeyboardCommandForTesting("moveDown:"))
        XCTAssertEqual(palette.selectedSuggestionIDForTesting, "two")

        var submission: KeelAddressPaletteSubmission?
        palette.onSubmit = { submission = $0 }
        XCTAssertTrue(palette.performKeyboardCommandForTesting("insertNewline:"))

        guard case let .openSuggestion(selected, input)? = submission else {
            return XCTFail("Return did not open the highlighted History row")
        }
        XCTAssertEqual(selected.id, "two")
        XCTAssertEqual(input, "shop")
    }

    func testOptionReturnQueuesHighlightedSuggestion() {
        let palette = KeelAddressPaletteController()
        palette.updateQuery("shop")
        palette.setSuggestions(
            [suggestion(id: "one")],
            forQueryGeneration: palette.queryGeneration,
            defaultSelection: .firstSuggestion
        )

        var submission: KeelAddressPaletteSubmission?
        palette.onSubmit = { submission = $0 }
        XCTAssertTrue(palette.performKeyboardCommandForTesting("insertNewline:", optionKey: true))

        guard case let .enqueueSuggestion(selected, input)? = submission else {
            return XCTFail("Option Return did not queue the highlighted History row")
        }
        XCTAssertEqual(selected.id, "one")
        XCTAssertEqual(input, "shop")
    }

    func testIconReplacementDoesNotRebuildRowsOrLoseSelection() {
        let palette = KeelAddressPaletteController()
        palette.updateQuery("shop")
        palette.setSuggestions(
            [suggestion(id: "one"), suggestion(id: "two")],
            forQueryGeneration: palette.queryGeneration,
            defaultSelection: .firstSuggestion
        )
        XCTAssertTrue(palette.performKeyboardCommandForTesting("moveDown:"))

        let icon = NSImage(size: NSSize(width: 16, height: 16))
        palette.replaceSuggestionIcon(
            id: "two",
            image: icon,
            forQueryGeneration: palette.queryGeneration,
            duration: 0
        )

        XCTAssertEqual(palette.selectedSuggestionIDForTesting, "two")
        XCTAssertEqual(palette.currentQuery, "shop")
    }

    func testRowsResolvingToTheSamePlaceCollapseToOne() {
        let palette = KeelAddressPaletteController()
        palette.updateQuery("x.com")
        palette.setSuggestions(
            [
                KeelAddressPaletteSuggestion(id: "a", historyURLID: 1, title: "", address: "https://x.com"),
                KeelAddressPaletteSuggestion(id: "b", historyURLID: 2, title: "", address: "https://x.com/"),
                KeelAddressPaletteSuggestion(id: "c", historyURLID: 3, title: "", address: "http://www.x.com"),
                KeelAddressPaletteSuggestion(id: "d", historyURLID: 4, title: "", address: "https://x.com/home"),
            ],
            forQueryGeneration: palette.queryGeneration
        )

        XCTAssertEqual(palette.visibleSuggestionIDsForTesting, ["a", "d"])
    }

    func testReturnAlwaysOpensAndTheQueueIsOneModifierAwayWhateverIsWaiting() {
        XCTAssertEqual(KeelAddressPaletteMode.opensNow.primaryTitle, "Open")
        XCTAssertEqual(KeelAddressPaletteMode.opensNow.secondaryTitle, "Add to queue")

        // Work waiting changes nothing: "news" + Return still searches.
        let holding = KeelAddressPaletteMode.queuesBehind(count: 3)
        XCTAssertEqual(holding.primaryTitle, "Open")
        XCTAssertEqual(holding.secondaryTitle, "Add to queue")
    }

    func testReturnOnABareQueryOpensItEvenWhenHistoryHasAHostnameMatch() async {
        let presenter = KeelAddressSuggestionPresenter(
            lookup: { _ in [Self.historySuggestion(id: 1, hostname: "news.ycombinator.com")] },
            stableListDelay: .zero
        )
        var received: KeelAddressPaletteDefaultSelection?
        presenter.onSuggestions = { (_: [KeelAddressPaletteSuggestion], _: Int, selection: KeelAddressPaletteDefaultSelection) in
            received = selection
        }

        presenter.queryDidChange("news", generation: 1)
        await presenter.waitForIdleForTesting()

        XCTAssertEqual(received, .open)
    }

    func testPresenterRejectsAStaleGeneration() async {
        let presenter = KeelAddressSuggestionPresenter(
            lookup: { input in
                if input == "older" {
                    try await Task.sleep(for: .milliseconds(50))
                }
                return [Self.historySuggestion(id: input == "older" ? 1 : 2, hostname: input)]
            },
            stableListDelay: .zero
        )
        var received: [(String, Int)] = []
        presenter.onSuggestions = { (suggestions: [KeelAddressPaletteSuggestion], generation: Int, _: KeelAddressPaletteDefaultSelection) in
            received.append((suggestions.first?.id ?? "", generation))
        }

        presenter.queryDidChange("older", generation: 1)
        presenter.queryDidChange("newer", generation: 2)
        await presenter.waitForIdleForTesting()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, "history-2")
        XCTAssertEqual(received.first?.1, 2)
    }

    func testDelegateRoutesHistorySuggestionDuringDetourAndKeepsPaletteVisible() {
        let palette = KeelAddressPaletteController()
        let presenter = KeelAddressSuggestionPresenter(lookup: { _ in [] })
        let delegate = KeelApplicationDelegate(
            addressPalette: palette,
            addressSuggestionPresenter: presenter
        )
        let host = NSView()
        palette.present(over: host, initialQuery: "shop")
        var received: KeelCoordinatorEvent?
        presenter.onSuggestionAccepted = { received = $0 }

        delegate.submitAddressPalette(
            .openSuggestion(suggestion(id: "one"), input: "shop"),
            detourIsActiveOverride: true
        )

        guard case let .selectHistorySuggestion(historyURLID, typedInput, disposition)? = received else {
            return XCTFail("The delegate did not route the suggestion to the coordinator")
        }
        XCTAssertEqual(historyURLID, 1)
        XCTAssertEqual(typedInput, "shop")
        XCTAssertEqual(disposition, .open)
        XCTAssertTrue(palette.isPresented)
        palette.dismiss(notify: false)
    }

    func testSilentPaletteTransitionCancelsAnInFlightStoreLookup() async {
        var suggestionCallbackCount = 0
        let presenter = KeelAddressSuggestionPresenter(
            lookup: { _ in
                try await Task.sleep(for: .seconds(1))
                return [Self.historySuggestion(id: 1, hostname: "shop")]
            }
        )
        presenter.onSuggestions = { _, _, _ in
            suggestionCallbackCount += 1
        }
        let delegate = KeelApplicationDelegate(addressSuggestionPresenter: presenter)

        presenter.queryDidChange("shop", generation: 1)
        delegate.dismissAddressPaletteForTransition()
        await presenter.waitForIdleForTesting()

        XCTAssertEqual(suggestionCallbackCount, 0)
    }

    func testSilentPaletteTransitionCancelsFaviconDebounceBeforeAnyLoad() async {
        let transport = FaviconTransportProbe()
        let loader = KeelFaviconLoader(transport: transport)
        let presenter = KeelAddressSuggestionPresenter(
            lookup: { _ in [Self.historySuggestion(id: 1, hostname: "shop")] },
            faviconLoader: loader,
            stableListDelay: .seconds(1)
        )
        let suggestionsVisible = MainActorSignal()
        presenter.onSuggestions = { _, _, _ in
            suggestionsVisible.signal()
        }
        let delegate = KeelApplicationDelegate(addressSuggestionPresenter: presenter)

        presenter.queryDidChange("shop", generation: 1)
        await suggestionsVisible.wait()
        delegate.dismissAddressPaletteForTransition()
        await presenter.waitForIdleForTesting()

        XCTAssertEqual(transport.requestCount, 0)
    }

    func testDetourSuggestionPolicyKeepsPaletteWhileItClosesTheDetour() {
        XCTAssertEqual(
            KeelAddressSuggestionSubmissionPolicy.action(
                detourIsActive: true,
                addressSubmissionIsAllowed: false
            ),
            .sendAndKeepPalette
        )
        XCTAssertEqual(
            KeelAddressSuggestionSubmissionPolicy.action(
                detourIsActive: false,
                addressSubmissionIsAllowed: true
            ),
            .sendAndDismissPalette
        )
    }

    /// Distinct addresses per row. The palette now collapses rows that resolve
    /// to the same place, so a shared address would leave only one row.
    private func suggestion(id: String) -> KeelAddressPaletteSuggestion {
        KeelAddressPaletteSuggestion(
            id: id,
            historyURLID: Int64(id == "one" ? 1 : 2),
            title: "Sample store",
            address: "https://sample-store.myshopify.test/admin/\(id)"
        )
    }

    private static func historySuggestion(id: Int64, hostname: String) -> HistorySuggestion {
        HistorySuggestion(
            historyURLID: id,
            url: URL(string: "https://\(hostname).example/admin") ?? URL(fileURLWithPath: "/"),
            displayURL: "\(hostname).example/admin",
            hostname: "\(hostname).example",
            title: hostname,
            faviconReferenceKey: nil,
            match: HistorySuggestionMatch(quality: .hostnamePrefix, field: .hostname),
            visitCount: 1,
            typedCount: 1,
            lastVisitedAt: .now,
            addressChoiceCount: 0,
            lastAddressChoiceAt: nil
        )
    }
}

@MainActor
private final class MainActorSignal {
    private var hasSignalled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func signal() {
        hasSignalled = true
        let continuations = continuations
        self.continuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func wait() async {
        if hasSignalled {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

@MainActor
private final class FaviconTransportProbe: KeelFaviconTransport {
    private(set) var requestCount = 0

    func load(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> KeelFaviconTransportResponse {
        requestCount += 1
        throw URLError(.cancelled)
    }
}
