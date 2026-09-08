import SwiftUI

public struct SettingsView: View {
    private let model: KeelSettingsModel
    private let actions: KeelSettingsActions
    @State private var selectedProvider: KeelSearchProvider
    @State private var selectedQueueExpiry: KeelQueueExpiry
    @State private var keepClosedPageReady: Bool
    @State private var selectedAppearance: KeelAppearanceOption
    @State private var selectedPageZoom: KeelPageZoom
    @State private var selectedHomeSceneMode: KeelHomeSceneMode
    @State private var customTemplate: String
    @State private var interactionState = KeelSettingsInteractionState()
    @State private var isShowingConfirmation = false
    @FocusState private var customTemplateFocused: Bool

    public init(model: KeelSettingsModel = KeelSettingsModel(), actions: KeelSettingsActions = KeelSettingsActions()) {
        self.model = model
        self.actions = actions
        _selectedProvider = State(initialValue: model.searchProvider)
        _selectedQueueExpiry = State(initialValue: model.queueExpiry)
        _keepClosedPageReady = State(initialValue: model.keepsClosedPageReady)
        _selectedAppearance = State(initialValue: model.appearance)
        _selectedPageZoom = State(initialValue: model.defaultPageZoom)
        _selectedHomeSceneMode = State(initialValue: model.homeSceneMode)
        _customTemplate = State(initialValue: model.customSearchTemplate)
    }

    public var body: some View {
        // Split into three stages because one chain of every control binding and every
        // model-sync binding pushed the type checker past its budget.
        confirmationLayer(modelSyncLayer(controlLayer(scaffold)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Settings")
    }

    private var scaffold: some View {
        ManagementScreenScaffold(
            title: "Settings",
            systemImage: "gearshape",
            onDismiss: { actions.perform(.dismiss) }
        ) {
            EmptyView()
        } content: {
            ScrollView {
                Form {
                    searchSection
                    queueSection
                    undoSection
                    downloadsSection
                    appearanceSection
                    homeBackgroundSection
                    diagnosticsSection
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: KeelDesign.readableWidth)
                .frame(maxWidth: .infinity)
                .padding(.vertical, KeelDesign.Space.snug)
            }
            .scrollIndicators(.automatic)
        }
    }

    private func controlLayer(_ content: some View) -> some View {
        content
            .onExitCommand {
                if let action = interactionState.handle(.escape) {
                    actions.perform(action)
                } else {
                    customTemplateFocused = false
                    isShowingConfirmation = interactionState.pendingDeletion != nil
                }
            }
            .onChange(of: selectedProvider) { _, provider in
                actions.perform(.setSearchProvider(provider))
            }
            .onChange(of: selectedQueueExpiry) { _, expiry in
                actions.perform(.setQueueExpiry(expiry))
            }
            .onChange(of: keepClosedPageReady) { _, keepsReady in
                actions.perform(.setKeepsClosedPageReady(keepsReady))
            }
            .onChange(of: selectedAppearance) { _, appearance in
                actions.perform(.setAppearance(appearance))
            }
            .onChange(of: selectedPageZoom) { _, zoom in
                actions.perform(.setDefaultPageZoom(zoom))
            }
            .onChange(of: selectedHomeSceneMode) { _, sceneMode in
                actions.perform(.setHomeSceneMode(sceneMode))
            }
            .onChange(of: customTemplateFocused) { _, isFocused in
                if isFocused {
                    interactionState.markTransientFocus()
                } else {
                    // Every other control here saves on change. The template saved
                    // only on a button press, which read as one of them not working.
                    saveCustomTemplate()
                }
            }
    }

    private func modelSyncLayer(_ content: some View) -> some View {
        content
            .onChange(of: model.searchProvider) { _, provider in
                if selectedProvider != provider { selectedProvider = provider }
            }
            .onChange(of: model.queueExpiry) { _, expiry in
                if selectedQueueExpiry != expiry { selectedQueueExpiry = expiry }
            }
            .onChange(of: model.keepsClosedPageReady) { _, keepsReady in
                if keepClosedPageReady != keepsReady { keepClosedPageReady = keepsReady }
            }
            .onChange(of: model.customSearchTemplate) { _, template in
                if customTemplate != template { customTemplate = template }
            }
            .onChange(of: model.appearance) { _, appearance in
                if selectedAppearance != appearance { selectedAppearance = appearance }
            }
            .onChange(of: model.defaultPageZoom) { _, zoom in
                if selectedPageZoom != zoom { selectedPageZoom = zoom }
            }
            .onChange(of: model.homeSceneMode) { _, sceneMode in
                if selectedHomeSceneMode != sceneMode { selectedHomeSceneMode = sceneMode }
            }
    }

    private func confirmationLayer(_ content: some View) -> some View {
        content
            .confirmationDialog(
                interactionState.pendingDeletion?.confirmationTitle ?? "Confirm diagnostics deletion",
                isPresented: $isShowingConfirmation,
                titleVisibility: .visible
            ) {
                Button(interactionState.pendingDeletion?.confirmTitle ?? "Delete", role: .destructive) {
                    confirmPendingDeletion()
                }
                Button("Cancel", role: .cancel) {
                    cancelPendingDeletion()
                }
            } message: {
                Text(interactionState.pendingDeletion?.confirmationMessage ?? "")
            }
    }

    private var homeBackgroundSection: some View {
        Section {
            SettingsHomeBackgroundSection(
                model: model,
                actions: actions,
                mode: $selectedHomeSceneMode,
                onRequestRemoval: requestHomeSceneRemoval
            )
        } header: {
            Text("Home background")
        } footer: {
            Text(homeBackgroundFooter)
                .font(KeelDesign.Text.detail)
                .foregroundStyle(KeelDesign.Surface.inkSecondary)
        }
    }

    private var homeBackgroundFooter: String {
        let base = "Keel copies imported photos. Your originals stay untouched."
        guard selectedHomeSceneMode == .rotateMine, !model.hasUserHomeScenes else { return base }
        return base + " Add a photo to rotate your own; until then Keel rotates all of them."
    }

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $selectedAppearance) {
                ForEach(KeelAppearanceOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }

            Picker("Default page zoom", selection: $selectedPageZoom) {
                ForEach(KeelPageZoom.allCases) { zoom in
                    Text(zoom.label).tag(zoom)
                }
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("Default zoom applies when a page opens. Command-plus changes the current page.")
                .font(KeelDesign.Text.detail)
                .foregroundStyle(KeelDesign.Surface.inkSecondary)
        }
    }

    private var downloadsSection: some View {
        Section {
            LabeledContent("Save files to") {
                HStack(spacing: KeelDesign.Space.snug) {
                    Text(model.downloadDirectoryLabel)
                        .font(KeelDesign.Text.body)
                        .foregroundStyle(KeelDesign.Surface.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel("Current download folder, \(model.downloadDirectoryLabel)")

                    Button("Choose…") {
                        actions.perform(.chooseDownloadDirectory)
                    }

                    Button("Use Downloads") {
                        actions.perform(.useDefaultDownloadDirectory)
                    }
                    .disabled(model.downloadDirectoryPath == nil)
                }
            }
        } header: {
            Text("Downloads")
        } footer: {
            Text("New downloads save to this folder.")
                .font(KeelDesign.Text.detail)
                .foregroundStyle(KeelDesign.Surface.inkSecondary)
        }
    }

    private var searchSection: some View {
        Section {
            Picker("Search with", selection: $selectedProvider) {
                Text("Google").tag(KeelSearchProvider.google)
                Text("DuckDuckGo").tag(KeelSearchProvider.duckDuckGo)
                Text("Kagi").tag(KeelSearchProvider.kagi)
                Text("Custom").tag(KeelSearchProvider.custom)
            }

            if selectedProvider == .custom {
                TextField("Template", text: $customTemplate, prompt: Text("https://example.test/search?q={query}"))
                    .focused($customTemplateFocused)
                    .onSubmit { saveCustomTemplate() }
                    .accessibilityLabel("Custom search URL template")

                if !customTemplate.isEmpty, !KeelSettingsModel.isValidSearchTemplate(customTemplate) {
                    Label(
                        "Use {query} exactly once, over HTTP or HTTPS.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(KeelDesign.Text.detail)
                    .foregroundStyle(KeelDesign.Surface.danger)
                }
            }
        } header: {
            Text("Search")
        } footer: {
            Text(selectedProvider == .custom
                ? "Include {query} exactly once. Keel saves the template when you finish editing."
                : "Anything that is not a URL goes to this provider.")
                .font(KeelDesign.Text.detail)
                .foregroundStyle(KeelDesign.Surface.inkSecondary)
        }
    }

    private var queueSection: some View {
        Section {
            Picker("Expire after", selection: $selectedQueueExpiry) {
                ForEach(KeelQueueExpiry.allCases) { expiry in
                    Text(expiry.label).tag(expiry)
                }
            }
        } header: {
            Text("Queue")
        } footer: {
            Text("Destinations untouched past this limit expire on their own. Removals stay undoable for 60 seconds.")
                .font(KeelDesign.Text.detail)
                .foregroundStyle(KeelDesign.Surface.inkSecondary)
        }
    }

    private var undoSection: some View {
        Section {
            Toggle("Keep the closed page ready", isOn: $keepClosedPageReady)
        } header: {
            Text("Reopening")
        } footer: {
            Text("Undo keeps the last closed page in memory for ten minutes. Relaunch resume reloads unfinished work separately.")
                .font(KeelDesign.Text.detail)
                .foregroundStyle(KeelDesign.Surface.inkSecondary)
        }
    }

    private var diagnosticsSection: some View {
        Section {
            LabeledContent("Local diagnostics") {
                HStack(spacing: KeelDesign.Space.snug) {
                    Button("Export…") {
                        actions.perform(.exportDiagnostics)
                    }
                    .disabled(!model.hasDiagnostics)

                    Button("Delete", role: .destructive) {
                        requestDiagnosticsDeletion()
                    }
                    .disabled(!model.hasDiagnostics)
                }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Diagnostics never leave this Mac. They record hostnames, event types, results, timings and error codes. Never page contents, cookies, form values or full URLs.")
                .font(KeelDesign.Text.detail)
                .foregroundStyle(KeelDesign.Surface.inkSecondary)
        }
    }

    private func requestHomeSceneRemoval(_ id: KeelHomeSceneID, name: String) {
        interactionState.requestHomeSceneRemoval(id, name: name)
        isShowingConfirmation = interactionState.pendingDeletion != nil
    }

    private func requestDiagnosticsDeletion() {
        interactionState.requestDiagnosticsDeletion()
        isShowingConfirmation = interactionState.pendingDeletion != nil
    }

    private func confirmPendingDeletion() {
        if let action = interactionState.confirmPendingDeletion() {
            actions.perform(action)
        }
        isShowingConfirmation = false
    }

    private func cancelPendingDeletion() {
        interactionState.cancelPendingDeletion()
        isShowingConfirmation = false
    }

    private func saveCustomTemplate() {
        guard KeelSettingsModel.isValidSearchTemplate(customTemplate),
              customTemplate != model.customSearchTemplate
        else { return }
        actions.perform(.setCustomSearchTemplate(customTemplate))
    }
}

#Preview {
    SettingsView(model: KeelSettingsModel(searchProvider: .custom, hasDiagnostics: true))
        .frame(width: 800, height: 640)
}
