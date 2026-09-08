import SwiftUI

public struct DownloadsView: View {
    private let model: KeelDownloadModel
    private let actions: KeelDownloadActions
    @State private var interactionState: KeelDownloadInteractionState
    @State private var isShowingConfirmation = false

    public init(model: KeelDownloadModel = KeelDownloadModel(), actions: KeelDownloadActions = KeelDownloadActions()) {
        self.model = model
        self.actions = actions
        _interactionState = State(initialValue: KeelDownloadInteractionState())
    }

    public var body: some View {
        ManagementScreenScaffold(
            title: "Downloads",
            systemImage: "arrow.down.circle",
            subtitle: "Downloads continue after a page closes. Removing a record leaves the file on disk.",
            onDismiss: { actions.perform(.dismiss) }
        ) {
            if !interactionState.selectedIDs.isEmpty {
                Button("Remove \(interactionState.selectedIDs.count) selected") {
                    requestSelectedDeletion()
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
            Button("Remove all") {
                requestAllDeletion()
            }
            .buttonStyle(.link)
            .foregroundStyle(.secondary)
            .controlSize(.small)
            .disabled(model.isEmpty)
        } content: {
            if model.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Files you download stay listed here after the page that started them closes.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                downloadsList
            }
        }
        .confirmationDialog(
            interactionState.pendingDeletion?.title ?? "Confirm download deletion",
            isPresented: $isShowingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove record", role: .destructive) {
                confirmPendingDeletion()
            }
            Button("Cancel", role: .cancel) {
                interactionState.cancelPendingDeletion()
                isShowingConfirmation = false
            }
        } message: {
            Text("Removing a record does not delete the downloaded file.")
        }
        .onExitCommand {
            handleEscape()
        }
        .onChange(of: model.itemIDs) { _, itemIDs in
            interactionState.pruneSelection(to: Set(itemIDs))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Downloads")
    }

    private var downloadsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.items) { item in
                    DownloadRowView(
                        item: item,
                        isSelected: interactionState.selectedIDs.contains(item.id),
                        isFocused: interactionState.focusedID == item.id,
                        onToggleSelection: { toggleSelection(for: item.id) },
                        onOpen: { actions.perform(.open(item.id)) },
                        onShowInFinder: { actions.perform(.showInFinder(item.id)) },
                        onCancel: { actions.perform(.cancel(item.id)) },
                        onDelete: { requestRecordDeletion(item.id) }
                    )
                    if item.id != model.items.last?.id {
                        Divider()
                            .overlay(KeelDesign.Surface.hairline)
                            .padding(.leading, 44)
                    }
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
            .padding(.vertical, KeelDesign.Inset.screenVertical)
        }
        .scrollIndicators(.automatic)
        .onMoveCommand { direction in
            let key: KeelDownloadKey?
            switch direction {
            case .up: key = .moveUp
            case .down: key = .moveDown
            default: key = nil
            }
            if let key {
                _ = interactionState.handle(key, itemIDs: model.itemIDs)
            }
        }
        .onKeyPress(.return) {
            guard let action = interactionState.handle(.submit, itemIDs: model.itemIDs) else {
                return .ignored
            }
            actions.perform(action)
            return .handled
        }
        .onExitCommand {
            handleEscape()
        }
    }

    private func toggleSelection(for id: UUID) {
        interactionState.focus(id)
        interactionState.toggle(id, isSelected: !interactionState.selectedIDs.contains(id))
    }

    private func requestRecordDeletion(_ id: UUID) {
        interactionState.requestRecordDeletion(id)
        isShowingConfirmation = true
    }

    private func requestSelectedDeletion() {
        interactionState.requestSelectedDeletion()
        isShowingConfirmation = interactionState.pendingDeletion != nil
    }

    private func requestAllDeletion() {
        interactionState.requestAllDeletion()
        isShowingConfirmation = !model.isEmpty
    }

    private func confirmPendingDeletion() {
        if let action = interactionState.confirmPendingDeletion() {
            actions.perform(action)
        }
        isShowingConfirmation = false
    }

    private func handleEscape() {
        if let action = interactionState.escape() {
            actions.perform(action)
        }
        if interactionState.pendingDeletion == nil {
            isShowingConfirmation = false
        }
    }
}

#Preview {
    DownloadsView(model: KeelDownloadModel.fixture(count: 5))
        .frame(width: 820, height: 620)
}
