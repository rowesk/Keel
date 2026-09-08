import SwiftUI

/// The corner of the scene that leads elsewhere. Words, not icon buttons:
/// three small-caps links that sit quietly on the photograph.
struct HomeHeaderView: View {
    let actions: KeelHomeActions

    var body: some View {
        HStack(spacing: KeelDesign.Space.loose) {
            Spacer(minLength: 0)

            HStack(spacing: KeelDesign.Space.loose) {
                HomeSceneLink(title: "History", shortcut: "⌘Y") { actions.perform(.showHistory) }
                HomeSceneLink(title: "Downloads", shortcut: "⌥⌘L") { actions.perform(.showDownloads) }
                HomeSceneLink(title: "Settings", shortcut: "⌘,") { actions.perform(.showSettings) }
            }

        }
        .padding(.horizontal, KeelDesign.Space.loose)
        .padding(.top, KeelDesign.Space.comfortable)
    }
}

private struct HomeSceneLink: View {
    let title: String
    let shortcut: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(KeelDesign.Text.smallCaps)
                .tracking(KeelDesign.Text.smallCapsTracking)
                .foregroundStyle(KeelDesign.Surface.scrimText)
                .shadow(color: .black.opacity(0.4), radius: 5, y: 1)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(KeelDesign.Motion.stateChange, value: isHovering)
        .help("\(title)  \(shortcut)")
        .accessibilityLabel(title)
    }
}
