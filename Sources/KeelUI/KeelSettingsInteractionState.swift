import Foundation

public struct KeelSettingsInteractionState: Equatable, Sendable {
    public private(set) var hasTransientFocus: Bool
    public private(set) var pendingDeletion: KeelSettingsDeletionRequest?

    public init(
        hasTransientFocus: Bool = false,
        pendingDeletion: KeelSettingsDeletionRequest? = nil
    ) {
        self.hasTransientFocus = hasTransientFocus
        self.pendingDeletion = pendingDeletion
    }

    public mutating func markTransientFocus() {
        hasTransientFocus = true
    }

    @discardableResult
    public mutating func handle(_ key: KeelSettingsKey) -> KeelSettingsAction? {
        switch key {
        case .submit:
            return confirmPendingDeletion()
        case .escape:
            if pendingDeletion != nil {
                pendingDeletion = nil
                return nil
            }
            guard !hasTransientFocus else {
                hasTransientFocus = false
                return nil
            }
            return .dismiss
        }
    }

    public mutating func requestDiagnosticsDeletion() {
        pendingDeletion = .diagnostics
    }

    public mutating func requestHomeSceneRemoval(_ id: KeelHomeSceneID, name: String) {
        pendingDeletion = .removeHomeScene(id, name)
    }

    @discardableResult
    public mutating func confirmPendingDeletion() -> KeelSettingsAction? {
        guard let pendingDeletion else { return nil }
        self.pendingDeletion = nil
        switch pendingDeletion {
        case .diagnostics:
            return .deleteDiagnostics
        case .removeHomeScene(let id, _):
            return .removeHomeScene(id)
        }
    }

    public mutating func cancelPendingDeletion() {
        pendingDeletion = nil
    }
}
