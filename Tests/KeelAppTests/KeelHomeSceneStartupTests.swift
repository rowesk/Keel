import Foundation
import KeelFoundation
import KeelStore
import KeelUI
import XCTest
@testable import KeelApp

@MainActor
final class KeelHomeSceneStartupTests: XCTestCase {
    func testStoredImportedSelectionWinsWhenPreferencesArriveBeforeLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = KeelPaths(applicationSupportDirectory: directory)
        let store = try KeelStore(paths: paths)
        let row = UserHomeScene(fileName: "selected.heic", displayName: "Selected",
                                topLuminance: 0.4, bottomLuminance: 0.4, addedAt: .now)
        try FileManager.default.createDirectory(at: paths.homeScenesDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: XCTUnwrap(KeelBundledScenes.url(for: "como")),
                                         to: paths.homeScenesDirectory.appending(path: row.fileName))
        try await store.insertUserHomeScene(row)
        let controller = KeelHomeSceneController(store: store, paths: paths, window: { nil }, persistSettings: { _ in })
        controller.settingsDidChange(KeelSettings(selectedHomeSceneID: "user:\(row.id.uuidString.lowercased())"))
        controller.arriveAtHome()
        await controller.loadLibrary()
        XCTAssertEqual(controller.currentSceneID, .user(row.id), "Late library loading must replace the initial fallback with the saved photo")
        // Decode completes on a worker. A cold CI image can take over a second.
        for _ in 0..<500 where controller.currentDisplay.image == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(controller.currentDisplay.image)
    }
}
