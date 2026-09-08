import Foundation
import Testing
import WebKit
@testable import KeelWeb

@MainActor
struct KeelWebViewRegistryTests {
    @Test("retaining an active page for Undo keeps one live web view")
    func retainActivePageForUndo() {
        let registry = KeelWebViewRegistry()
        let pageID = UUID()
        let webView = makeWebView()

        #expect(registry.activate(pageID: pageID, webView: webView) == nil)
        let result = registry.retainActiveAsUndo(pageID: pageID)

        guard case let .retained(replacedUndoWebView) = result else {
            Issue.record("Expected the active page to move into Undo")
            return
        }

        #expect(replacedUndoWebView == nil)
        #expect(registry.activeWebView() == nil)
        #expect(registry.webView(for: pageID) === webView)
        #expect(registry.slot(for: pageID) == .undo)
        #expect(registry.liveWebViewCount == 1)
    }

    @Test("restoring Undo lets the controller replace the active page without a third view")
    func restoreUndoThenActivate() throws {
        let registry = KeelWebViewRegistry()
        let oldPageID = UUID()
        let newPageID = UUID()
        let oldView = makeWebView()
        let newView = makeWebView()

        _ = registry.activate(pageID: oldPageID, webView: oldView)
        _ = registry.retainActiveAsUndo(pageID: oldPageID)
        _ = registry.activate(pageID: newPageID, webView: newView)

        let restored = try #require(registry.restoreUndo(pageID: oldPageID))
        #expect(restored === oldView)
        let displaced = registry.activate(pageID: oldPageID, webView: restored)

        #expect(displaced === newView)
        #expect(registry.activeWebView(for: oldPageID) === oldView)
        #expect(registry.liveWebViewCount == 2)
        registry.finishRetiring(newView)
        #expect(registry.liveWebViewCount == 1)
    }

    @Test("detour reservation evicts Undo before the popup becomes live")
    func detourReservationEvictsUndoBeforePopupCreation() throws {
        let registry = KeelWebViewRegistry()
        let pageID = UUID()
        let undoPageID = UUID()
        let activeView = makeWebView()
        let undoView = makeWebView()

        _ = registry.activate(pageID: undoPageID, webView: undoView)
        _ = registry.retainActiveAsUndo(pageID: undoPageID)
        _ = registry.activate(pageID: pageID, webView: activeView)

        let detourID = UUID()
        let reservation = try #require(registry.reserveDetour(id: detourID, parentPageID: pageID))
        #expect(reservation.evictedUndoWebView === undoView)
        #expect(registry.webView(for: undoPageID) == nil)
        #expect(registry.liveWebViewCount == 1)
        #expect(registry.canCreateWebView)
        #expect(registry.hasDetourReservation)
        #expect(registry.takeEvictedUndoWebView(from: reservation) === undoView)
        #expect(reservation.evictedUndoWebView == nil)

        let detourView = makeWebView()
        #expect(registry.presentDetour(id: detourID, webView: detourView, reservation: reservation))
        #expect(registry.detourWebView(for: detourID) === detourView)
        #expect(registry.detourParentPageID(for: detourID) == pageID)
        #expect(registry.liveWebViewCount == 2)
        #expect(!registry.hasDetourReservation)
    }

    @Test("reservation clears its Undo reference before popup construction")
    func reservationClearsUndoReferenceBeforePopupConstruction() throws {
        let registry = KeelWebViewRegistry()
        let activePageID = UUID()
        let undoPageID = UUID()
        let reservation: KeelWebViewRegistry.DetourReservation

        do {
            let undoView = makeWebView()
            _ = registry.activate(pageID: undoPageID, webView: undoView)
            _ = registry.retainActiveAsUndo(pageID: undoPageID)
            _ = registry.activate(pageID: activePageID, webView: makeWebView())
            reservation = try #require(registry.reserveDetour(id: UUID(), parentPageID: activePageID))
            let transferred = registry.takeEvictedUndoWebView(from: reservation)
            #expect(transferred === undoView)
            #expect(reservation.evictedUndoWebView == nil)
        }

        #expect(registry.liveWebViewCount == 1)
        #expect(registry.canCreateWebView)
    }

    @Test("a stale detour reservation cannot add a web view")
    func staleDetourReservationCannotAddPopup() throws {
        let registry = KeelWebViewRegistry()
        let pageID = UUID()
        _ = registry.activate(pageID: pageID, webView: makeWebView())
        let reservation = try #require(registry.reserveDetour(id: UUID(), parentPageID: pageID))
        registry.cancelDetourReservation(reservation)

        #expect(!registry.presentDetour(id: UUID(), webView: makeWebView(), reservation: reservation))
        #expect(registry.liveWebViewCount == 1)
    }

    @Test("dismiss and discard return the detached web views to the controller")
    func detachReturnedViews() throws {
        let registry = KeelWebViewRegistry()
        let pageID = UUID()
        let activeView = makeWebView()
        _ = registry.activate(pageID: pageID, webView: activeView)
        let detourID = UUID()
        let reservation = try #require(registry.reserveDetour(id: detourID, parentPageID: pageID))
        let detourView = makeWebView()
        #expect(registry.presentDetour(id: detourID, webView: detourView, reservation: reservation))

        #expect(registry.dismissDetour(id: detourID) === detourView)
        #expect(registry.liveWebViewCount == 2)
        registry.finishRetiring(detourView)
        _ = registry.retainActiveAsUndo(pageID: pageID)
        #expect(registry.discardUndo(pageID: pageID) === activeView)
        #expect(registry.liveWebViewCount == 1)
        registry.finishRetiring(activeView)
        #expect(registry.liveWebViewCount == 0)
    }

    @Test("a retiring detour keeps the second slot reserved until media shutdown finishes")
    func retiringDetourKeepsCapacityReserved() throws {
        let registry = KeelWebViewRegistry()
        let pageID = UUID()
        let detourID = UUID()
        let active = makeWebView()
        let detour = makeWebView()
        _ = registry.activate(pageID: pageID, webView: active)
        let reservation = try #require(registry.reserveDetour(id: detourID, parentPageID: pageID))
        #expect(registry.presentDetour(id: detourID, webView: detour, reservation: reservation))

        #expect(registry.dismissDetour(id: detourID) === detour)
        #expect(registry.liveWebViewCount == 2)
        #expect(!registry.canCreateWebView)

        registry.finishRetiring(detour)
        #expect(registry.liveWebViewCount == 1)
        #expect(registry.canCreateWebView)
    }

    private func makeWebView() -> WKWebView {
        KeelWebViewFactory.make()
    }
}
