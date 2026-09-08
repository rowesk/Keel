import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Mean relative luminance of the bands Home puts type over.
///
/// Keep these constants in step with `Scripts/import-scenes.swift`, which
/// measures bundled scenes the same way at build time.
public enum KeelSceneLuminance {
    /// The top band the wordmark and header sit in.
    static let topBand = 0.24
    /// The bottom band the ledger and status line sit in.
    static let bottomBand = 0.38
    /// Wide enough to average honestly, small enough to be free.
    static let sampleWidth = 128

    /// Mean relative luminance (0…1) of the top and bottom bands.
    public static func measure(_ image: CGImage) -> (top: Double, bottom: Double) {
        let width = min(sampleWidth, max(1, image.width))
        let height = max(1, Int((Double(image.height) / Double(max(1, image.width)) * Double(width)).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return (0.5, 0.5) }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return (0.5, 0.5) }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        func band(fromRow: Int, rows: Int) -> Double {
            guard rows > 0 else { return 0.5 }
            var total = 0.0
            for row in fromRow..<(fromRow + rows) {
                for column in 0..<width {
                    let index = row * width * 4 + column * 4
                    let red = Double(bytes[index]) / 255
                    let green = Double(bytes[index + 1]) / 255
                    let blue = Double(bytes[index + 2]) / 255
                    total += 0.2126 * red + 0.7152 * green + 0.0722 * blue
                }
            }
            return total / Double(rows * width)
        }

        // CGContext rows run top down for the bitmap we drew into.
        let topRows = max(1, Int((Double(height) * topBand).rounded()))
        let bottomRows = max(1, Int((Double(height) * bottomBand).rounded()))
        return (band(fromRow: 0, rows: topRows), band(fromRow: height - bottomRows, rows: bottomRows))
    }
}

/// A scene copied into the app container.
public struct KeelImportedScene: Equatable, Sendable {
    public var fileName: String
    public var displayName: String
    public var topLuminance: Double
    public var bottomLuminance: Double

    public init(fileName: String, displayName: String, topLuminance: Double, bottomLuminance: Double) {
        self.fileName = fileName
        self.displayName = displayName
        self.topLuminance = topLuminance
        self.bottomLuminance = bottomLuminance
    }
}

public enum KeelSceneImportError: Error, Equatable, LocalizedError {
    case tooLarge
    case unreadable
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "That photo is too large. Keel takes photos up to 60 MB."
        case .unreadable: "Keel could not read that photo."
        case .writeFailed: "Keel could not save that photo."
        }
    }
}

/// Copies a chosen photograph into the app's own store: one still frame, no
/// metadata, a size Home can draw without holding a 60 megapixel bitmap.
public enum KeelSceneImporter {
    /// Anything past this and the original is not a photograph worth keeping.
    static let maximumSourceBytes = 60 * 1_024 * 1_024
    /// Long edge of the stored copy.
    static let maximumPixelSize = 4_096
    static let quality = 0.85

    public static func importScene(from source: URL, into directory: URL) throws -> KeelImportedScene {
        let values = try? source.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize, size > maximumSourceBytes { throw KeelSceneImportError.tooLarge }

        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw KeelSceneImportError.unreadable
        }
        // Frame 0 only. An animated source becomes its first still.
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ] as CFDictionary) else {
            throw KeelSceneImportError.unreadable
        }

        let luminance = KeelSceneLuminance.measure(image)
        let fileName = "\(UUID().uuidString.lowercased()).heic"
        let destination = directory.appendingPathComponent(fileName)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw KeelSceneImportError.writeFailed
        }

        guard let writer = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw KeelSceneImportError.writeFailed
        }
        // Nothing from the original travels with the pixels: no EXIF, no GPS,
        // no maker notes.
        CGImageDestinationAddImage(writer, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
            kCGImageDestinationMergeMetadata: false,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {
            try? FileManager.default.removeItem(at: destination)
            throw KeelSceneImportError.writeFailed
        }

        return KeelImportedScene(
            fileName: fileName,
            displayName: source.deletingPathExtension().lastPathComponent,
            topLuminance: luminance.top,
            bottomLuminance: luminance.bottom
        )
    }
}
