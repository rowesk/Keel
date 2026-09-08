public struct KeelHomeActions: Sendable {
    public let perform: @MainActor @Sendable (KeelHomeAction) -> Void

    public init(perform: @escaping @MainActor @Sendable (KeelHomeAction) -> Void = { _ in }) {
        self.perform = perform
    }
}
