import Foundation

public struct KeelQueueDeletionUndoItem: Equatable, Sendable {
    public let deletedCount: Int
    public let deadline: Date

    public init(deletedCount: Int, deadline: Date) {
        self.deletedCount = deletedCount
        self.deadline = deadline
    }
}
