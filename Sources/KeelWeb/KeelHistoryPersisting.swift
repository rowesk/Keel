import Foundation
import KeelStore

/// Keeps History failures testable independently of coordinator commits.
protocol KeelHistoryPersisting: Sendable {
    func recordHistoryVisit(_ event: HistoryVisitEvent) async throws -> HistoryVisit
    func updateHistoryTitle(visitID: UUID, title: String?) async throws
}

extension KeelStore: KeelHistoryPersisting {}
