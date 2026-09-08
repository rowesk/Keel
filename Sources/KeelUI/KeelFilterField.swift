import SwiftUI

/// A compact filter field for a management screen header. Keel builds its own
/// rather than using `.searchable`, which needs a navigation container the
/// single-surface screens do not have.
struct KeelFilterField: View {
    @Binding var text: String
    let prompt: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: KeelDesign.Space.tight) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(KeelDesign.Text.detail)
                .focused($isFocused)
                .frame(width: 130)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, KeelDesign.Space.snug)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: KeelDesign.Radius.row)
                .fill(KeelDesign.Surface.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: KeelDesign.Radius.row)
                .strokeBorder(
                    isFocused ? KeelDesign.Surface.accent.opacity(0.6) : KeelDesign.Surface.hairline,
                    lineWidth: 1
                )
        )
        .animation(KeelDesign.Motion.stateChange, value: isFocused)
        .accessibilityLabel(prompt)
    }
}
