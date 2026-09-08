import Foundation

public struct KeelHomeModel: Equatable, Sendable {
    public let resume: KeelResumeItem?
    public let undo: KeelUndoItem?
    public let queue: [KeelQueueItem]
    public let queueDeletionUndo: KeelQueueDeletionUndoItem?
    public let queueIDs: [UUID]
    /// Mirrors the coordinator's own guard for advancing the queue: Home is
    /// showing, no page is active, and no checkpoint is waiting ahead of it.
    public let canStartQueue: Bool

    public init(
        resume: KeelResumeItem? = nil,
        undo: KeelUndoItem? = nil,
        queue: [KeelQueueItem] = [],
        queueDeletionUndo: KeelQueueDeletionUndoItem? = nil,
        canStartQueue: Bool = true
    ) {
        self.resume = resume
        self.undo = undo
        let sortedQueue = queue.sorted {
            if $0.sequence != $1.sequence {
                return $0.sequence < $1.sequence
            }
            if $0.capturedAt != $1.capturedAt {
                return $0.capturedAt < $1.capturedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        self.queue = sortedQueue
        self.queueDeletionUndo = queueDeletionUndo
        self.queueIDs = sortedQueue.map(\.id)
        self.canStartQueue = canStartQueue && !sortedQueue.isEmpty && resume == nil
    }

    /// Recovery never takes the forward action away from a ready queue.
    public var primaryAction: KeelHomeAction? {
        if resume != nil { return .resume }
        if hasVisibleQueue { return .startQueue }
        if undo != nil { return .restoreClosedPage }
        return nil
    }

    public var queueCountDescription: String? {
        queue.isEmpty ? nil : "\(queue.count) queued"
    }

    public var hasVisibleQueue: Bool {
        !queue.isEmpty
    }

    public var visibleQueueIDs: [UUID] {
        queueIDs
    }

    /// Whether Home has queued or unfinished work to describe beside the field.
    /// Address submission chooses Open or Add to queue independently.
    public var queueIsHolding: Bool {
        !queue.isEmpty || resume != nil
    }

    /// Why Start is unavailable while destinations are waiting. A greyed button
    /// beside a full queue is the kind of thing that reads as a broken app.
    public var startBlockedReason: String? {
        guard !queue.isEmpty, !canStartQueue else { return nil }
        if resume != nil {
            return "Resume or discard the unfinished page first"
        }
        return "Close the active page first"
    }

    public static func fixture(count: Int, now: Date = Date.now) -> KeelHomeModel {
        let safeCount = max(0, count)
        let titles = [
            "Hacker News",
            "Swift Forums, concurrency",
            nil,
            "WWDC session catalogue",
            "Neon docs, branching",
        ]
        let queue = (0 ..< safeCount).map { index in
            KeelQueueItem(
                id: UUID(),
                displayURL: "https://example\(index).test/article/\(index)",
                hostname: "example\(index).test",
                title: titles.indices.contains(index) ? titles[index] : nil,
                capturedAt: now.addingTimeInterval(TimeInterval(-index * 340)),
                sequence: Int64(index)
            )
        }
        return KeelHomeModel(queue: queue)
    }
}
