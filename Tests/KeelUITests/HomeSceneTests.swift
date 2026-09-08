import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import KeelUI

final class HomeSceneTests: XCTestCase {
    func testDisplayedScrimSamplesTopTextAndAspectFillCrop() throws {
        func image(width: Int, height: Int, white: (Int, Int) -> Bool) throws -> NSImage {
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width where !white(x, y) {
                    let offset = (y * width + x) * 4
                    bytes[offset] = 0
                    bytes[offset + 1] = 0
                    bytes[offset + 2] = 0
                }
            }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
            let cg = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                                          bitsPerPixel: 32, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
        }
        let topWhite = try image(width: 100, height: 100) { _, y in y < 35 }
        XCTAssertGreaterThan(KeelHomeSceneGradient.displayedTopOpacity(image: topWhite,
                             viewport: CGSize(width: 1000, height: 1000), fallbackLuminance: 0), 0.70)
        let brightEdge = try image(width: 600, height: 200) { x, _ in x > 500 }
        let wide = KeelHomeSceneGradient.displayedTopOpacity(image: brightEdge,
                    viewport: CGSize(width: 1200, height: 400), fallbackLuminance: 0)
        let cropped = KeelHomeSceneGradient.displayedTopOpacity(image: brightEdge,
                       viewport: CGSize(width: 720, height: 720), fallbackLuminance: 0)
        XCTAssertGreaterThan(wide, 0.70)
        XCTAssertEqual(cropped, 0.20, accuracy: 0.01)
    }

    private var scratch = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keel-scene-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Scene ids

    func testSceneIDRoundTripsThroughItsStoredValue() {
        let bundled = KeelHomeSceneID.bundled("como")
        XCTAssertEqual(bundled.storedValue, "bundled:como")
        XCTAssertEqual(KeelHomeSceneID(storedValue: "bundled:como"), bundled)

        let uuid = UUID()
        let user = KeelHomeSceneID.user(uuid)
        XCTAssertEqual(user.storedValue, "user:\(uuid.uuidString.lowercased())")
        XCTAssertEqual(KeelHomeSceneID(storedValue: user.storedValue), user)

        XCTAssertNil(KeelHomeSceneID(storedValue: "como"))
        XCTAssertNil(KeelHomeSceneID(storedValue: "bundled:"))
        XCTAssertNil(KeelHomeSceneID(storedValue: "user:not-a-uuid"))
    }

    // MARK: Bundled scenes

    func testBundledScenesLoadAndEveryFileIsInTheBundle() throws {
        let scenes = KeelBundledScenes.all
        XCTAssertFalse(scenes.isEmpty)
        XCTAssertEqual(scenes.first?.id, "como")

        for scene in scenes {
            let url = try XCTUnwrap(KeelBundledScenes.url(for: scene.id), "missing resource for \(scene.id)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing file \(scene.file)")
        }
    }

    func testComoMatchesTheBundledManifest() throws {
        let como = try XCTUnwrap(KeelBundledScenes.all.first { $0.id == "como" })
        XCTAssertEqual(como.topLuminance, KeelHomeScene.como.topLuminance, accuracy: 0.0001)
        XCTAssertEqual(como.bottomLuminance, KeelHomeScene.como.bottomLuminance, accuracy: 0.0001)
    }

    // MARK: Luminance

    func testLuminanceOfFlatImages() {
        let white = KeelSceneLuminance.measure(Self.flat(white: 1))
        XCTAssertEqual(white.top, 1, accuracy: 0.01)
        XCTAssertEqual(white.bottom, 1, accuracy: 0.01)

        let black = KeelSceneLuminance.measure(Self.flat(white: 0))
        XCTAssertEqual(black.top, 0, accuracy: 0.01)
        XCTAssertEqual(black.bottom, 0, accuracy: 0.01)

        let half = KeelSceneLuminance.measure(Self.flat(white: 0.5))
        XCTAssertEqual(half.top, 0.5, accuracy: 0.02)
        XCTAssertEqual(half.bottom, 0.5, accuracy: 0.02)
    }

    func testLuminanceReadsTheTopAndBottomBandsSeparately() {
        // White upper half, black lower half. The bands never overlap.
        let image = Self.halves(top: 1, bottom: 0)
        let measured = KeelSceneLuminance.measure(image)
        XCTAssertEqual(measured.top, 1, accuracy: 0.02)
        XCTAssertEqual(measured.bottom, 0, accuracy: 0.02)
    }

    // MARK: Gradient

    func testGradientFloorIsTheScrimHomeAlwaysDrew() {
        let scrim = KeelHomeSceneGradient.opacities(
            topLuminance: KeelHomeSceneGradient.topRange.low,
            bottomLuminance: KeelHomeSceneGradient.bottomRange.low
        )
        XCTAssertEqual(scrim.top, 0.22, accuracy: 0.01)
        XCTAssertEqual(scrim.bottom, 0.46, accuracy: 0.01)
    }

    func testGradientAnchorsAndClamping() {
        let high = KeelHomeSceneGradient.opacities(topLuminance: 0.70, bottomLuminance: 0.70)
        XCTAssertEqual(high.top, 0.48, accuracy: 0.0001)
        XCTAssertEqual(high.bottom, 0.68, accuracy: 0.0001)

        let dark = KeelHomeSceneGradient.opacities(topLuminance: 0, bottomLuminance: 0)
        XCTAssertEqual(dark.top, 0.22, accuracy: 0.0001)
        XCTAssertEqual(dark.bottom, 0.46, accuracy: 0.0001)

        let blown = KeelHomeSceneGradient.opacities(topLuminance: 1, bottomLuminance: 1)
        XCTAssertEqual(blown.top, 0.48, accuracy: 0.0001)
        XCTAssertEqual(blown.bottom, 0.68, accuracy: 0.0001)

        let middle = KeelHomeSceneGradient.opacities(topLuminance: 0.505, bottomLuminance: 0.525)
        XCTAssertEqual(middle.top, 0.35, accuracy: 0.01)
        XCTAssertEqual(middle.bottom, 0.57, accuracy: 0.01)
    }

    // MARK: Importer

    func testImportDownsamplesAndWritesHEIC() throws {
        let source = scratch.appendingPathComponent("Big Water.png")
        try Self.write(Self.flat(white: 0.5, width: 6_000, height: 4_000), to: source, type: .png)

        let imported = try KeelSceneImporter.importScene(from: source, into: scratch.appendingPathComponent("scenes"))

        XCTAssertEqual(imported.displayName, "Big Water")
        XCTAssertTrue(imported.fileName.hasSuffix(".heic"))

        let written = scratch.appendingPathComponent("scenes").appendingPathComponent(imported.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))

        let readBack = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(readBack) as String?, UTType.heic.identifier)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(readBack, 0, nil))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 4_096)
        XCTAssertGreaterThan(image.width, image.height)
    }

    func testImportStripsMetadata() throws {
        let source = scratch.appendingPathComponent("Tagged.jpg")
        try Self.write(
            Self.flat(white: 0.4),
            to: source,
            type: .jpeg,
            properties: [
                kCGImagePropertyExifDictionary as String: [
                    kCGImagePropertyExifUserComment as String: "keel-test-secret",
                    kCGImagePropertyExifDateTimeOriginal as String: "2020:01:01 00:00:00",
                ],
            ]
        )
        // The source really does carry the tag, otherwise the assertion below
        // would pass for the wrong reason.
        let sourceProperties = try XCTUnwrap(Self.properties(of: source))
        XCTAssertNotNil(sourceProperties[kCGImagePropertyExifDictionary as String])

        let imported = try KeelSceneImporter.importScene(from: source, into: scratch)
        let written = scratch.appendingPathComponent(imported.fileName)
        let properties = try XCTUnwrap(Self.properties(of: written))
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment as String])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
    }

    func testImportRejectsAnOversizeFile() throws {
        let source = scratch.appendingPathComponent("Huge.jpg")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(KeelSceneImporter.maximumSourceBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try KeelSceneImporter.importScene(from: source, into: scratch)) { error in
            XCTAssertEqual(error as? KeelSceneImportError, .tooLarge)
        }
    }

    func testImportRejectsSomethingThatIsNotAnImage() throws {
        let source = scratch.appendingPathComponent("Notes.jpg")
        try Data("not an image".utf8).write(to: source)

        XCTAssertThrowsError(try KeelSceneImporter.importScene(from: source, into: scratch)) { error in
            XCTAssertEqual(error as? KeelSceneImportError, .unreadable)
        }
    }

    func testImportTakesTheFirstFrameOfAnAnimatedSource() throws {
        let source = scratch.appendingPathComponent("Blink.gif")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(
            source as CFURL, UTType.gif.identifier as CFString, 2, nil
        ))
        CGImageDestinationSetProperties(writer, [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0],
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 0.2],
        ] as CFDictionary
        CGImageDestinationAddImage(writer, Self.flat(white: 1), frameProperties)
        CGImageDestinationAddImage(writer, Self.flat(white: 0), frameProperties)
        XCTAssertTrue(CGImageDestinationFinalize(writer))

        let imported = try KeelSceneImporter.importScene(from: source, into: scratch)
        // Frame one is white, frame two black. A white result proves frame
        // one was the one that was taken.
        XCTAssertEqual(imported.topLuminance, 1, accuracy: 0.03)
        XCTAssertEqual(imported.bottomLuminance, 1, accuracy: 0.03)

        let written = scratch.appendingPathComponent(imported.fileName)
        let readBack = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(readBack), 1)
    }

    // MARK: Fixtures

    private static func flat(white: Double, width: Int = 400, height: Int = 300) -> CGImage {
        let context = makeContext(width: width, height: height)
        context.setFillColor(gray: white, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private static func halves(top: Double, bottom: Double) -> CGImage {
        let width = 400, height = 300
        let context = makeContext(width: width, height: height)
        // CGContext draws from the bottom left up.
        context.setFillColor(gray: bottom, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(gray: top, alpha: 1)
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        return context.makeImage()!
    }

    private static func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
    }

    private static func write(
        _ image: CGImage,
        to url: URL,
        type: UTType,
        properties: [String: Any] = [:]
    ) throws {
        guard let writer = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw KeelSceneImportError.writeFailed
        }
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw KeelSceneImportError.writeFailed }
    }

    private static func properties(of url: URL) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    }
}
