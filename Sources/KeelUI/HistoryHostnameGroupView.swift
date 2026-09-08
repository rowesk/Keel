import SwiftUI

struct HistoryHostnameGroupView: View {
    let group: KeelHistoryHostnameGroup
    let selectedVisitIDs: Set<UUID>
    let focusedVisitID: UUID?
    let onToggleVisit: (UUID) -> Void
    let onFocusVisit: (UUID) -> Void
    let onOpenVisit: (UUID) -> Void
    let onDeleteVisit: (UUID) -> Void
    let onDeleteGroup: (KeelHistoryHostnameGroup) -> Void

    @State private var isHoveringHeader = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if group.visits.count > 1 {
                header
            }

            ForEach(group.visits) { visit in
                HistoryVisitRowView(
                    visit: visit,
                    isSelected: selectedVisitIDs.contains(visit.id),
                    isFocused: focusedVisitID == visit.id,
                    onToggle: {
                        onFocusVisit(visit.id)
                        onToggleVisit(visit.id)
                    },
                    onOpen: { onOpenVisit(visit.id) },
                    onDelete: { onDeleteVisit(visit.id) }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Visits to \(group.hostname)")
    }

    private var header: some View {
        HStack(spacing: KeelDesign.Space.tight) {
            Text(group.hostname)
                .font(KeelDesign.Text.detail)
                .foregroundStyle(KeelDesign.Surface.inkSecondary)
            Text("\(group.visits.count)")
                .font(KeelDesign.Text.numeric)
                .foregroundStyle(KeelDesign.Surface.inkSecondary)

            Spacer(minLength: KeelDesign.Space.snug)

            if isHoveringHeader {
                RowActionButton(title: "Delete these \(group.visits.count) visits", systemImage: "trash", isDestructive: true) {
                    onDeleteGroup(group)
                }
            }
        }
        .padding(.horizontal, KeelDesign.Space.regular)
        .padding(.top, KeelDesign.Space.snug)
        .padding(.bottom, 2)
        .frame(minHeight: 24)
        .contentShape(Rectangle())
        .onHover { isHoveringHeader = $0 }
        .contextMenu {
            Button("Delete These Visits", role: .destructive) {
                onDeleteGroup(group)
            }
        }
    }
}
