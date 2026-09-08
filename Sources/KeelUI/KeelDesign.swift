import AppKit
import CoreText
import SwiftUI

/// The one place Keel decides what a surface, a radius, or a gap is worth.
/// Every screen reads these. Nothing hard-codes a number that appears here.
public enum KeelDesign {
    /// Corner radii. Larger containers get larger radii so nesting stays legible.
    public enum Radius {
        /// Rows, chips, and anything that nests inside a card.
        public static let row: CGFloat = 7
        /// Controls that sit on their own: address field, buttons.
        public static let control: CGFloat = 11
        /// Cards, list containers, grouped sections.
        public static let card: CGFloat = 13
        /// Floating panels over content: palette, find, detour.
        public static let panel: CGFloat = 14
    }

    /// A four-point spacing ladder. Anything between two steps is a mistake.
    public enum Space {
        public static let hair: CGFloat = 2
        public static let tight: CGFloat = 4
        public static let snug: CGFloat = 8
        public static let regular: CGFloat = 12
        public static let comfortable: CGFloat = 16
        public static let loose: CGFloat = 24
        public static let section: CGFloat = 32
    }

    /// Padding applied inside containers.
    public enum Inset {
        public static let row = EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10)
        public static let card: CGFloat = 16
        public static let screenHorizontal: CGFloat = 28
        public static let screenVertical: CGFloat = 24
    }

    /// Every screen's content column stops here so lines stay readable.
    public static let readableWidth: CGFloat = 720

    /// Minimum pointer target on any control Keel draws itself.
    public static let minimumHitTarget: CGFloat = 28

    /// Riva's materials. Every neutral is warm: no colour in the system has
    /// equal red, green and blue, and system blue appears nowhere.
    public enum Surface {
        /// Management screen ground. Warm paper by day, warm near-black after.
        public static var canvas: Color { dynamic(light: 0xF3EFE6, dark: 0x17140F) }
        /// Panels, cards, the capsule, the palette.
        public static var raised: Color { dynamic(light: 0xFBF8F2, dark: 0x221D15) }
        /// A row inside a card, at rest.
        public static var row: Color { Color.clear }
        /// A row under the pointer. Colour only; nothing moves on hover.
        public static var rowHover: Color { ink.opacity(0.05) }
        /// A row the user has selected.
        public static var rowSelected: Color { dynamic(light: 0x3E4A38, dark: 0xEDE7DD, lightAlpha: 0.12, darkAlpha: 0.07) }
        /// A hairline between rows or against a panel edge.
        public static var hairline: Color { ink.opacity(0.1) }

        /// Primary text. Warm ink on paper, bone on dark.
        public static var ink: Color { dynamic(light: 0x26231C, dark: 0xEDE7DD) }
        public static var inkSecondary: Color { ink.opacity(0.72) }
        public static var inkTertiary: Color { ink.opacity(0.62) }

        /// The one accent, loden green. Roughly one appearance per screen.
        public static var accent: Color { dynamic(light: 0x3E4A38, dark: 0xA9B79B) }
        /// Fill behind the screen's single prominent button.
        public static var accentFill: Color { dynamic(light: 0x3E4A38, dark: 0x45523E) }
        /// Text on top of `accentFill`.
        public static var onAccent: Color { dynamic(light: 0xFBF8F2, dark: 0xEDE7DD) }
        /// Destructive text on hover. A warm red, not system red.
        public static var danger: Color { dynamic(light: 0x8C3B2E, dark: 0xC96A54) }
        /// Text painted directly over the photograph.
        public static var scrimText: Color { Color(red: 0.98, green: 0.973, blue: 0.949) }

        static func dynamic(
            light: Int,
            dark: Int,
            lightAlpha: CGFloat = 1,
            darkAlpha: CGFloat = 1
        ) -> Color {
            Color(nsColor: NSSurface.dynamic(light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
        }
    }

    /// The same materials for AppKit callers: the palette, the toolbar
    /// capsule, the find bar, the shelf and the error page all draw with
    /// these, so the app has one paper rather than five materials.
    public enum NSSurface {
        public static var canvas: NSColor { dynamic(light: 0xF3EFE6, dark: 0x17140F) }
        public static var raised: NSColor { dynamic(light: 0xFBF8F2, dark: 0x221D15) }
        public static var ink: NSColor { dynamic(light: 0x26231C, dark: 0xEDE7DD) }
        public static var inkSecondary: NSColor { ink.withAlphaComponent(0.72) }
        public static var inkTertiary: NSColor { ink.withAlphaComponent(0.62) }
        public static var hairline: NSColor { ink.withAlphaComponent(0.1) }
        public static var accent: NSColor { dynamic(light: 0x3E4A38, dark: 0xA9B79B) }
        public static var accentFill: NSColor { dynamic(light: 0x3E4A38, dark: 0x45523E) }
        public static var onAccent: NSColor { dynamic(light: 0xFBF8F2, dark: 0xEDE7DD) }
        public static var danger: NSColor { dynamic(light: 0x8C3B2E, dark: 0xC96A54) }
        public static var selection: NSColor {
            dynamic(light: 0x3E4A38, dark: 0xEDE7DD, lightAlpha: 0.12, darkAlpha: 0.07)
        }

        public static func dynamic(
            light: Int,
            dark: Int,
            lightAlpha: CGFloat = 1,
            darkAlpha: CGFloat = 1
        ) -> NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
            }
        }
    }

    /// The Como scene. Home only, static, never behind text without a scrim.
    public static let homeScene: NSImage? = resourceBundle?
        .url(forResource: "como", withExtension: "heic")
        .flatMap { NSImage(contentsOf: $0) }

    /// SwiftPM's generated `Bundle.module` traps when the bundle is not where
    /// the build put it, and an installed .app keeps resources under
    /// Contents/Resources instead. Look in the places the bundle actually
    /// lives, in test runs and in the shipped app alike.
    static let resourceBundle: Bundle? = {
        let bundleName = "Keel_KeelUI.bundle"
        let candidates = [
            Bundle.main.resourceURL,
            Bundle(for: KeelDesignBundleMarker.self).resourceURL,
            Bundle.main.bundleURL,
            // Test runs: the bundle sits beside the .xctest wrapper in the
            // build directory.
            Bundle(for: KeelDesignBundleMarker.self).bundleURL.deletingLastPathComponent(),
        ]
        for candidate in candidates {
            if let url = candidate?.appendingPathComponent(bundleName),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        // The direct build layout (swift run, previews) keeps resources in the
        // module bundle itself.
        return Bundle(for: KeelDesignBundleMarker.self)
    }()

    /// Register once for this process. This does not install the font on the Mac.
    private static let registerWordmarkFont: Void = {
        guard let url = resourceBundle?.url(forResource: "PalaceScriptMT-SemiBold", withExtension: "ttf") else {
            return
        }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    /// The bundled wordmark face, with system fallbacks if registration fails.
    public static func wordmarkFont(size: CGFloat) -> Font {
        _ = registerWordmarkFont
        if NSFont(name: "PalaceScriptMT-SemiBold", size: size) != nil {
            return Font.custom("PalaceScriptMT-SemiBold", size: size)
        }
        if NSFont(name: "SnellRoundhand-Bold", size: size) != nil {
            return Font.custom("SnellRoundhand-Bold", size: size)
        }
        return Font.system(size: size, design: .serif).italic()
    }

    /// A stand-in favicon: the hostname's initial on a tint hashed from the
    /// hostname, so rows without icons still differ from each other. Replaces
    /// the one grey globe that used to stand in for every unknown site.
    public static func monogram(for hostname: String) -> (initial: String, tint: Color) {
        let parts = monogramParts(for: hostname)
        return (parts.initial, Color(hue: parts.hue, saturation: 0.22, brightness: 0.52).opacity(0.9))
    }

    /// The AppKit rendering of the same monogram: initial on a rounded tint,
    /// sized for a favicon box.
    public static func monogramImage(for hostname: String, size: CGFloat) -> NSImage {
        let parts = monogramParts(for: hostname)
        let tint = NSColor(hue: parts.hue, saturation: 0.22, brightness: 0.52, alpha: 1)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
            tint.withAlphaComponent(0.24).setFill()
            path.fill()
            let font = NSFont.monospacedSystemFont(ofSize: size * 0.52, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
            let text = NSAttributedString(string: parts.initial, attributes: attributes)
            let textSize = text.size()
            text.draw(at: NSPoint(
                x: rect.midX - textSize.width / 2,
                y: rect.midY - textSize.height / 2
            ))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A stable warm-band hue per hostname: hash into 0-1, keep saturation and
    /// brightness in the muted range so no monogram shouts.
    static func monogramParts(for hostname: String) -> (initial: String, hue: Double) {
        let trimmed = hostname.hasPrefix("www.") ? String(hostname.dropFirst(4)) : hostname
        let initial = trimmed.first.map { String($0).uppercased() } ?? "•"
        var hash: UInt64 = 1469598103934665603
        for byte in trimmed.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return (initial, Double(hash % 360) / 360)
    }

    /// The type ladder. Five steps, and every screen uses the same five.
    public enum Text {
        /// A screen's name. One per screen. The serif is the print voice; the
        /// script face is reserved for the wordmark alone.
        public static let screenTitle = Font.system(size: 24, weight: .medium, design: .serif)
        /// Small-caps label voice: taglines, nav over the photo, list headers.
        public static let smallCaps = Font.system(size: 11, weight: .semibold)
        /// Tracking that goes with `smallCaps`.
        public static let smallCapsTracking: CGFloat = 1.8
        /// A section or card heading.
        public static let sectionTitle = Font.system(size: 13, weight: .semibold)
        /// A row's primary line.
        public static let rowTitle = Font.system(size: 13, weight: .medium)
        /// A row's secondary line, and body copy.
        public static let body = Font.system(size: 12)
        /// Timestamps, counts, and status.
        public static let detail = Font.system(size: 11)
        /// Queue positions and anything else that must not jitter as digits change.
        public static let numeric = Font.system(size: 11, weight: .semibold).monospacedDigit()
    }

    /// The complete motion budget. Five animations plus colour-only hovers;
    /// anything not named here renders finished on frame one. Keyboard-
    /// initiated appearances (the palette opening) are always instant.
    public enum Motion {
        /// Hover and other colour-only state changes.
        public static let quick: TimeInterval = 0.12
        /// M1: a native screen fading in over the page, or out of its way.
        public static let screenFade: TimeInterval = 0.18
        /// M2: a queue row arriving. The one moment motion teaches where a
        /// thing went.
        public static let queueEnter: TimeInterval = 0.26
        /// M3: a queue row leaving, fade then gap-close.
        public static let queueLeave: TimeInterval = 0.2
        /// M4: the palette's exit. Its entrance is frame-1 instant.
        public static let paletteExit: TimeInterval = 0.09
        /// M5: the download shelf sliding in from the edge it lives on.
        public static let shelfIn: TimeInterval = 0.24
        public static let shelfOut: TimeInterval = 0.18

        public static var stateChange: Animation { .easeInOut(duration: quick) }
        public static var queueChange: Animation { .easeOut(duration: queueEnter) }
    }

    /// Panel shadows. AppKit callers build these with an explicit path so the
    /// silhouette follows the rounded rect instead of the layer's square bounds.
    public enum Shadow {
        /// Tight and dark. Gives an edge its contact with the surface beneath.
        public static let ambientRadius: CGFloat = 2
        public static let ambientOpacity: Float = 0.10
        public static let ambientOffset = CGSize(width: 0, height: -1)

        /// Soft and close. Wide enough to lift, tight enough to stay a shadow
        /// rather than a smudge under the panel.
        public static let keyRadius: CGFloat = 16
        public static let keyOpacity: Float = 0.16
        public static let keyOffset = CGSize(width: 0, height: -5)
    }
}

/// Anchors `Bundle(for:)` to this module so the resource lookup finds the
/// KeelUI bundle wherever the build system placed it.
private final class KeelDesignBundleMarker {}

extension NSColor {
    /// `0xRRGGBB` in sRGB. Every Riva colour routes through here so the
    /// palette stays auditable as a list of hex values.
    convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Wraps an `NSImage` so presentation models can carry a favicon while staying
/// `Sendable`. Keel only ever reads these on the main actor.
public struct KeelIconImage: @unchecked Sendable, Equatable, Hashable {
    public let image: NSImage

    public init(_ image: NSImage) {
        self.image = image
    }

    public static func == (lhs: KeelIconImage, rhs: KeelIconImage) -> Bool {
        lhs.image === rhs.image
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(image))
    }
}

public extension Date {
    /// "just now", "12 min ago", "3 hr ago", then a date. Keel prefers elapsed
    /// time to wall-clock time everywhere a duration is what the user is judging.
    func keelRelativeDescription(from reference: Date = .now) -> String {
        let elapsed = reference.timeIntervalSince(self)
        if elapsed < 0 {
            return formatted(date: .omitted, time: .shortened)
        }
        if elapsed < 45 {
            return "just now"
        }
        if elapsed < 3600 {
            return "\(max(1, Int(elapsed / 60))) min ago"
        }
        if elapsed < 86_400 {
            return "\(Int(elapsed / 3600)) hr ago"
        }
        if elapsed < 7 * 86_400 {
            return "\(Int(elapsed / 86_400)) days ago"
        }
        return formatted(date: .abbreviated, time: .omitted)
    }

    /// A countdown for an affordance that will expire. Returns nil once it has.
    func keelCountdownDescription(from reference: Date = .now) -> String? {
        let remaining = timeIntervalSince(reference)
        guard remaining > 0 else { return nil }
        if remaining < 60 {
            return "\(Int(remaining))s left"
        }
        return "\(Int(remaining / 60)) min left"
    }
}

public extension String {
    /// Strips the scheme, any `www.`, and a bare trailing slash so a URL can be
    /// read as a place rather than parsed as a string. Keel never shows
    /// `absoluteString` as a row's primary text.
    var keelDisplayAddress: String {
        var value = self
        for scheme in ["https://", "http://"] where value.hasPrefix(scheme) {
            value.removeFirst(scheme.count)
        }
        if value.hasPrefix("www.") {
            value.removeFirst(4)
        }
        if value.hasSuffix("/"), value.dropLast().contains("/") == false {
            value.removeLast()
        }
        return value
    }
}

public extension EnvironmentValues {
    /// Freezes what "now" means for anything that would otherwise tick.
    ///
    /// Production leaves this nil, so countdowns update themselves through
    /// SwiftUI's own timer text. Previews and snapshot rendering set it so the
    /// same state produces the same pixels every time.
    @Entry var keelFixedNow: Date? = nil
}
