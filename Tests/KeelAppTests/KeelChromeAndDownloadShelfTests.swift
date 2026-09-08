import AppKit
import KeelWeb
import XCTest
@testable import KeelApp

@MainActor
final class KeelChromeAndDownloadShelfTests: XCTestCase {
    private func mainMenu() -> NSMenu {
        let delegate = KeelApplicationDelegate()
        let chromeController = KeelChromeController()
        delegate.installBrowserMenu(using: chromeController)
        return try! XCTUnwrap(NSApp.mainMenu)
    }

    func testCommandTOpensTheAddressPaletteRatherThanDoingNothing() {
        let menu = mainMenu()
        let file = try! XCTUnwrap(menu.item(withTitle: "File")?.submenu)

        let newAddress = try! XCTUnwrap(file.item(withTitle: "New Address…"))
        XCTAssertEqual(newAddress.keyEquivalent, "t")
        XCTAssertEqual(newAddress.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(newAddress.representedObject as? KeelChromeCommand, .newAddress)

        // Shift+Cmd+T keeps reopening the closed page.
        let reopen = try! XCTUnwrap(file.item(withTitle: "Reopen Closed Page"))
        XCTAssertEqual(reopen.keyEquivalent, "t")
        XCTAssertEqual(reopen.keyEquivalentModifierMask, [.command, .shift])
    }

    func testCommandWIsAlwaysBoundSoItIsNeverADeadKeyOnHome() {
        let menu = mainMenu()
        let file = try! XCTUnwrap(menu.item(withTitle: "File")?.submenu)
        let close = try! XCTUnwrap(file.item(withTitle: "Close Page"))

        XCTAssertEqual(close.keyEquivalent, "w")
        XCTAssertEqual(close.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(close.representedObject as? KeelChromeCommand, .closePage)
    }

    func testFileMenuExposesStartQueueSoTheQueueCanBeDrained() {
        let menu = mainMenu()
        let file = try! XCTUnwrap(menu.item(withTitle: "File")?.submenu)
        let start = try! XCTUnwrap(file.item(withTitle: "Start Queue"))

        XCTAssertEqual(start.keyEquivalent, "\r")
        XCTAssertEqual(start.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(start.representedObject as? KeelChromeCommand, .startQueue)
    }

    func testMenuBarProvidesTheStandardMacintoshStructure() {
        let menu = mainMenu()
        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles, ["Keel", "File", "Edit", "View", "History", "Window", "Help"])

        let application = try! XCTUnwrap(menu.item(withTitle: "Keel")?.submenu)
        XCTAssertNotNil(application.item(withTitle: "About Keel"))
        XCTAssertNotNil(application.item(withTitle: "Services"))
        let hide = try! XCTUnwrap(application.item(withTitle: "Hide Keel"))
        XCTAssertEqual(hide.keyEquivalent, "h")
        XCTAssertEqual(hide.keyEquivalentModifierMask, [.command])
    }

    func testManagementShortcutsKeepTheirDecidedKeys() {
        let menu = mainMenu()

        let history = try! XCTUnwrap(menu.item(withTitle: "History")?.submenu?.item(withTitle: "Show All History"))
        XCTAssertEqual(history.keyEquivalent, "y")
        XCTAssertEqual(history.keyEquivalentModifierMask, [.command])

        let downloads = try! XCTUnwrap(menu.item(withTitle: "Window")?.submenu?.item(withTitle: "Downloads"))
        XCTAssertEqual(downloads.keyEquivalent, "l")
        XCTAssertEqual(downloads.keyEquivalentModifierMask, [.command, .option])

        let settings = try! XCTUnwrap(menu.item(withTitle: "Keel")?.submenu?.item(withTitle: "Settings…"))
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(settings.keyEquivalentModifierMask, [.command])
    }

    func testNoTwoMenuItemsClaimTheSameShortcut() {
        let shortcuts = allMenuItems(in: mainMenu())
            .filter { !$0.isSeparatorItem && !$0.keyEquivalent.isEmpty }
            .map { "\($0.keyEquivalent)|\($0.keyEquivalentModifierMask.rawValue)" }
        XCTAssertEqual(shortcuts.count, Set(shortcuts).count, "Duplicate shortcut in the menu bar")
    }

    func testEveryMenuItemRunsSomething() {
        let menu = mainMenu()
        let titles = Set(allMenuItems(in: menu).map(\.title))
        for forbidden in ["Save Page", "Stop Loading", "New Tab", "New Window", "Private Window"] {
            XCTAssertFalse(titles.contains(forbidden), "Unexpected out-of-scope command: \(forbidden)")
        }
        for item in allMenuItems(in: menu) where !item.isSeparatorItem && item.submenu == nil {
            XCTAssertNotNil(item.action, "Menu item has no command action: \(item.title)")
        }

        let showKeel = try! XCTUnwrap(menu.item(withTitle: "Window")?.submenu?.item(withTitle: "Show Keel"))
        XCTAssertEqual(showKeel.keyEquivalent, "n")
        XCTAssertEqual(showKeel.representedObject as? KeelChromeCommand, .showSoleWindow)
    }

    func testManagementCommandsAreBlockedWhenAProtectionPanelOwnsInput() {
        XCTAssertTrue(
            KeelManagementCommandPolicy.allows(
                modalWindowIsPresented: false,
                attachedSheetIsPresented: false
            )
        )
        XCTAssertFalse(
            KeelManagementCommandPolicy.allows(
                modalWindowIsPresented: true,
                attachedSheetIsPresented: false
            )
        )
        XCTAssertFalse(
            KeelManagementCommandPolicy.allows(
                modalWindowIsPresented: false,
                attachedSheetIsPresented: true
            )
        )
        XCTAssertFalse(
            KeelManagementCommandPolicy.allows(
                modalWindowIsPresented: true,
                attachedSheetIsPresented: true
            )
        )
    }

    func testDetourCommandPolicyBlocksCommandsThatDiscardOrMisrouteUserIntent() {
        let blocked: Set<KeelChromeCommand> = [
            .showAddressPalette,
            .newAddress,
            .copyCurrentURL,
            .showHome,
            .requeueAndClosePage,
            .restoreCloseUndo,
            .addCurrentURLToQueue,
            .startQueue,
            .findInPage,
            .findNext,
            .findPrevious,
        ]

        for command in blocked {
            XCTAssertFalse(KeelDetourCommandPolicy.allows(command, whileDetourIsActive: true))
        }
        XCTAssertEqual(
            Set(KeelChromeCommand.allCases.filter {
                !KeelDetourCommandPolicy.allows($0, whileDetourIsActive: true)
            }),
            blocked
        )
    }

    func testDetourCommandPolicyPreservesDetourNavigationAndClose() {
        let detourControls: Set<KeelChromeCommand> = [
            .back,
            .forward,
            .reload,
            .reloadFromOrigin,
            .closePage,
        ]

        for command in detourControls {
            XCTAssertTrue(KeelDetourCommandPolicy.allows(command, whileDetourIsActive: true))
        }
        for command in KeelChromeCommand.allCases {
            XCTAssertTrue(KeelDetourCommandPolicy.allows(command, whileDetourIsActive: false))
        }
    }

    func testDetourPolicyVisiblyDisablesBlockedMenuAndToolbarCommands() {
        let delegate = KeelApplicationDelegate()
        let controller = KeelChromeController()
        delegate.installBrowserMenu(using: controller)
        let menu = try! XCTUnwrap(NSApp.mainMenu)

        let toolbar = NSToolbar(identifier: "keel-app-test")
        let homeItem = controller.toolbar(
            toolbar,
            itemForItemIdentifier: .init("com.chrisrowe.keel.home"),
            willBeInsertedIntoToolbar: true
        )
        let closeItem = controller.toolbar(
            toolbar,
            itemForItemIdentifier: .init("com.chrisrowe.keel.close-page"),
            willBeInsertedIntoToolbar: true
        )

        controller.updatePageAvailability(hasActivePage: true)
        controller.applyCommandPolicy {
            KeelDetourCommandPolicy.allows($0, whileDetourIsActive: true)
        }

        let file = menu.item(withTitle: "File")?.submenu
        XCTAssertFalse(file?.item(withTitle: "Open Address…")?.isEnabled ?? true)
        XCTAssertFalse(file?.item(withTitle: "New Address…")?.isEnabled ?? true)
        XCTAssertFalse(file?.item(withTitle: "Add Address to Queue")?.isEnabled ?? true)
        XCTAssertFalse(menu.item(withTitle: "Edit")?.submenu?.item(withTitle: "Find…")?.isEnabled ?? true)
        XCTAssertFalse((homeItem?.view as? NSButton)?.isEnabled ?? true)
        XCTAssertTrue((closeItem?.view as? NSButton)?.isEnabled ?? false)
    }

    func testAddressSubmissionPolicyRejectsAStateChangeAfterAsyncResolution() {
        XCTAssertTrue(
            KeelDetourCommandPolicy.allows(.showAddressPalette, whileDetourIsActive: false)
        )
        XCTAssertFalse(
            KeelDetourCommandPolicy.allows(.showAddressPalette, whileDetourIsActive: true)
        )
    }

    func testDownloadShelfKeepsNewestItemCollapsedAndPreservesOrderWhenExpanded() {
        let newest = KeelDownloadShelfItem(id: UUID(), filename: "newest.pdf", state: .completed)
        let older = KeelDownloadShelfItem(id: UUID(), filename: "older.pdf", state: .completed)
        let shelf = KeelDownloadShelfController()

        shelf.setItems([newest, older])
        XCTAssertFalse(shelf.isExpanded)
        XCTAssertEqual(shelf.visibleItemIDs, [newest.id])

        shelf.setExpanded(true)
        XCTAssertTrue(shelf.isExpanded)
        XCTAssertEqual(shelf.visibleItemIDs, [newest.id, older.id])

        shelf.setExpanded(false)
        XCTAssertEqual(shelf.visibleItemIDs, [newest.id])
    }

    func testACompletedShelfCardClearsItselfAndACancelledOrFailedOneDoesNot() {
        var clock = Date(timeIntervalSinceReferenceDate: 1_000)
        let shelf = KeelDownloadShelfController(now: { clock }, autoDismissDelay: 5)
        var dismissed: [UUID] = []
        shelf.onDismiss = { dismissed.append($0) }

        let done = KeelDownloadShelfItem(id: UUID(), filename: "done.pdf", state: .completed)
        let cancelled = KeelDownloadShelfItem(id: UUID(), filename: "stopped.pdf", state: .cancelled)
        let failed = KeelDownloadShelfItem(id: UUID(), filename: "broken.pdf", state: .failed(message: "1"))
        shelf.setItems([done, cancelled, failed])

        clock = clock.addingTimeInterval(4)
        shelf.performAutoDismiss(at: clock)
        XCTAssertEqual(dismissed, [])

        clock = clock.addingTimeInterval(2)
        shelf.performAutoDismiss(at: clock)
        XCTAssertEqual(dismissed, [done.id])
        XCTAssertEqual(Set(shelf.visibleItemIDs), [cancelled.id])

        clock = clock.addingTimeInterval(600)
        shelf.performAutoDismiss(at: clock)
        XCTAssertEqual(dismissed, [done.id])
    }

    func testARunningCardIsNeverAutoDismissed() {
        var clock = Date(timeIntervalSinceReferenceDate: 1_000)
        let shelf = KeelDownloadShelfController(now: { clock }, autoDismissDelay: 5)
        var dismissed: [UUID] = []
        shelf.onDismiss = { dismissed.append($0) }

        let running = KeelDownloadShelfItem(id: UUID(), filename: "big.zip", state: .receiving(progress: 0.4))
        shelf.setItems([running])
        XCTAssertNil(shelf.autoDismissDeadline)

        clock = clock.addingTimeInterval(60)
        shelf.performAutoDismiss(at: clock)
        XCTAssertEqual(dismissed, [])
    }

    func testHoveringHoldsTheCardAndRestartsTheDelayOnceThePointerLeaves() {
        var clock = Date(timeIntervalSinceReferenceDate: 1_000)
        let shelf = KeelDownloadShelfController(now: { clock }, autoDismissDelay: 5)
        var dismissed: [UUID] = []
        shelf.onDismiss = { dismissed.append($0) }

        let done = KeelDownloadShelfItem(id: UUID(), filename: "done.pdf", state: .completed)
        shelf.setItems([done])
        shelf.setHovering(true)

        clock = clock.addingTimeInterval(30)
        shelf.performAutoDismiss(at: clock)
        XCTAssertEqual(dismissed, [])
        XCTAssertNil(shelf.autoDismissDeadline)

        shelf.setHovering(false)
        XCTAssertEqual(shelf.autoDismissDeadline, clock.addingTimeInterval(5))

        clock = clock.addingTimeInterval(3)
        shelf.performAutoDismiss(at: clock)
        XCTAssertEqual(dismissed, [])

        clock = clock.addingTimeInterval(3)
        shelf.performAutoDismiss(at: clock)
        XCTAssertEqual(dismissed, [done.id])
    }

    func testTheShelfCardStatusLineCarriesTheRunningRate() {
        let item = KeelDownloadShelfItem(
            id: UUID(),
            filename: "big.zip",
            state: .receiving(progress: 0.25),
            detail: "1.2 MB/s · 8s left"
        )

        XCTAssertEqual(item.statusLine, "25% · 1.2 MB/s · 8s left")
        XCTAssertEqual(
            KeelDownloadShelfItem(id: item.id, filename: "big.zip", state: .completed).statusLine,
            "Downloaded"
        )
    }

    func testTerminationPolicyOnlyPromptsForActiveDownloads() {
        let completed = KeelDownloadSnapshot(
            id: UUID(),
            sourceHostname: "example.com",
            filename: "complete.pdf",
            state: .completed,
            createdAt: .now
        )
        let active = KeelDownloadSnapshot(
            id: UUID(),
            sourceHostname: "example.com",
            filename: "active.pdf",
            state: .inProgress,
            createdAt: .now
        )

        XCTAssertFalse(KeelTerminationPolicy.hasInProgressDownloads([completed]))
        XCTAssertTrue(KeelTerminationPolicy.hasInProgressDownloads([completed, active]))
    }

    func testWindowTracksHiddenChromeStateForControlCommandDrag() {
        let controller = KeelWindowController(shellView: KeelShellView(), permitsWindowPresentation: false)

        controller.setChromeVisible(false)

        XCTAssertFalse(controller.isChromeVisible)
        controller.removeHiddenChromeDragMonitor()
    }

    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            guard let submenu = item.submenu else { return [item] }
            return [item] + allMenuItems(in: submenu)
        }
    }
}
