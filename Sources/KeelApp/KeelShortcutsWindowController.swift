import AppKit
import KeelUI
import SwiftUI

/// The keyboard map, generated from the commands themselves.
///
/// Keel's shortcuts changed enough during the dogfood pass that a written list
/// would already be wrong. This reads `KeelChromeCommand` directly, so it cannot
/// drift from what the menus actually bind.
@MainActor
final class KeelShortcutsWindowController: NSWindowController {
    private static let contentSize = NSSize(width: 460, height: 560)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Keyboard Shortcuts"
        // A transparent title bar let the list scroll up under the window
        // controls and the title, which read as a rendering fault.
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: KeelShortcutsView())
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    func toggle(relativeTo parent: NSWindow?) {
        guard let window else { return }
        if window.isVisible {
            window.orderOut(nil)
            return
        }
        if let parent {
            let origin = NSPoint(
                x: parent.frame.midX - Self.contentSize.width / 2,
                y: parent.frame.midY - Self.contentSize.height / 2
            )
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }
}

private struct KeelShortcutsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KeelDesign.Space.loose) {
                ForEach(KeelShortcutGroup.all) { group in
                    VStack(alignment: .leading, spacing: KeelDesign.Space.tight) {
                        Text(group.title)
                            .font(KeelDesign.Text.sectionTitle)
                            .foregroundStyle(.secondary)

                        VStack(spacing: 0) {
                            ForEach(group.entries) { entry in
                                HStack {
                                    Text(entry.title)
                                        .font(KeelDesign.Text.body)
                                    Spacer(minLength: KeelDesign.Space.comfortable)
                                    Text(entry.shortcut)
                                        .font(KeelDesign.Text.numeric)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, KeelDesign.Space.regular)
                                .padding(.vertical, 6)

                                if entry.id != group.entries.last?.id {
                                    KeelRowSeparatorProxy()
                                }
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: KeelDesign.Radius.card)
                                .fill(KeelDesign.Surface.raised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: KeelDesign.Radius.card)
                                .strokeBorder(KeelDesign.Surface.hairline, lineWidth: 1)
                        )
                    }
                }
            }
            .padding(.horizontal, KeelDesign.Inset.screenHorizontal)
            .padding(.top, KeelDesign.Inset.screenVertical)
            .padding(.bottom, KeelDesign.Inset.screenVertical)
        }
        .background(KeelDesign.Surface.canvas)
        .accessibilityLabel("Keyboard shortcuts")
    }
}

/// KeelUI's separator is internal to that module, so the shortcuts sheet draws
/// its own hairline from the same token rather than widening KeelUI's surface.
private struct KeelRowSeparatorProxy: View {
    var body: some View {
        Rectangle()
            .fill(KeelDesign.Surface.hairline)
            .frame(height: 1)
            .padding(.leading, KeelDesign.Space.regular)
            .accessibilityHidden(true)
    }
}

@MainActor
struct KeelShortcutEntry: Identifiable {
    let id: String
    let title: String
    let shortcut: String

    init(command: KeelChromeCommand) {
        id = command.rawValue
        title = command.title
        shortcut = KeelShortcutFormatter.glyphs(
            key: command.keyEquivalent,
            modifiers: command.modifierMask
        )
    }

    init(id: String, title: String, key: String, modifiers: NSEvent.ModifierFlags) {
        self.id = id
        self.title = title
        shortcut = KeelShortcutFormatter.glyphs(key: key, modifiers: modifiers)
    }
}

@MainActor
struct KeelShortcutGroup: Identifiable {
    let id: String
    let title: String
    let entries: [KeelShortcutEntry]

    /// Grouped the way the menu bar is, so the sheet and the menus agree.
    static var all: [KeelShortcutGroup] {
        [
            KeelShortcutGroup(
                id: "address",
                title: "Address and queue",
                entries: [
                    KeelShortcutEntry(command: .newAddress),
                    KeelShortcutEntry(command: .showAddressPalette),
                    KeelShortcutEntry(command: .addCurrentURLToQueue),
                    KeelShortcutEntry(command: .startQueue),
                    KeelShortcutEntry(command: .copyCurrentURL),
                ]
            ),
            KeelShortcutGroup(
                id: "page",
                title: "The active page",
                entries: [
                    KeelShortcutEntry(command: .back),
                    KeelShortcutEntry(command: .forward),
                    KeelShortcutEntry(command: .reload),
                    KeelShortcutEntry(command: .reloadFromOrigin),
                    KeelShortcutEntry(command: .closePage),
                    KeelShortcutEntry(command: .requeueAndClosePage),
                    KeelShortcutEntry(command: .restoreCloseUndo),
                    KeelShortcutEntry(command: .printPage),
                ]
            ),
            KeelShortcutGroup(
                id: "find",
                title: "Find",
                entries: [
                    KeelShortcutEntry(command: .findInPage),
                    KeelShortcutEntry(command: .findNext),
                    KeelShortcutEntry(command: .findPrevious),
                ]
            ),
            KeelShortcutGroup(
                id: "view",
                title: "View",
                entries: [
                    KeelShortcutEntry(command: .showHome),
                    KeelShortcutEntry(command: .zoomIn),
                    KeelShortcutEntry(command: .zoomOut),
                    KeelShortcutEntry(command: .resetZoom),
                    KeelShortcutEntry(command: .toggleChrome),
                ]
            ),
            KeelShortcutGroup(
                id: "screens",
                title: "Keel screens",
                entries: [
                    KeelShortcutEntry(id: "history", title: "History", key: "y", modifiers: .command),
                    KeelShortcutEntry(id: "downloads", title: "Downloads", key: "l", modifiers: [.command, .option]),
                    KeelShortcutEntry(id: "settings", title: "Settings", key: ",", modifiers: .command),
                    KeelShortcutEntry(command: .showSoleWindow),
                    KeelShortcutEntry(id: "shortcuts", title: "Keyboard Shortcuts", key: "/", modifiers: .command),
                ]
            ),
        ]
    }
}

enum KeelShortcutFormatter {
    /// Renders a key equivalent the way the menu bar draws it, so the sheet and
    /// the menus cannot disagree about what a shortcut looks like.
    static func glyphs(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var rendered = ""
        if modifiers.contains(.control) { rendered += "⌃" }
        if modifiers.contains(.option) { rendered += "⌥" }
        if modifiers.contains(.shift) { rendered += "⇧" }
        if modifiers.contains(.command) { rendered += "⌘" }
        return rendered + keyGlyph(for: key)
    }

    static func keyGlyph(for key: String) -> String {
        switch key {
        case "\r": "↩"
        case "\u{8}": "⌫"
        case "\u{1b}": "⎋"
        case " ": "Space"
        default: key.uppercased()
        }
    }
}
