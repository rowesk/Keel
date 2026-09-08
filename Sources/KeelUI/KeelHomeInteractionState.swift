import Foundation

/// The keyboard state used by Home's queue. It is separate from SwiftUI so the
/// selection and confirmation rules can be tested without creating a window.
public struct KeelHomeInteractionState: Equatable, Sendable {
    public private(set) var selectedQueueIDs: Set<UUID>
    public private(set) var focusedQueueID: UUID?
    public private(set) var pendingDeletion: KeelQueueDeletionRequest?

    public init(selectedQueueIDs: Set<UUID> = [], focusedQueueID: UUID? = nil) {
        self.selectedQueueIDs = selectedQueueIDs
        self.focusedQueueID = focusedQueueID
    }

    public mutating func selectQueueItem(_ id: UUID, extendsSelection: Bool = false) {
        if extendsSelection {
            if selectedQueueIDs.contains(id) {
                selectedQueueIDs.remove(id)
            } else {
                selectedQueueIDs.insert(id)
            }
        } else {
            selectedQueueIDs = [id]
        }
        focusedQueueID = id
    }

    public mutating func clearSelection() {
        selectedQueueIDs.removeAll()
        focusedQueueID = nil
    }

    public mutating func replaceSelection(_ ids: Set<UUID>) {
        selectedQueueIDs = ids
        focusedQueueID = ids.first
    }

    public mutating func pruneSelection(to validIDs: Set<UUID>) {
        selectedQueueIDs = selectedQueueIDs.intersection(validIDs)
        if let focusedQueueID, validIDs.contains(focusedQueueID) {
            self.focusedQueueID = focusedQueueID
        } else {
            self.focusedQueueID = selectedQueueIDs.first
        }
    }

    @discardableResult
    public mutating func handle(
        _ key: KeelHomeKey,
        queueIDs: [UUID]
    ) -> KeelHomeAction? {
        switch key {
        case .moveUp:
            moveFocus(offset: -1, queueIDs: queueIDs)
            return nil
        case .moveDown:
            moveFocus(offset: 1, queueIDs: queueIDs)
            return nil
        case .submit:
            guard let focusedQueueID else { return nil }
            return .selectQueueItem(focusedQueueID)
        case .escape:
            escape()
            return nil
        case .deleteSelection:
            guard !selectedQueueIDs.isEmpty else { return nil }
            pendingDeletion = .selected(selectedQueueIDs)
            return nil
        case .clearQueue:
            guard !queueIDs.isEmpty else { return nil }
            pendingDeletion = .all
            return nil
        }
    }

    public mutating func confirmPendingDeletion() -> KeelHomeAction? {
        guard let pendingDeletion else { return nil }
        self.pendingDeletion = nil
        clearSelection()
        switch pendingDeletion {
        case let .selected(ids): return .deleteQueueItems(ids)
        case .all: return .clearQueue
        }
    }

    public mutating func cancelPendingDeletion() {
        pendingDeletion = nil
    }

    public mutating func escape() {
        if pendingDeletion != nil {
            pendingDeletion = nil
        } else {
            clearSelection()
        }
    }

    private mutating func moveFocus(offset: Int, queueIDs: [UUID]) {
        guard !queueIDs.isEmpty else {
            clearSelection()
            return
        }

        let currentIndex: Int
        if let focusedQueueID, let index = queueIDs.firstIndex(of: focusedQueueID) {
            currentIndex = index
        } else {
            currentIndex = offset < 0 ? queueIDs.count : -1
        }
        let nextIndex = min(max(currentIndex + offset, 0), queueIDs.count - 1)
        let nextID = queueIDs[nextIndex]
        focusedQueueID = nextID
        selectedQueueIDs = [nextID]
    }
}
