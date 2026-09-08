public struct KeelSettingsActions: Sendable {
    public let perform: @MainActor @Sendable (KeelSettingsAction) -> Void

    public init(perform: @escaping @MainActor @Sendable (KeelSettingsAction) -> Void = { _ in }) {
        self.perform = perform
    }
}
