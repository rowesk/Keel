import AppKit
import XCTest
@testable import KeelApp

/// The shortcuts sheet is generated from `KeelChromeCommand`, so it cannot list
/// a key the menus do not bind. These pin that, and pin the glyph rendering.
@MainActor
final class KeelShortcutsSheetTests: XCTestCase {
    func testEveryListedCommandShortcutMatchesItsMenuBinding() {
        let delegate = KeelApplicationDelegate()
        delegate.installBrowserMenu(using: KeelChromeController())
        let menu = try! XCTUnwrap(NSApp.mainMenu)

        var bindingsByCommand: [String: String] = [:]
        for item in allMenuItems(in: menu) {
            guard let command = item.representedObject as? KeelChromeCommand else { continue }
            bindingsByCommand[command.rawValue] = KeelShortcutFormatter.glyphs(
                key: item.keyEquivalent,
                modifiers: item.keyEquivalentModifierMask
            )
        }

        for group in KeelShortcutGroup.all {
            for entry in group.entries {
                guard let bound = bindingsByCommand[entry.id] else { continue }
                XCTAssertEqual(
                    entry.shortcut,
                    bound,
                    "The shortcuts sheet and the menu bar disagree about \(entry.title)"
                )
            }
        }
    }

    func testTheSheetCoversEveryCommandTheMenusBind() {
        let delegate = KeelApplicationDelegate()
        delegate.installBrowserMenu(using: KeelChromeController())
        let menu = try! XCTUnwrap(NSApp.mainMenu)

        let bound = Set(allMenuItems(in: menu).compactMap {
            ($0.representedObject as? KeelChromeCommand)?.rawValue
        })
        let listed = Set(KeelShortcutGroup.all.flatMap { $0.entries.map(\.id) })

        XCTAssertTrue(
            bound.subtracting(listed).isEmpty,
            "Commands bound in a menu but missing from the shortcuts sheet: \(bound.subtracting(listed).sorted())"
        )
    }

    func testHelpMenuIsInstalledAndDoesNotCollide() {
        let delegate = KeelApplicationDelegate()
        delegate.installBrowserMenu(using: KeelChromeController())
        let menu = try! XCTUnwrap(NSApp.mainMenu)

        let help = try! XCTUnwrap(menu.item(withTitle: "Help")?.submenu)
        let shortcuts = try! XCTUnwrap(help.item(withTitle: "Keyboard Shortcuts"))
        XCTAssertEqual(shortcuts.keyEquivalent, "/")
        XCTAssertEqual(shortcuts.keyEquivalentModifierMask, [.command])

        let all = allMenuItems(in: menu)
            .filter { !$0.isSeparatorItem && !$0.keyEquivalent.isEmpty }
            .map { "\($0.keyEquivalent)|\($0.keyEquivalentModifierMask.rawValue)" }
        XCTAssertEqual(all.count, Set(all).count)
    }

    func testReturnAndEscapeRenderAsGlyphsNotAsControlCharacters() {
        XCTAssertEqual(KeelShortcutFormatter.glyphs(key: "\r", modifiers: .command), "⌘↩")
        XCTAssertEqual(KeelShortcutFormatter.glyphs(key: "t", modifiers: [.command, .shift]), "⇧⌘T")
        XCTAssertEqual(
            KeelShortcutFormatter.glyphs(key: "l", modifiers: [.command, .option]),
            "⌥⌘L"
        )
    }

    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            guard let submenu = item.submenu else { return [item] }
            return [item] + allMenuItems(in: submenu)
        }
    }
}
