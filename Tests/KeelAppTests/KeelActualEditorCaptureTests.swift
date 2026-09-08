import AppKit
import SwiftUI
import KeelUI
import XCTest
@testable import KeelApp

@MainActor
final class KeelActualEditorCaptureTests: XCTestCase {
    func testActualEmbeddedEditorAndSuggestionsRenderOffscreenAtBothWidths() throws {
        for width in [720.0, 1120.0] {
          for variant in ["selected-unicode-long", "empty", "no-results"] {
            let shell = KeelShellView()
            let controller = KeelWindowController(shellView: shell, permitsWindowPresentation: false)
            controller.permitsWindowPresentation = false
            let window = try XCTUnwrap(controller.window)
            window.setContentSize(NSSize(width: width, height: 600))
            let host = KeelNativeScreenHost()
            shell.addSubview(host)
            shell.pinToContentArea(host)
            let palette = KeelAddressPaletteController()
            let state = KeelEmbeddedPaletteState()
            palette.onEmbeddedChange = {
                state.isActive = palette.isEmbeddedActive
                state.rowsHeight = palette.embeddedRowsHeight
            }
            host.showHome(model: KeelHomeModel(), actions: KeelHomeActions(),
                addressField: AnyView(KeelEmbeddedAddressField(state: state, palette: palette).transaction { $0.disablesAnimations = true }))
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(palette.isEmbedded, "The capture must contain the real editor")
            palette.activateEmbedded(initialQuery: variant == "empty" ? "" : "東京 café example", mode: .opensNow)
            palette.setSuggestions(variant == "selected-unicode-long" ? [
                KeelAddressPaletteSuggestion(id: "one", historyURLID: 1, title: String(repeating: "東京 café résumé 🛶 ", count: 12), address: "https://example.test/" + String(repeating: "long-path/", count: 20))
            ] : [], forQueryGeneration: palette.queryGeneration)
            if variant == "selected-unicode-long" {
                _ = palette.performKeyboardCommandForTesting("moveUp:")
            }
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(palette.isEmbeddedActive)
            XCTAssertTrue(palette.queryHasEditorForTesting)
            XCTAssertEqual(palette.visibleSuggestionIDsForTesting, variant == "selected-unicode-long" ? ["one"] : [])
            if variant == "selected-unicode-long" { XCTAssertEqual(palette.selectedSuggestionIDForTesting, "one") }
            XCTAssertFalse(window.isVisible)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            if let directory = ProcessInfo.processInfo.environment["KEEL_APP_CAPTURE_DIRECTORY"] {
                let output = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try data.write(to: output.appendingPathComponent("actual-editor-\(variant)-\(Int(width)).png"))
            }
            XCTAssertGreaterThan(data.count, 10_000)
            palette.dismiss(notify: false)
            controller.removeHiddenChromeDragMonitor()
            window.close()
          }
        }
    }
}
