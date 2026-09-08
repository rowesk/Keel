public struct KeelHistoryActions: Sendable {
    public let perform: @MainActor @Sendable (KeelHistoryAction) -> Void

    public init(perform: @escaping @MainActor @Sendable (KeelHistoryAction) -> Void = { _ in }) {
        self.perform = perform
    }
}
