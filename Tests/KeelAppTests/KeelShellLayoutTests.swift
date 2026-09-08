import AppKit
import XCTest
@testable import KeelApp

/// Guards the defects that made the dogfood build unusable. Each test names the
/// symptom rather than the implementation, so a future refactor still has to
/// keep the behaviour.
@MainActor
final class KeelShellLayoutTests: XCTestCase {
    func testOffscreenWindowDoesNotRegisterAnAutosavedFrame() {
        let controller = KeelWindowController(shellView: KeelShellView(), permitsWindowPresentation: false)
        XCTAssertEqual(controller.window?.frameAutosaveName, "")
        controller.removeHiddenChromeDragMonitor()
    }

    func testContentStartsBelowTheToolbarWhileChromeIsVisible() {
        let shell = KeelShellView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unifiedCompact
        window.toolbar = NSToolbar(identifier: "keel-layout-test")
        window.contentView = shell

        let page = NSView()
        shell.addSubview(page)
        shell.pinToContentArea(page)
        shell.layoutSubtreeIfNeeded()

        // The page must not begin at the very top of the window, which is what
        // drew Hacker News underneath the toolbar glyphs.
        XCTAssertGreaterThan(
            shell.bounds.height - page.frame.height,
            0,
            "Page content is not inset below the title bar"
        )
        XCTAssertEqual(page.frame.width, shell.bounds.width, accuracy: 0.5)
    }

    func testHidingChromeGivesThePageTheWholeFrame() {
        let shell = KeelShellView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.toolbar = NSToolbar(identifier: "keel-layout-test-hidden")
        window.contentView = shell

        let page = NSView()
        shell.addSubview(page)
        shell.pinToContentArea(page)

        shell.isChromeVisible = false
        shell.layoutSubtreeIfNeeded()

        XCTAssertEqual(page.frame.height, shell.bounds.height, accuracy: 0.5)
    }

    func testShowingChromeRestoresAnOpaqueTitleBar() {
        let shell = KeelShellView()
        let controller = KeelWindowController(shellView: shell, permitsWindowPresentation: false)
        let window = try! XCTUnwrap(controller.window)

        controller.setChromeVisible(false)
        XCTAssertTrue(
            window.titlebarAppearsTransparent,
            "Hidden chrome should let the page reach the window edge"
        )

        controller.setChromeVisible(true)
        XCTAssertFalse(
            window.titlebarAppearsTransparent,
            "Visible chrome needs title bar material behind the toolbar glyphs"
        )
        controller.removeHiddenChromeDragMonitor()
    }

    func testShowingAnAlreadyVisibleWindowDoesNotResizeIt() {
        let presentation = WindowPresentationProbe(isVisible: true)
        let controller = KeelWindowController(shellView: KeelShellView(),
            permitsWindowPresentation: true, windowPresentation: presentation)
        let window = try! XCTUnwrap(controller.window)
        let chosen = NSRect(x: 120, y: 120, width: 1_480, height: 900)
        window.setFrame(chosen, display: false)

        controller.showSoleWindow()

        XCTAssertEqual(presentation.hiddenPresentationCount, 0, "Showing an existing window must not restore its autosaved frame")
        XCTAssertEqual(presentation.bringToFrontCount, 1)
        XCTAssertEqual(window.frame.width, chosen.width, accuracy: 0.5)
        XCTAssertEqual(window.frame.height, chosen.height, accuracy: 0.5)
        XCTAssertFalse(window.isVisible, "The injected presenter must never order the test window")
        controller.removeHiddenChromeDragMonitor()
    }

    func testShowingAHiddenWindowRunsTheInitialPresentationOnce() {
        let presentation = WindowPresentationProbe(isVisible: false)
        let controller = KeelWindowController(shellView: KeelShellView(),
            permitsWindowPresentation: true, windowPresentation: presentation)
        controller.showSoleWindow()
        controller.showSoleWindow()
        XCTAssertEqual(presentation.hiddenPresentationCount, 1)
        XCTAssertEqual(presentation.bringToFrontCount, 2)
        XCTAssertFalse(controller.window?.isVisible ?? true)
        controller.removeHiddenChromeDragMonitor()
    }

    func testTheToolbarUsesAHairlineRatherThanAFadedShadow() {
        let controller = KeelWindowController(shellView: KeelShellView(), permitsWindowPresentation: false)
        let window = try! XCTUnwrap(controller.window)

        // Automatic fades a shadow under the toolbar as if content scrolled
        // beneath it. Keel insets its content, so there is nothing under there.
        XCTAssertEqual(window.titlebarSeparatorStyle, .line)

        controller.setChromeVisible(false)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)

        controller.setChromeVisible(true)
        XCTAssertEqual(window.titlebarSeparatorStyle, .line)
        controller.removeHiddenChromeDragMonitor()
    }

    func testWindowTitleFollowsThePageSoMissionControlCanNameIt() {
        let controller = KeelWindowController(shellView: KeelShellView(), permitsWindowPresentation: false)

        controller.updateWindowTitle("Hacker News")
        XCTAssertEqual(controller.window?.title, "Hacker News")

        controller.updateWindowTitle(nil)
        XCTAssertEqual(controller.window?.title, "Keel")
        controller.removeHiddenChromeDragMonitor()
    }
}

@MainActor
final class KeelAddressBarTests: XCTestCase {
    func testTheAddressBarSeparatesHostFromTheRest() {
        XCTAssertEqual(KeelAddressBarView.displayHost("www.example.com"), "example.com")
        XCTAssertEqual(KeelAddressBarView.displayHost("news.ycombinator.com"), "news.ycombinator.com")
    }

    func testABareOriginShowsNoLonelySlash() {
        let url = URL(string: "https://example.com/")!
        XCTAssertEqual(KeelAddressBarView.remainder(of: url), "")
    }

    func testTheRestOfTheAddressStaysVisible() {
        let url = URL(string: "https://example.com/a/b?q=1#frag")!
        XCTAssertEqual(KeelAddressBarView.remainder(of: url), "/a/b?q=1#frag")
    }
}

@MainActor
private final class WindowPresentationProbe: KeelWindowPresenting {
    let savesWindowFrame = false
    var visible: Bool
    var hiddenPresentationCount = 0
    var bringToFrontCount = 0
    init(isVisible: Bool) { visible = isVisible }
    func isVisible(_ window: NSWindow) -> Bool { visible }
    func showHiddenWindow(_ controller: NSWindowController) {
        hiddenPresentationCount += 1
        visible = true
        // Model the autosaved-frame restoration that caused the regression.
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 720, height: 480), display: false)
    }
    func bringToFront(_ window: NSWindow) { bringToFrontCount += 1 }
}
