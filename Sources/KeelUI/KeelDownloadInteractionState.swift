import Foundation

public struct KeelDownloadInteractionState: Equatable, Sendable {
    public private(set) var selectedIDs: Set<UUID>
    public private(set) var focusedID: UUID?
    public private(set) var pendingDeletion: KeelDownloadDeletionRequest?

    public init(selectedIDs: Set<UUID> = [], focusedID: UUID? = nil) {
        self.selectedIDs = selectedIDs
        self.focusedID = focusedID
    }

    public mutating func toggle(_ id: UUID, isSelected: Bool) {
        if isSelected {
            selectedIDs.insert(id)
        } else {
            selectedIDs.remove(id)
        }
    }

    public mutating func pruneSelection(to validIDs: Set<UUID>) {
        selectedIDs = selectedIDs.intersection(validIDs)
        if let focusedID, !validIDs.contains(focusedID) {
            self.focusedID = selectedIDs.first
        }
    }

    public mutating func focus(_ id: UUID) {
        focusedID = id
    }

    @discardableResult
    public mutating func handle(_ key: KeelDownloadKey, itemIDs: [UUID]) -> KeelDownloadAction? {
        switch key {
        case .moveUp:
            moveFocus(offset: -1, itemIDs: itemIDs)
            return nil
        case .moveDown:
            moveFocus(offset: 1, itemIDs: itemIDs)
            return nil
        case .submit:
            guard let focusedID else { return nil }
            return .open(focusedID)
        case .escape:
            return escape()
        }
    }

    public mutating func requestRecordDeletion(_ id: UUID) {
        pendingDeletion = .record(id)
    }

    public mutating func requestSelectedDeletion() {
        guard !selectedIDs.isEmpty else { return }
        pendingDeletion = .selected(selectedIDs)
    }

    public mutating func requestAllDeletion() {
        pendingDeletion = .all
    }

    @discardableResult
    public mutating func confirmPendingDeletion() -> KeelDownloadAction? {
        guard let pendingDeletion else { return nil }
        self.pendingDeletion = nil
        selectedIDs.removeAll()
        switch pendingDeletion {
        case let .record(id): return .deleteRecords([id])
        case let .selected(ids): return .deleteRecords(ids)
        case .all: return .deleteAllRecords
        }
    }

    public mutating func cancelPendingDeletion() {
        pendingDeletion = nil
    }

    @discardableResult
    public mutating func escape() -> KeelDownloadAction? {
        if pendingDeletion != nil {
            pendingDeletion = nil
            return nil
        } else if !selectedIDs.isEmpty || focusedID != nil {
            selectedIDs.removeAll()
            focusedID = nil
            return nil
        } else {
            return .dismiss
        }
    }

    private mutating func moveFocus(offset: Int, itemIDs: [UUID]) {
        guard !itemIDs.isEmpty else {
            focusedID = nil
            return
        }

        let currentIndex: Int
        if let focusedID, let index = itemIDs.firstIndex(of: focusedID) {
            currentIndex = index
        } else {
            currentIndex = offset < 0 ? itemIDs.count : -1
        }
        focusedID = itemIDs[min(max(currentIndex + offset, 0), itemIDs.count - 1)]
    }
}
