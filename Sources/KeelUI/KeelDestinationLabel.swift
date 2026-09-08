import SwiftUI

/// Favicon, page title, address. The shape Keel uses anywhere it names a
/// destination, so the queue, History, Undo and Resume all read the same way.
public struct KeelDestinationLabel: View {
    private let icon: KeelIconImage?
    private let primary: String
    private let secondary: String
    private let iconSize: CGFloat

    public init(
        icon: KeelIconImage?,
        primary: String,
        secondary: String,
        iconSize: CGFloat = 16
    ) {
        self.icon = icon
        self.primary = primary
        self.secondary = secondary
        self.iconSize = iconSize
    }

    public var body: some View {
        HStack(alignment: .center, spacing: KeelDesign.Space.snug) {
            KeelFaviconView(icon: icon, size: iconSize, monogramSource: secondary.isEmpty ? primary : secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(primary)
                    .font(KeelDesign.Text.rowTitle)
                    .foregroundStyle(KeelDesign.Surface.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // A row with no page title leads with its hostname. Repeating
                // that hostname underneath says nothing.
                if secondary != primary, !secondary.isEmpty {
                    Text(secondary)
                        .font(KeelDesign.Text.detail)
                        .foregroundStyle(KeelDesign.Surface.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(secondary == primary || secondary.isEmpty ? primary : "\(primary), \(secondary)")
    }
}

/// Draws a site's favicon. Without one it shows the hostname's initial on a
/// tint hashed from the hostname, so iconless rows still differ from each
/// other instead of sharing one grey globe. The box stays square either way,
/// so rows never shift when an icon arrives late.
public struct KeelFaviconView: View {
    private let icon: KeelIconImage?
    private let size: CGFloat
    private let monogramSource: String

    public init(icon: KeelIconImage?, size: CGFloat = 16, monogramSource: String = "") {
        self.icon = icon
        self.size = size
        self.monogramSource = monogramSource
    }

    public var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .transition(.opacity)
            } else {
                let host = Self.hostPrefix(of: monogramSource)
                let monogram = KeelDesign.monogram(for: host)
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(monogram.tint.opacity(0.24))
                    .overlay(
                        Text(monogram.initial)
                            .font(.system(size: size * 0.52, weight: .semibold, design: .monospaced))
                            .foregroundStyle(monogram.tint)
                    )
            }
        }
        .frame(width: size, height: size)
        .animation(KeelDesign.Motion.stateChange, value: icon)
        .accessibilityHidden(true)
    }

    /// Display addresses arrive scheme-stripped, so the host is everything up
    /// to the first slash.
    static func hostPrefix(of displayAddress: String) -> String {
        displayAddress.split(separator: "/", maxSplits: 1).first.map(String.init) ?? displayAddress
    }
}
