import AppKit

/// Turns a scene's measured luminance into the two scrim strengths Home draws.
///
/// A bright photograph needs more shading behind the wordmark and the ledger
/// than a dark one. The anchors are calibrated on Como, the default scene, so
/// its scrim is exactly the one Home has always drawn: (0.22, 0.46).
public enum KeelHomeSceneGradient {
    /// Como's measured luminance is the low end of each ramp; a near-white
    /// band is the high end.
    static let topRange = (low: 0.31, high: 0.70)
    static let bottomRange = (low: 0.35, high: 0.70)
    static let topOpacity = (low: 0.22, high: 0.48)
    static let bottomOpacity = (low: 0.46, high: 0.68)

    public static func opacities(topLuminance: Double, bottomLuminance: Double) -> (top: Double, bottom: Double) {
        (
            top: map(topLuminance, from: topRange, to: topOpacity),
            bottom: map(bottomLuminance, from: bottomRange, to: bottomOpacity)
        )
    }

    /// Sample the aspect-filled crop, not the uncropped source's import bands.
    /// The plateau covers navigation and the wordmark, then yields to the lake.
    public static func displayedTopOpacity(image: NSImage?, viewport: CGSize, fallbackLuminance: Double) -> Double {
        let luminance = displayedTopLuminance(image: image, viewport: viewport) ?? fallbackLuminance
        return map(luminance, from: (0.10, 0.80), to: (0.20, 0.74))
    }

    static func displayedTopLuminance(image: NSImage?, viewport: CGSize) -> Double? {
        guard let image, viewport.width > 0, viewport.height > 0,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let width = 96
        let height = max(1, Int(Double(width) * viewport.height / viewport.width))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let scale = max(Double(width) / Double(cgImage.width), Double(height) / Double(cgImage.height))
        let drawnWidth = Double(cgImage.width) * scale
        let drawnHeight = Double(cgImage.height) * scale
        context.draw(cgImage, in: CGRect(x: (Double(width) - drawnWidth) / 2,
                                        y: (Double(height) - drawnHeight) / 2,
                                        width: drawnWidth, height: drawnHeight))
        let sampleScale = Double(width) / viewport.width
        let wordmarkRegion = CGRect(x: Double(width) / 2 - 70 * sampleScale,
                                    y: Double(height) * 0.20 - 42 * sampleScale,
                                    width: 140 * sampleScale, height: 84 * sampleScale)
        let navigationRegion = CGRect(x: Double(width) - 330 * sampleScale, y: 12 * sampleScale,
                                      width: 310 * sampleScale, height: 32 * sampleScale)
        let rows = max(1, Int(Double(height) * 0.30))
        var luminances: [Double] = []
        // CGContext's first bitmap row is the top of this unflipped image draw.
        for y in 0..<rows {
            for x in 0..<width {
                let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                guard wordmarkRegion.contains(point) || navigationRegion.contains(point) else { continue }
                let offset = (y * width + x) * 4
                func linear(_ byte: UInt8) -> Double {
                    let value = Double(byte) / 255
                    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                luminances.append(0.2126 * linear(pixels[offset]) + 0.7152 * linear(pixels[offset + 1])
                                  + 0.0722 * linear(pixels[offset + 2]))
            }
        }
        guard !luminances.isEmpty else { return nil }
        luminances.sort()
        return luminances[Int(Double(luminances.count - 1) * 0.90)]
    }

    private static func map(
        _ value: Double,
        from source: (low: Double, high: Double),
        to target: (low: Double, high: Double)
    ) -> Double {
        guard source.high > source.low else { return target.low }
        let fraction = min(1, max(0, (value - source.low) / (source.high - source.low)))
        return target.low + fraction * (target.high - target.low)
    }
}
