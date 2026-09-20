import AppKit
import KeelUI
import KeelWeb
import XCTest
@testable import KeelApp

@MainActor
final class KeelAppearanceRegressionTests: XCTestCase {
    func testPaletteColoursFollowWindowAppearanceAndReattachment() throws {
        try withOffscreenWindow { window, host in
            let palette = KeelAddressPaletteController()
            palette.present(over: host, initialQuery: "ft.")
            defer { palette.dismiss(notify: false) }
            let panel = try XCTUnwrap(descendants(host).first { $0.layer?.cornerRadius == 14 && $0.layer?.borderWidth == 1 })
            try exerciseAppearances(window: window) {
                assertSurface(panel)
                let selected = try XCTUnwrap(descendants(panel).first { $0.layer?.cornerRadius == 7 && ($0.layer?.backgroundColor?.alpha ?? 0) > 0 })
                assertColour(selected.layer?.backgroundColor, KeelDesign.NSSurface.selection, in: selected)
                // Input updates must resolve selection against the window, even
                // when the application has the opposite appearance.
                palette.updateQuery("bbc")
                assertColour(selected.layer?.backgroundColor, KeelDesign.NSSurface.selection, in: selected)
            }
            palette.dismiss(notify: false)
            window.appearance = NSAppearance(named: .aqua)
            palette.present(over: host, initialQuery: "ft.")
            assertSurface(panel)
        }
    }

    func testFindPanelColoursFollowWindowAppearanceAndReattachment() throws {
        try withOffscreenWindow { window, host in
            let find = KeelFindController()
            find.present(over: host)
            defer { find.dismiss(notify: false) }
            let panel = try XCTUnwrap(descendants(host).first { $0 is NSVisualEffectView && $0.layer?.borderWidth == 1 })
            exerciseAppearances(window: window) { assertSurface(panel) }
            find.dismiss(notify: false)
            window.appearance = NSAppearance(named: .aqua)
            find.present(over: host)
            assertSurface(panel)
        }
    }

    func testDownloadCardColoursFollowWindowAppearance() throws {
        try withOffscreenWindow { window, host in
            let shelf = KeelDownloadShelfController()
            // Build the card before attachment, under the app's dark theme.
            shelf.setItems([KeelDownloadShelfItem(id: UUID(), filename: "test.zip", state: .receiving(progress: 0.4))])
            window.appearance = NSAppearance(named: .aqua)
            shelf.attach(to: host)
            let card = try XCTUnwrap(descendants(host).first { $0 is NSVisualEffectView && $0.layer?.borderWidth == 1 })
            assertSurface(card)
            exerciseAppearances(window: window) { assertSurface(card) }
        }
    }

    func testPageErrorBackgroundFollowsWindowAppearance() {
        withOffscreenWindow { window, host in
            let error = KeelPageErrorView()
            window.appearance = NSAppearance(named: .aqua)
            host.addSubview(error)
            assertColour(error.layer?.backgroundColor, KeelDesign.NSSurface.canvas, in: error)
            exerciseAppearances(window: window) {
                assertColour(error.layer?.backgroundColor, KeelDesign.NSSurface.canvas, in: error)
            }
        }
    }

    func testHoverColoursUseWindowAppearanceAndRefreshWhileHovered() throws {
        try withOffscreenWindow { window, host in
            let address = KeelAddressBarView(frame: .zero)
            let button = KeelToolbarButton(frame: .zero)
            host.addSubview(address)
            host.addSubview(button)
            let background = try XCTUnwrap(address.subviews.first { $0.layer?.borderWidth == 1 })
            let event = try XCTUnwrap(NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil
            ))
            window.appearance = NSAppearance(named: .aqua)
            address.mouseEntered(with: event)
            button.mouseEntered(with: event)
            exerciseAppearances(window: window) {
                assertColour(background.layer?.backgroundColor, KeelDesign.NSSurface.ink.withAlphaComponent(0.1), in: address)
                assertColour(background.layer?.borderColor, KeelDesign.NSSurface.ink.withAlphaComponent(0.18), in: address)
                assertColour(button.layer?.backgroundColor, NSColor.quaternaryLabelColor.withAlphaComponent(0.22), in: button)
            }
            window.appearance = NSAppearance(named: .aqua)
            address.mouseExited(with: event)
            button.mouseExited(with: event)
            assertColour(background.layer?.backgroundColor, KeelDesign.NSSurface.ink.withAlphaComponent(0.06), in: address)
            XCTAssertEqual(button.layer?.backgroundColor?.alpha, 0)
        }
    }

    private func withOffscreenWindow(_ body: (NSWindow, NSView) throws -> Void) rethrows {
        let app = NSApplication.shared
        let original = app.appearance
        app.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        defer {
            window.orderOut(nil)
            window.close()
            app.appearance = original
        }
        try body(window, host)
        XCTAssertFalse(window.isVisible)
    }

    private func exerciseAppearances(window: NSWindow, check: () throws -> Void) rethrows {
        for mode: NSAppearance.Name in [.darkAqua, .aqua, .darkAqua, .aqua] {
            window.appearance = NSAppearance(named: mode)
            window.layoutIfNeeded()
            try check()
        }
        // No window override: follow application/system appearance as well.
        window.appearance = nil
        for mode: NSAppearance.Name in [.aqua, .darkAqua] {
            NSApplication.shared.appearance = NSAppearance(named: mode)
            window.layoutIfNeeded()
            try check()
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func assertSurface(_ view: NSView, file: StaticString = #filePath, line: UInt = #line) {
        assertColour(view.layer?.backgroundColor, KeelDesign.NSSurface.raised, in: view, file: file, line: line)
        assertColour(view.layer?.borderColor, KeelDesign.NSSurface.hairline, in: view, file: file, line: line)
    }

    private func assertColour(_ actual: CGColor?, _ colour: @autoclosure () -> NSColor, in view: NSView, file: StaticString = #filePath, line: UInt = #line) {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            XCTAssertEqual(actual, colour().cgColor, "Layer colour must follow \(view.effectiveAppearance.name)", file: file, line: line)
        }
    }
}
