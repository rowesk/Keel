import Foundation
import KeelStore

/// Writes only the bounded diagnostic fields permitted by ADR 0017.
@MainActor
final class KeelWebDiagnostics {
    private let store: KeelStore
    private let now: @Sendable () -> Date

    init(store: KeelStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    func record(
        eventType: DiagnosticEventType,
        url: URL?,
        result: DiagnosticResult,
        durationMilliseconds: Int? = nil,
        errorCode: Int? = nil
    ) {
        guard let hostname = url?.host.flatMap({ try? DiagnosticHostname($0) }) else {
            return
        }
        let record = DiagnosticRecord(
            timestamp: now(),
            eventType: eventType,
            hostname: hostname,
            result: result,
            durationMilliseconds: durationMilliseconds,
            errorCode: errorCode
        )
        Task {
            _ = try? await store.apply([.recordDiagnostic(record)])
        }
    }
}
