#!/usr/bin/env swift
//
// Prepares bundled home scenes.
//
//     swift Scripts/import-scenes.swift <folder-of-originals> [resources-folder]
//
// Writes Sources/KeelUI/Resources/<slug>.heic at 2560 px on the long edge,
// quality 0.85, metadata stripped, and merges an entry per photo into
// scenes.json. Como stays first and keeps its JPEG.
//
// The luminance maths here is a copy of KeelSceneLuminance (top 24 %, bottom
// 38 %, sampled at 128 px wide). A standalone script cannot import KeelUI, so
// the two must be changed together.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sampleWidth = 128
let topBand = 0.24
let bottomBand = 0.38
let longEdge = 2_560
let quality = 0.85

func measure(_ image: CGImage) -> (top: Double, bottom: Double) {
    let width = min(sampleWidth, max(1, image.width))
    let height = max(1, Int((Double(image.height) / Double(max(1, image.width)) * Double(width)).rounded()))
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
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
                total += 0.2126 * Double(bytes[index]) / 255
                    + 0.7152 * Double(bytes[index + 1]) / 255
                    + 0.0722 * Double(bytes[index + 2]) / 255
            }
        }
        return total / Double(rows * width)
    }

    let topRows = max(1, Int((Double(height) * topBand).rounded()))
    let bottomRows = max(1, Int((Double(height) * bottomBand).rounded()))
    return (band(fromRow: 0, rows: topRows), band(fromRow: height - bottomRows, rows: bottomRows))
}

func slug(_ name: String) -> String {
    let lowered = name.lowercased()
    var out = ""
    var lastWasDash = false
    for character in lowered {
        if character.isLetter || character.isNumber {
            out.append(character)
            lastWasDash = false
        } else if !lastWasDash, !out.isEmpty {
            out.append("-")
            lastWasDash = true
        }
    }
    while out.hasSuffix("-") { out.removeLast() }
    return out.isEmpty ? "scene" : out
}

func displayName(_ name: String) -> String {
    let words = slug(name).split(separator: "-").map { $0.capitalized }
    return words.joined(separator: " ")
}

func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

func byteLabel(_ bytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(bytes))
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: swift Scripts/import-scenes.swift <folder-of-originals> [resources-folder]")
    exit(2)
}
let sourceFolder = URL(fileURLWithPath: arguments[1], isDirectory: true)
let resources = arguments.count >= 3
    ? URL(fileURLWithPath: arguments[2], isDirectory: true)
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/KeelUI/Resources", isDirectory: true)

struct Scene: Codable {
    var id: String
    var name: String
    var file: String
    var topLuminance: Double
    var bottomLuminance: Double
}

let manifest = resources.appendingPathComponent("scenes.json")
var scenes: [Scene] = {
    guard let data = try? Data(contentsOf: manifest) else { return [] }
    return (try? JSONDecoder().decode([Scene].self, from: data)) ?? []
}()

try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

let originals = (try FileManager.default.contentsOfDirectory(
    at: sourceFolder,
    includingPropertiesForKeys: [.fileSizeKey],
    options: [.skipsHiddenFiles]
)).sorted { $0.lastPathComponent < $1.lastPathComponent }

var totalIn = 0
var totalOut = 0

for original in originals {
    let id = slug(original.deletingPathExtension().lastPathComponent)
    // Como ships as the JPEG that has always been in the bundle.
    if id == "keel-home" || id == "como" {
        print("skipping \(original.lastPathComponent): Como stays the bundled JPEG")
        continue
    }
    guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
          ] as CFDictionary)
    else {
        print("skipping \(original.lastPathComponent): could not read it")
        continue
    }

    let file = "\(id).heic"
    let destination = resources.appendingPathComponent(file)
    guard let writer = CGImageDestinationCreateWithURL(
        destination as CFURL, UTType.heic.identifier as CFString, 1, nil
    ) else {
        print("skipping \(original.lastPathComponent): could not write HEIC")
        continue
    }
    CGImageDestinationAddImage(writer, image, [
        kCGImageDestinationLossyCompressionQuality: quality,
        kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
        kCGImageDestinationMergeMetadata: false,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(writer) else {
        print("skipping \(original.lastPathComponent): could not finalize HEIC")
        continue
    }

    let luminance = measure(image)
    let scene = Scene(
        id: id,
        name: displayName(original.deletingPathExtension().lastPathComponent),
        file: file,
        topLuminance: round2(luminance.top),
        bottomLuminance: round2(luminance.bottom)
    )
    if let index = scenes.firstIndex(where: { $0.id == id }) {
        scenes[index] = scene
    } else {
        scenes.append(scene)
    }

    let inBytes = (try? original.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    let outBytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    totalIn += inBytes
    totalOut += outBytes
    print("\(original.lastPathComponent) -> \(file)  \(image.width)x\(image.height)  \(byteLabel(inBytes)) -> \(byteLabel(outBytes))  top \(round2(luminance.top)) bottom \(round2(luminance.bottom))")
}

// Como first, then whatever order the manifest already had.
if let comoIndex = scenes.firstIndex(where: { $0.id == "como" }), comoIndex != 0 {
    let como = scenes.remove(at: comoIndex)
    scenes.insert(como, at: 0)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(scenes).write(to: manifest)

print("\(scenes.count) scene(s) in \(manifest.path)")
print("originals \(byteLabel(totalIn)) -> bundled \(byteLabel(totalOut))")
