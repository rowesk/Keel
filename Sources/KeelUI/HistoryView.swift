import SwiftUI

public struct HistoryView: View {
    private let model: KeelHistoryModel
    private let actions: KeelHistoryActions
    @State private var interactionState: KeelHistoryInteractionState
    @State private var isShowingConfirmation = false
    @State private var query = ""

    public init(model: KeelHistoryModel = KeelHistoryModel(), actions: KeelHistoryActions = KeelHistoryActions()) {
        self.model = model
        self.actions = actions
        _interactionState = State(initialValue: KeelHistoryInteractionState())
    }

    public var body: some View {
        ManagementScreenScaffold(
            title: "History",
            systemImage: "clock",
            subtitle: "Grouped by browsing session. Deleting History leaves cookies and website data intact.",
            onDismiss: { actions.perform(.dismiss) }
        ) {
            KeelFilterField(text: $query, prompt: "Search")
            if !interactionState.selectedVisitIDs.isEmpty {
                Button("Delete \(interactionState.selectedVisitIDs.count) selected") {
                    requestSelectedDeletion()
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
            Button("Delete all") {
                requestAllDeletion()
            }
            .buttonStyle(.link)
            .foregroundStyle(KeelDesign.Surface.inkSecondary)
            .controlSize(.small)
            .disabled(!model.hasAnyHistory)
        } content: {
            content
        }
        .confirmationDialog(
            interactionState.pendingDeletion?.confirmationTitle ?? "Confirm History deletion",
            isPresented: $isShowingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                confirmPendingDeletion()
            }
            Button("Cancel", role: .cancel) {
                interactionState.cancelPendingDeletion()
                isShowingConfirmation = false
            }
        } message: {
            Text(interactionState.pendingDeletion?.confirmationMessage ?? "")
        }
        .onExitCommand {
            handleEscape()
        }
        // The field asks the Store, so a query reaches visits no page loaded.
        // The wait collapses a burst of keystrokes into one request.
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != model.searchQuery else { return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            actions.perform(.search(trimmed))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("History")
    }

    @ViewBuilder
    private var content: some View {
        if model.isSearchActive {
            if model.sessions.isEmpty && !model.isSearching {
                ContentUnavailableView(
                    "No matches",
                    systemImage: "magnifyingglass",
                    description: Text("Nothing in History matches \"\(model.searchQuery)\".")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                historyList
            }
        } else if model.isEmpty {
            ContentUnavailableView(
                "No History",
                systemImage: "clock",
                description: Text("Pages you visit appear here. Keel keeps History on this Mac until you delete it.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            historyList
        }
    }

    /// The loaded page, or the search results, newest first.
    private var orderedSessions: [KeelHistorySession] {
        model.sessions.sorted { $0.startedAt > $1.startedAt }
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: KeelDesign.Space.loose, pinnedViews: [.sectionHeaders]) {
                ForEach(dayGroups, id: \.key) { group in
                    Section {
                        VStack(alignment: .leading, spacing: KeelDesign.Space.regular) {
                            ForEach(group.sessions) { session in
                                HistorySessionView(
                                    session: session,
                                    selectedVisitIDs: interactionState.selectedVisitIDs,
                                    focusedVisitID: interactionState.focusedVisitID,
                                    onToggleVisit: toggleVisit,
                                    onFocusVisit: { interactionState.focusVisit($0) },
                                    onOpenVisit: { actions.perform(.openVisit($0)) },
                                    onDeleteVisit: requestVisitDeletion,
                                    onDeleteGroup: requestGroupDeletion,
                                    onDeleteSession: requestSessionDeletion
                                )
                            }
                        }
                    } header: {
                        Text(group.key)
                            .font(KeelDesign.Text.sectionTitle)
                            .foregroundStyle(KeelDesign.Surface.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, KeelDesign.Space.tight)
                            .padding(.horizontal, KeelDesign.Inset.screenHorizontal)
                            .background(KeelDesign.Surface.canvas)
                    }
                }

                listFooter
            }
            .padding(.bottom, KeelDesign.Space.section)
        }
        .scrollIndicators(.automatic)
        .onMoveCommand { direction in
            let key: KeelHistoryKey?
            switch direction {
            case .up: key = .moveUp
            case .down: key = .moveDown
            default: key = nil
            }
            if let key {
                _ = interactionState.handle(key, visitIDs: model.allVisitIDs)
            }
        }
        .onKeyPress(.return) {
            guard let action = interactionState.handle(.submit, visitIDs: model.allVisitIDs) else {
                return .ignored
            }
            actions.perform(action)
            return .handled
        }
        .onExitCommand {
            handleEscape()
        }
    }

    /// History loads one page at a time, so the end of the list is where the
    /// reader asks for the rest. A button rather than a scroll trigger keeps the
    /// request reachable from the keyboard.
    @ViewBuilder
    private var listFooter: some View {
        if model.isSearchActive {
            if model.searchReachedLimit {
                Text("Showing the newest matches. Narrow the search to see older ones.")
                    .font(KeelDesign.Text.detail)
                    .foregroundStyle(KeelDesign.Surface.inkSecondary)
                    .padding(.horizontal, KeelDesign.Inset.screenHorizontal)
            }
        } else if model.hasOlderSessions {
            HStack(spacing: KeelDesign.Space.snug) {
                Button("Load older") {
                    actions.perform(.loadOlderSessions)
                }
                .controlSize(.small)
                .disabled(model.isLoadingOlderSessions)

                if model.isLoadingOlderSessions {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, KeelDesign.Inset.screenHorizontal)
            .accessibilityHint("Loads the next page of browsing sessions.")
        }
    }

    /// "Today", "Yesterday", then a date. A flat list of sessions all labelled
    /// "Browsing session" gave the reader nothing to navigate by.
    private var dayGroups: [(key: String, sessions: [KeelHistorySession])] {
        var order: [String] = []
        var buckets: [String: [KeelHistorySession]] = [:]
        for session in orderedSessions {
            let key = Self.dayLabel(for: session.startedAt)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(session)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    static func dayLabel(for date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func toggleVisit(_ id: UUID) {
        interactionState.toggleVisit(id, isSelected: !interactionState.selectedVisitIDs.contains(id))
    }

    private func requestVisitDeletion(_ id: UUID) {
        interactionState.requestVisitDeletion(id)
        isShowingConfirmation = true
    }

    private func requestSelectedDeletion() {
        interactionState.requestSelectedDeletion()
        isShowingConfirmation = interactionState.pendingDeletion != nil
    }

    private func requestGroupDeletion(_ group: KeelHistoryHostnameGroup) {
        interactionState.requestGroupDeletion(sessionID: group.sessionID, branchID: group.branchID, groupID: group.id)
        isShowingConfirmation = true
    }

    private func requestSessionDeletion(_ id: UUID) {
        interactionState.requestSessionDeletion(id)
        isShowingConfirmation = true
    }

    private func requestAllDeletion() {
        interactionState.requestAllDeletion()
        isShowingConfirmation = model.hasAnyHistory
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
    HistoryView(model: .fixture(sessionCount: 3, visitsPerSession: 4))
        .frame(width: 880, height: 700)
}
