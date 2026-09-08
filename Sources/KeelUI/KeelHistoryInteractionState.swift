import Foundation

public struct KeelHistoryInteractionState: Equatable, Sendable {
    public private(set) var selectedVisitIDs: Set<UUID>
    public private(set) var focusedVisitID: UUID?
    public private(set) var pendingDeletion: KeelHistoryDeletionRequest?

    public init(selectedVisitIDs: Set<UUID> = [], focusedVisitID: UUID? = nil) {
        self.selectedVisitIDs = selectedVisitIDs
        self.focusedVisitID = focusedVisitID
    }

    public mutating func replaceSelection(_ ids: Set<UUID>) {
        selectedVisitIDs = ids
    }

    public mutating func focusVisit(_ id: UUID) {
        focusedVisitID = id
    }

    @discardableResult
    public mutating func handle(_ key: KeelHistoryKey, visitIDs: [UUID]) -> KeelHistoryAction? {
        switch key {
        case .moveUp:
            moveFocus(offset: -1, visitIDs: visitIDs)
            return nil
        case .moveDown:
            moveFocus(offset: 1, visitIDs: visitIDs)
            return nil
        case .submit:
            guard let focusedVisitID else { return nil }
            return .openVisit(focusedVisitID)
        case .escape:
            return escape()
        }
    }

    /// Drops selected identifiers the Store no longer holds. History does not
    /// call this on every model change any more, because a paged model drops
    /// visits it simply has not loaded.
    public mutating func pruneSelection(to validIDs: Set<UUID>) {
        selectedVisitIDs = selectedVisitIDs.intersection(validIDs)
    }

    public mutating func toggleVisit(_ id: UUID, isSelected: Bool) {
        if isSelected {
            selectedVisitIDs.insert(id)
        } else {
            selectedVisitIDs.remove(id)
        }
    }

    public mutating func requestVisitDeletion(_ id: UUID) {
        pendingDeletion = .visit(id)
    }

    public mutating func requestSelectedDeletion() {
        guard !selectedVisitIDs.isEmpty else { return }
        pendingDeletion = .selected(selectedVisitIDs)
    }

    public mutating func requestGroupDeletion(sessionID: UUID, branchID: String, groupID: UUID) {
        pendingDeletion = .hostnameGroup(sessionID: sessionID, branchID: branchID, groupID: groupID)
    }

    public mutating func requestSessionDeletion(_ id: UUID) {
        pendingDeletion = .session(id)
    }

    public mutating func requestAllDeletion() {
        pendingDeletion = .all
    }

    /// Selection survives paging and searching, because a reader who ticked a
    /// row on page one still means it after loading page two. It clears only
    /// once the rows it names are on their way out.
    @discardableResult
    public mutating func confirmPendingDeletion() -> KeelHistoryAction? {
        guard let pendingDeletion else { return nil }
        self.pendingDeletion = nil
        switch pendingDeletion {
        case let .visit(id):
            selectedVisitIDs.remove(id)
            return .deleteVisit(id)
        case let .selected(ids):
            selectedVisitIDs.subtract(ids)
            return .deleteVisits(ids)
        case let .hostnameGroup(sessionID, branchID, groupID):
            return .deleteHostnameGroup(sessionID: sessionID, branchID: branchID, groupID: groupID)
        case let .session(id): return .deleteSession(id)
        case .all:
            selectedVisitIDs.removeAll()
            return .deleteAll
        }
    }

    public mutating func cancelPendingDeletion() {
        pendingDeletion = nil
    }

    @discardableResult
    public mutating func escape() -> KeelHistoryAction? {
        if pendingDeletion != nil {
            pendingDeletion = nil
            return nil
        } else if !selectedVisitIDs.isEmpty || focusedVisitID != nil {
            selectedVisitIDs.removeAll()
            focusedVisitID = nil
            return nil
        } else {
            return .dismiss
        }
    }

    private mutating func moveFocus(offset: Int, visitIDs: [UUID]) {
        guard !visitIDs.isEmpty else {
            focusedVisitID = nil
            return
        }

        let currentIndex: Int
        if let focusedVisitID, let index = visitIDs.firstIndex(of: focusedVisitID) {
            currentIndex = index
        } else {
            currentIndex = offset < 0 ? visitIDs.count : -1
        }
        focusedVisitID = visitIDs[min(max(currentIndex + offset, 0), visitIDs.count - 1)]
    }
}
