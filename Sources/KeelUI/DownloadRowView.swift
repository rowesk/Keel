import SwiftUI

struct DownloadRowView: View {
    let item: KeelDownloadItem
    let isSelected: Bool
    let isFocused: Bool
    let onToggleSelection: () -> Void
    let onOpen: () -> Void
    let onShowInFinder: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: KeelDesign.Space.regular) {
            Button(action: onToggleSelection) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .foregroundStyle(isSelected ? AnyShapeStyle(KeelDesign.Surface.accent) : AnyShapeStyle(KeelDesign.Surface.inkTertiary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "Deselect \(item.filename)" : "Select \(item.filename)")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename)
                    .font(KeelDesign.Text.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: KeelDesign.Space.tight) {
                    if item.status != .completed {
                        Text(item.status.label)
                            .font(KeelDesign.Text.detail)
                            .foregroundStyle(statusColor)
                        Text("·")
                            .font(KeelDesign.Text.detail)
                            .foregroundStyle(KeelDesign.Surface.inkSecondary)
                    }
                    Text(item.detailDescription)
                        .font(KeelDesign.Text.detail)
                        .foregroundStyle(KeelDesign.Surface.inkSecondary)
                        .lineLimit(1)
                    // Monospaced digits and a fixed slot, so a changing rate moves
                    // nothing else on the row.
                    if let metrics = item.progressMetricsDescription {
                        Text("·")
                            .font(KeelDesign.Text.detail)
                            .foregroundStyle(KeelDesign.Surface.inkSecondary)
                        Text(metrics)
                            .font(KeelDesign.Text.numeric)
                            .foregroundStyle(item.isStalled ? AnyShapeStyle(KeelDesign.Surface.ink) : AnyShapeStyle(KeelDesign.Surface.inkSecondary))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }

                if item.status == .completed && !item.canOpen {
                    Text("File unavailable")
                        .font(KeelDesign.Text.detail)
                        .foregroundStyle(KeelDesign.Surface.danger)
                }

                if case let .failed(message) = item.status, let message, !message.isEmpty {
                    Text(message)
                        .font(KeelDesign.Text.detail)
                        .foregroundStyle(KeelDesign.Surface.danger)
                        .lineLimit(2)
                }

                if item.status.isInProgress {
                    if let progress = item.progress {
                        ProgressView(value: progress, total: 1)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .frame(maxWidth: 260)
                            .accessibilityValue("\(Int(progress * 100)) percent")
                    } else {
                        Text("Total size unknown")
                            .font(KeelDesign.Text.detail)
                            .foregroundStyle(KeelDesign.Surface.inkSecondary)
                    }
                }
            }

            Spacer(minLength: KeelDesign.Space.snug)

            Group {
                if item.status.isInProgress {
                    RowActionButton(title: "Cancel this download", systemImage: "xmark.circle", action: onCancel)
                } else {
                    if item.canOpen {
                        Button("Open", action: onOpen)
                            .buttonStyle(KeelLinkButtonStyle(color: KeelDesign.Surface.ink))
                            .frame(minHeight: 28)
                        RowActionButton(title: "Show in Finder", systemImage: "folder", action: onShowInFinder)
                    }
                    RowActionButton(title: "Remove this record", systemImage: "trash", isDestructive: true, action: onDelete)
                }
            }
        }
        .padding(.horizontal, KeelDesign.Space.regular)
        .padding(.vertical, KeelDesign.Space.snug)
        .frame(minHeight: 46)
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
        .onTapGesture {
            if item.canOpen { onOpen() }
        }
        .contextMenu {
            if item.canOpen {
                Button("Open", action: onOpen)
                Button("Show in Finder", action: onShowInFinder)
                Divider()
            }
            if item.status.isInProgress {
                Button("Cancel Download", role: .destructive, action: onCancel)
            } else {
                Button("Remove Record", role: .destructive, action: onDelete)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.accessibilitySummary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var statusIcon: String {
        switch item.status {
        case .inProgress: "arrow.down.circle"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "slash.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .inProgress: KeelDesign.Surface.accent
        case .completed: KeelDesign.Surface.inkTertiary
        case .cancelled: KeelDesign.Surface.inkSecondary
        case .failed: KeelDesign.Surface.danger
        }
    }
}
