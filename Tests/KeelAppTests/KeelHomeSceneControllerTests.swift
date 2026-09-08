import AppKit
import CoreGraphics
import Foundation
import ImageIO
import KeelFoundation
import KeelUI
import UniformTypeIdentifiers
import XCTest
@testable import KeelApp
@testable import KeelStore

@MainActor
final class KeelHomeSceneControllerTests: XCTestCase {
    func testOnePhotoShowsTheSameSceneOnEveryArrival() async throws {
        let fixture = try SceneFixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()
        _ = try await fixture.addScene(named: "Harbour")
        _ = try await fixture.addScene(named: "Cliff")
        await controller.loadLibrary()
        controller.settingsDidChange(fixture.settings)

        controller.arriveAtHome()
        let first = controller.currentSceneID
        controller.arriveAtHome()
        controller.arriveAtHome()

        XCTAssertEqual(controller.currentSceneID, .bundled("como"))
        XCTAssertEqual(controller.currentSceneID, first)
        XCTAssertTrue(fixture.settings.homeSceneRotation.order.isEmpty, "One photo advanced a deck it does not use")
        XCTAssertNil(fixture.persistedSettings, "One photo wrote settings on arrival")
    }

    func testRotateAllShowsEachSceneOncePerCycleAndPersistsTheDeck() async throws {
        let fixture = try SceneFixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()
        _ = try await fixture.addScene(named: "Harbour")
        _ = try await fixture.addScene(named: "Cliff")
        await controller.loadLibrary()
        fixture.settings.homeSceneMode = .rotateAll
        controller.settingsDidChange(fixture.settings)

        var shown: [KeelHomeSceneID] = []
        for _ in 0 ..< controller.library.count {
            controller.arriveAtHome()
            shown.append(try XCTUnwrap(controller.currentSceneID))
        }

        XCTAssertEqual(Set(shown).count, controller.library.count, "A scene repeated inside one cycle: \(shown)")
        let persisted = try XCTUnwrap(fixture.persistedSettings)
        XCTAssertEqual(Set(persisted.homeSceneRotation.order), Set(shown.map(\.storedValue)))
        XCTAssertEqual(persisted.homeSceneRotation.position, controller.library.count - 1)

        // A relaunch reads the deck back and carries on rather than restarting it.
        let relaunched = fixture.makeController()
        await relaunched.loadLibrary()
        relaunched.settingsDidChange(persisted)
        relaunched.arriveAtHome()
        let next = try XCTUnwrap(relaunched.currentSceneID)
        XCTAssertNotEqual(next, shown.last, "The new cycle opened on the scene that just closed the old one")
        XCTAssertEqual(try XCTUnwrap(fixture.persistedSettings).homeSceneRotation.position, 0)
    }

    func testAnArrivalBeforeTheLibraryLoadsWaitsForTheWholeDeck() async throws {
        let fixture = try SceneFixture()
        defer { fixture.remove() }
        _ = try await fixture.addScene(named: "Harbour")
        _ = try await fixture.addScene(named: "Cliff")
        let controller = fixture.makeController()
        fixture.settings.homeSceneMode = .rotateAll
        controller.settingsDidChange(fixture.settings)

        // Launch: Home renders before the store has answered.
        controller.arriveAtHome()
        XCTAssertNil(fixture.persistedSettings, "Shuffled before the imported scenes were known")

        await controller.loadLibrary()
        let persisted = try XCTUnwrap(fixture.persistedSettings)
        XCTAssertEqual(persisted.homeSceneRotation.order.count, KeelBundledScenes.all.count + 2, "The launch deck missed the imported scenes")
        XCTAssertNotNil(controller.currentSceneID)
    }

    func testRotateMineWithNothingImportedRotatesEverything() async throws {
        let fixture = try SceneFixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()
        await controller.loadLibrary()
        fixture.settings.homeSceneMode = .rotateMine
        controller.settingsDidChange(fixture.settings)

        controller.arriveAtHome()

        XCTAssertTrue(controller.library.contains { $0.id == controller.currentSceneID })
        let persisted = try XCTUnwrap(fixture.persistedSettings)
        XCTAssertEqual(Set(persisted.homeSceneRotation.order), Set(controller.library.map(\.id.storedValue)))
    }

    func testRemovingTheSelectedSceneFallsBackToComo() async throws {
        let fixture = try SceneFixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()
        let row = try await fixture.addScene(named: "Harbour")
        await controller.loadLibrary()
        fixture.settings.selectedHomeSceneID = KeelHomeSceneID.user(row.id).storedValue
        controller.settingsDidChange(fixture.settings)
        XCTAssertEqual(controller.selectedSceneID, .user(row.id))
        controller.arriveAtHome()
        XCTAssertEqual(controller.currentSceneID, .user(row.id))

        await controller.remove(.user(row.id))

        XCTAssertEqual(controller.selectedSceneID, .bundled("como"))
        XCTAssertEqual(controller.currentSceneID, .bundled("como"))
        XCTAssertEqual(controller.library.count, KeelBundledScenes.all.count)
        let fileURL = fixture.paths.homeScenesDirectory.appending(path: row.fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
        let rows = try await fixture.store.userHomeScenes()
        XCTAssertTrue(rows.isEmpty)
    }

    func testARowWithoutItsFileIsDropped() async throws {
        let fixture = try SceneFixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()
        let kept = try await fixture.addScene(named: "Harbour")
        let lost = try await fixture.addScene(named: "Cliff")
        try FileManager.default.removeItem(
            at: fixture.paths.homeScenesDirectory.appending(path: lost.fileName)
        )

        await controller.loadLibrary()

        XCTAssertEqual(controller.library.map(\.id).filter { if case .user = $0 { return true }; return false }, [.user(kept.id)])
        let rows = try await fixture.store.userHomeScenes()
        XCTAssertEqual(rows.map(\.id), [kept.id])
    }

    func testImportKeepsTheGoodPhotoAndReportsTheBadOne() async throws {
        let fixture = try SceneFixture()
        defer { fixture.remove() }
        let controller = fixture.makeController()
        let good = try fixture.writeSourceImage(named: "Beach")
        let bad = fixture.directory.appending(path: "not-a-photo.png")
        try Data("this is not an image".utf8).write(to: bad)

        let outcome = await controller.importScenes([good, bad])

        XCTAssertEqual(outcome.imported, 1)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(try XCTUnwrap(outcome.failures.first).hasPrefix("not-a-photo.png"))
        let rows = try await fixture.store.userHomeScenes()
        XCTAssertEqual(rows.map(\.displayName), ["Beach"])
        XCTAssertEqual(controller.library.count, KeelBundledScenes.all.count + 1)
    }
}

/// A store and a container directory of their own, so one test's photographs
/// never reach another's.
@MainActor
private final class SceneFixture {
    let directory: URL
    let paths: KeelPaths
    let store: KeelStore
    var settings = KeelSettings()
    var persistedSettings: KeelSettings?

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "KeelHomeSceneTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        paths = KeelPaths(applicationSupportDirectory: directory)
        try FileManager.default.createDirectory(at: paths.homeScenesDirectory, withIntermediateDirectories: true)
        store = try KeelStore(databaseURL: paths.databaseURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeController() -> KeelHomeSceneController {
        KeelHomeSceneController(
            store: store,
            paths: paths,
            window: { nil },
            persistSettings: { [weak self] next in
                self?.settings = next
                self?.persistedSettings = next
            }
        )
    }

    /// A row and its file, without going through the importer.
    func addScene(named name: String) async throws -> UserHomeScene {
        let row = UserHomeScene(
            fileName: "\(UUID().uuidString.lowercased()).heic",
            displayName: name,
            topLuminance: 0.4,
            bottomLuminance: 0.5,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(name.count))
        )
        try await store.insertUserHomeScene(row)
        try Data("pixels".utf8).write(to: paths.homeScenesDirectory.appending(path: row.fileName))
        return row
    }

    /// A real PNG on disk, so the importer has something it can actually decode.
    func writeSourceImage(named name: String) throws -> URL {
        let url = directory.appending(path: "\(name).png")
        let width = 64
        let height = 64
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        guard let writer = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw SceneFixtureError.couldNotWriteSource }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw SceneFixtureError.couldNotWriteSource }
        return url
    }
}

private enum SceneFixtureError: Error {
    case couldNotWriteSource
}
