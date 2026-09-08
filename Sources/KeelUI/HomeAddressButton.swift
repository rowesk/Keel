import SwiftUI

/// The capsule on the lawn when no live field is supplied (previews and the
/// snapshot suite). In the app the address palette's own field row sits here,
/// wearing the same chrome, so typing happens in place.
struct HomeAddressButton: View {
    let actions: KeelHomeActions
    /// Work waiting behind the field. Open remains an explicit address action.
    let queueIsHolding: Bool

    @State private var isHovering = false

    var body: some View {
        Button {
            actions.perform(.openAddress)
        } label: {
            HStack(spacing: KeelDesign.Space.snug) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(KeelDesign.Surface.inkSecondary)
                    .frame(width: 16)

                Text("Search or enter address")
                    .font(.system(size: 15))
                    .foregroundStyle(KeelDesign.Surface.inkSecondary)

                Spacer(minLength: KeelDesign.Space.snug)

                Text("⌘L")
                    .font(KeelDesign.Text.numeric)
                    .foregroundStyle(KeelDesign.Surface.inkTertiary)
            }
            .padding(.horizontal, KeelDesign.Space.comfortable)
            .frame(height: KeelDesign.capsuleHeight)
            .modifier(KeelCapsuleChrome(isActive: isHovering))
            .contentShape(RoundedRectangle(cornerRadius: KeelDesign.Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(KeelDesign.Motion.stateChange, value: isHovering)
        .accessibilityLabel("Search or enter an address")
        .accessibilityHint("Opens the address palette")
    }
}
