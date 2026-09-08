public struct KeelDownloadActions: Sendable {
    public let perform: @MainActor @Sendable (KeelDownloadAction) -> Void

    public init(perform: @escaping @MainActor @Sendable (KeelDownloadAction) -> Void = { _ in }) {
        self.perform = perform
    }
}
