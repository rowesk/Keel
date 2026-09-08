import SwiftUI

struct HistorySessionView: View {
    let session: KeelHistorySession
    let selectedVisitIDs: Set<UUID>
    let focusedVisitID: UUID?
    let onToggleVisit: (UUID) -> Void
    let onFocusVisit: (UUID) -> Void
    let onOpenVisit: (UUID) -> Void
    let onDeleteVisit: (UUID) -> Void
    let onDeleteGroup: (KeelHistoryHostnameGroup) -> Void
    let onDeleteSession: (UUID) -> Void

    @State private var isHoveringHeader = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ForEach(session.groups) { group in
                HistoryHostnameGroupView(
                    group: group,
                    selectedVisitIDs: selectedVisitIDs,
                    focusedVisitID: focusedVisitID,
                    onToggleVisit: onToggleVisit,
                    onFocusVisit: onFocusVisit,
                    onOpenVisit: onOpenVisit,
                    onDeleteVisit: onDeleteVisit,
                    onDeleteGroup: onDeleteGroup
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: KeelDesign.Radius.card)
                .fill(KeelDesign.Surface.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: KeelDesign.Radius.card)
                .strokeBorder(KeelDesign.Surface.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: KeelDesign.Radius.card))
        .padding(.horizontal, KeelDesign.Inset.screenHorizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Browsing session, \(summary), \(session.visits.count) visit\(session.visits.count == 1 ? "" : "s")"
        )
    }

    private var header: some View {
        HStack(spacing: KeelDesign.Space.snug) {
            Text(timeRange)
                .font(KeelDesign.Text.detail)
                .foregroundStyle(KeelDesign.Surface.inkSecondary)
                .monospacedDigit()

            Text(summary)
                .font(KeelDesign.Text.detail)
                .foregroundStyle(KeelDesign.Surface.inkSecondary)
                .lineLimit(1)

            Spacer(minLength: KeelDesign.Space.snug)

            if isHoveringHeader {
                RowActionButton(title: "Delete this session", systemImage: "trash", isDestructive: true) {
                    onDeleteSession(session.id)
                }
            }
        }
        .padding(.horizontal, KeelDesign.Space.regular)
        .padding(.vertical, KeelDesign.Space.snug)
        .frame(minHeight: 30)
        .background(KeelDesign.Surface.rowHover.opacity(0.5))
        .contentShape(Rectangle())
        .onHover { isHoveringHeader = $0 }
        .contextMenu {
            Button("Delete This Session", role: .destructive) {
                onDeleteSession(session.id)
            }
        }
    }

    /// Names the session by where it went, because every session header
    /// previously read "Browsing session" and told the reader nothing.
    private var summary: String {
        let hostnames = session.groups.map(\.hostname)
        var seen: Set<String> = []
        let unique = hostnames.filter { seen.insert($0).inserted }
        switch unique.count {
        case 0: return "No visits"
        case 1, 2: return unique.joined(separator: ", ")
        default: return "\(unique.prefix(2).joined(separator: ", ")) and \(unique.count - 2) more"
        }
    }

    private var timeRange: String {
        let start = session.startedAt.formatted(date: .omitted, time: .shortened)
        guard let endedAt = session.endedAt,
              endedAt.timeIntervalSince(session.startedAt) > 60
        else { return start }
        return "\(start) – \(endedAt.formatted(date: .omitted, time: .shortened))"
    }
}
