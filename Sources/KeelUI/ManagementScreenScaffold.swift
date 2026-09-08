import SwiftUI

/// The frame every management screen sits in: a serif title, a description,
/// whatever actions belong to the whole screen, and a Done control. The same
/// warm paper as the panels over the scene, without the scene.
struct ManagementScreenScaffold<Actions: View, Content: View>: View {
    let title: String
    let systemImage: String
    let subtitle: String?
    let onDismiss: () -> Void
    @ViewBuilder let screenActions: Actions
    @ViewBuilder let content: Content

    init(
        title: String,
        systemImage: String,
        subtitle: String? = nil,
        onDismiss: @escaping () -> Void,
        @ViewBuilder screenActions: () -> Actions = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.onDismiss = onDismiss
        self.screenActions = screenActions()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: KeelDesign.Space.tight) {
                HStack(alignment: .firstTextBaseline, spacing: KeelDesign.Space.snug) {
                    Text(title)
                        .font(KeelDesign.Text.screenTitle)
                        .foregroundStyle(KeelDesign.Surface.ink)

                    Spacer(minLength: KeelDesign.Space.comfortable)

                    screenActions

                    // Done is these screens' one prominent act: the way back
                    // to the page.
                    Button("Done", action: onDismiss)
                        .buttonStyle(KeelProminentButtonStyle())
                        .keyboardShortcut(.escape, modifiers: [])
                        .help("Return to browsing  esc")
                }

                if let subtitle {
                    Text(subtitle)
                        .font(KeelDesign.Text.detail)
                        .foregroundStyle(KeelDesign.Surface.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, KeelDesign.Inset.screenHorizontal)
            .padding(.top, KeelDesign.Inset.screenVertical)
            .padding(.bottom, KeelDesign.Space.regular)

            Divider().overlay(KeelDesign.Surface.hairline)

            content
        }
        .background(KeelDesign.Surface.canvas.ignoresSafeArea())
        .tint(KeelDesign.Surface.accent)
    }
}

/// A visible row action with a stable pointer and keyboard target.
struct RowActionButton: View {
    let title: String
    let systemImage: String
    var isDestructive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 28, height: 28)
                .background(
                    isHovering ? KeelDesign.Surface.rowHover : .clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            isDestructive && isHovering
                ? KeelDesign.Surface.danger
                : KeelDesign.Surface.inkSecondary
        )
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}
