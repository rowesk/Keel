import SwiftUI

struct HistoryVisitRowView: View {
    let visit: KeelHistoryVisit
    let isSelected: Bool
    let isFocused: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: KeelDesign.Space.snug) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .foregroundStyle(isSelected ? AnyShapeStyle(KeelDesign.Surface.accent) : AnyShapeStyle(KeelDesign.Surface.inkTertiary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "Deselect \(visit.primaryText)" : "Select \(visit.primaryText)")

            KeelDestinationLabel(
                icon: visit.icon,
                primary: visit.primaryText,
                secondary: visit.secondaryText,
                iconSize: 14
            )

            Spacer(minLength: KeelDesign.Space.snug)

            Text(visit.visitedAt.formatted(date: .omitted, time: .shortened))
                .font(KeelDesign.Text.detail)
                .foregroundStyle(KeelDesign.Surface.inkSecondary)
                .monospacedDigit()
            RowActionButton(title: "Open", systemImage: "arrow.up.forward", action: onOpen)
            RowActionButton(title: "Delete this visit", systemImage: "trash", isDestructive: true, action: onDelete)
        }
        .padding(.horizontal, KeelDesign.Space.regular)
        .padding(.vertical, 5)
        .frame(minHeight: 34)
        .background(
            isSelected ? KeelDesign.Surface.rowSelected
                : isHovering ? KeelDesign.Surface.rowHover
                : KeelDesign.Surface.row
        )
        .overlay(alignment: .leading) {
            if isFocused {
                Rectangle().fill(KeelDesign.Surface.accent).frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onOpen() }
        .contextMenu {
            Button("Open", action: onOpen)
            Divider()
            Button("Delete This Visit", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(visit.primaryText), \(visit.secondaryText)")
        .accessibilityValue("Visited \(visit.visitedAt.keelRelativeDescription())")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Open this visit, or use Select to mark it for deletion.")
        .accessibilityAction { onOpen() }
    }
}
