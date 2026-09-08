import SwiftUI

/// The screen's one prominent act. Loden fill, paper text. If two of these
/// are visible at once, one of them is wrong.
struct KeelProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(KeelDesign.Surface.onAccent)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(KeelDesign.Surface.accentFill)
                    .opacity(configuration.isPressed ? 0.82 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A secondary act: ink text on a hairline. Never competes with the fill.
struct KeelQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(KeelDesign.Surface.ink.opacity(configuration.isPressed ? 0.6 : 0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(KeelDesign.Surface.hairline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A bare verb in text. For acts that should barely register until wanted.
struct KeelLinkButtonStyle: ButtonStyle {
    var color: Color = KeelDesign.Surface.inkSecondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(configuration.isPressed ? KeelDesign.Surface.ink : color)
            .contentShape(Rectangle())
    }
}

/// The ledger's verb: a hairline box, no fill, with the shortcut taught
/// inside it. On the photograph it is set in scrim white; on paper, in ink.
/// It replaces the accent fill as Home's primary act, so the screen no longer
/// needs a colour to say what to press.
struct KeelOutlineButtonStyle: ButtonStyle {
    enum Tone { case scrim, ink }

    var tone: Tone = .scrim
    var hint: String? = nil

    private var foreground: Color {
        tone == .scrim ? KeelDesign.Surface.scrimText : KeelDesign.Surface.ink
    }

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
            if let hint {
                Text(hint)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .opacity(0.5)
            }
        }
        .foregroundStyle(foreground.opacity(configuration.isPressed ? 0.7 : 1))
        .padding(.leading, 12)
        .padding(.trailing, hint == nil ? 12 : 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(foreground.opacity(configuration.isPressed ? 0.12 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(foreground.opacity(tone == .scrim ? 0.3 : 0.22), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
