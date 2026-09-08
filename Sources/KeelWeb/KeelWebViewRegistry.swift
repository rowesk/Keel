import Foundation
import WebKit

/// Owns the at-most-two live web views allowed by Keel.
///
/// The registry deliberately does not add views to an AppKit hierarchy. The browser
/// controller controls visibility while this type controls references and slot limits.
@MainActor
public final class KeelWebViewRegistry {
    public enum Slot: Equatable {
        case active
        case detour
        case undo
    }

    public enum UndoRetention {
        case retained(replacedUndoWebView: WKWebView?)
        case ignored
    }

    public final class DetourReservation {
        public let id: UUID
        public let parentPageID: UUID
        public private(set) var evictedUndoWebView: WKWebView?

        fileprivate init(id: UUID, parentPageID: UUID, evictedUndoWebView: WKWebView?) {
            self.id = id
            self.parentPageID = parentPageID
            self.evictedUndoWebView = evictedUndoWebView
        }

        fileprivate func takeEvictedUndoWebView() -> WKWebView? {
            defer { evictedUndoWebView = nil }
            return evictedUndoWebView
        }
    }

    private struct Entry {
        let pageID: UUID
        let webView: WKWebView
    }

    private struct DetourEntry {
        let id: UUID
        let parentPageID: UUID
        let webView: WKWebView
    }

    private var active: Entry?
    private var detour: DetourEntry?
    private var undo: Entry?
    private var reservation: DetourReservation?
    private var retiring: [ObjectIdentifier: WKWebView] = [:]

    public init() {}

    public var liveWebViewCount: Int {
        [active?.webView, detour?.webView, undo?.webView].compactMap { $0 }.count + retiring.count
    }

    /// A factory caller must check this before instantiating another WKWebView.
    public var canCreateWebView: Bool { liveWebViewCount < 2 }

    public var hasDetourReservation: Bool {
        reservation != nil
    }

    public func slot(for pageID: UUID) -> Slot? {
        if active?.pageID == pageID { return .active }
        if detour?.id == pageID { return .detour }
        if undo?.pageID == pageID { return .undo }
        return nil
    }

    public func webView(for pageID: UUID) -> WKWebView? {
        if active?.pageID == pageID { return active?.webView }
        if detour?.id == pageID { return detour?.webView }
        if undo?.pageID == pageID { return undo?.webView }
        return nil
    }

    public func activeWebView() -> WKWebView? {
        active?.webView
    }

    public func activeWebView(for pageID: UUID) -> WKWebView? {
        active?.pageID == pageID ? active?.webView : nil
    }

    /// Makes `webView` the active page and returns the active view it replaced.
    /// The caller owns any returned view and must remove it from the view hierarchy.
    @discardableResult
    public func activate(pageID: UUID, webView: WKWebView) -> WKWebView? {
        precondition(!isOwnedOutsideActive(webView), "A web view cannot occupy two Keel slots")

        if active?.pageID == pageID, active?.webView === webView {
            return nil
        }

        let displaced = active?.webView
        if let displaced { beginRetiring(displaced) }
        active = Entry(pageID: pageID, webView: webView)
        assertCapacity()
        return displaced
    }

    /// Detaches the active page. The caller takes ownership of the returned view.
    @discardableResult
    public func detachActive(pageID: UUID) -> WKWebView? {
        guard active?.pageID == pageID else { return nil }
        let detached = active?.webView
        if let detached { beginRetiring(detached) }
        active = nil
        return detached
    }

    /// Moves the active page into the single Undo slot, replacing any older Undo page.
    @discardableResult
    public func retainActiveAsUndo(pageID: UUID) -> UndoRetention {
        guard let active, active.pageID == pageID else { return .ignored }

        let replacedUndo = undo?.webView
        if let replacedUndo { beginRetiring(replacedUndo) }
        self.active = nil
        undo = active
        assertCapacity()
        return .retained(replacedUndoWebView: replacedUndo)
    }

    /// Moves the Undo page out of the registry. The caller should activate it next.
    @discardableResult
    public func restoreUndo(pageID: UUID) -> WKWebView? {
        guard undo?.pageID == pageID else { return nil }
        let restored = undo?.webView
        undo = nil
        return restored
    }

    /// Removes the Undo page from the registry and gives its view back to the caller.
    @discardableResult
    public func discardUndo(pageID: UUID) -> WKWebView? {
        guard undo?.pageID == pageID else { return nil }
        let discarded = undo?.webView
        if let discarded { beginRetiring(discarded) }
        undo = nil
        return discarded
    }

    /// Reserves the second live slot before WebKit synchronously asks for a popup view.
    ///
    /// Reserving a detour removes Undo first. The caller owns the evicted view and must
    /// suspend or destroy it before calling `presentDetour`.
    public func reserveDetour(id: UUID, parentPageID: UUID) -> DetourReservation? {
        guard active?.pageID == parentPageID, detour == nil, reservation == nil else { return nil }

        // Popup creation is synchronous. Undo is deliberately downgraded to an opaque
        // checkpoint by the controller, then removed from Keel ownership before WebKit
        // receives the supplied popup configuration. It must not consume a retiring slot.
        let evictedUndo = undo?.webView
        undo = nil
        let reservation = DetourReservation(
            id: id,
            parentPageID: parentPageID,
            evictedUndoWebView: evictedUndo
        )
        self.reservation = reservation
        assertCapacity()
        return reservation
    }

    /// Transfers the evicted Undo view out of the reservation. The caller must archive and
    /// release it before constructing WebKit's supplied popup configuration.
    public func takeEvictedUndoWebView(from reservation: DetourReservation) -> WKWebView? {
        guard self.reservation === reservation else { return nil }
        return reservation.takeEvictedUndoWebView()
    }

    /// Fills a reservation with WebKit's popup view. A stale reservation cannot create a detour.
    @discardableResult
    public func presentDetour(
        id: UUID,
        webView: WKWebView,
        reservation: DetourReservation
    ) -> Bool {
        guard self.reservation === reservation,
              reservation.id == id,
              active?.pageID == reservation.parentPageID,
              detour == nil,
              !isOwned(webView) else {
            return false
        }

        detour = DetourEntry(id: id, parentPageID: reservation.parentPageID, webView: webView)
        self.reservation = nil
        assertCapacity()
        return true
    }

    /// Cancels an unfilled detour reservation. Undo remains evicted by design.
    public func cancelDetourReservation(_ reservation: DetourReservation) {
        guard self.reservation === reservation else { return }
        self.reservation = nil
    }

    public func detourWebView(for detourID: UUID) -> WKWebView? {
        detour?.id == detourID ? detour?.webView : nil
    }

    public func detourParentPageID(for detourID: UUID) -> UUID? {
        detour?.id == detourID ? detour?.parentPageID : nil
    }

    /// Removes the detour from the registry and gives its view back to the caller.
    @discardableResult
    public func dismissDetour(id: UUID) -> WKWebView? {
        guard detour?.id == id else { return nil }
        let dismissed = detour?.webView
        if let dismissed { beginRetiring(dismissed) }
        detour = nil
        return dismissed
    }

    /// Removes a WebKit instance from the live budget only after its media shutdown callback.
    public func finishRetiring(_ webView: WKWebView) {
        retiring.removeValue(forKey: ObjectIdentifier(webView))
        assertCapacity()
    }

    public func hasDetour(parentPageID: UUID) -> Bool {
        detour?.parentPageID == parentPageID
    }

    private func isOwnedOutsideActive(_ webView: WKWebView) -> Bool {
        detour?.webView === webView || undo?.webView === webView
    }

    private func isOwned(_ webView: WKWebView) -> Bool {
        active?.webView === webView || isOwnedOutsideActive(webView) || retiring[ObjectIdentifier(webView)] != nil
    }

    private func beginRetiring(_ webView: WKWebView) {
        retiring[ObjectIdentifier(webView)] = webView
    }

    private func assertCapacity() {
        assert(liveWebViewCount <= 2, "Keel must never retain more than two live web views")
    }
}
