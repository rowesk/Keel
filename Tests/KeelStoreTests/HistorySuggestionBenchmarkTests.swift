@testable import KeelStore
import Dispatch
import Foundation
import Testing

@Suite("History suggestion benchmarks")
struct HistorySuggestionBenchmarkTests {
    /// ADR 0007 allows 150 milliseconds to initiate a selected address action.
    /// Result generation must remain within that interaction budget at p99.
    private static let addressInteractionBudgetNanoseconds: UInt64 = 150_000_000

    /// This test does no fixture work during the normal suite. Run one of:
    /// `KEEL_HISTORY_BENCHMARK=10000 swift test --filter HistorySuggestionBenchmarkTests`
    /// `KEEL_HISTORY_BENCHMARK=100000 swift test --filter HistorySuggestionBenchmarkTests`
    @Test("reports prefix and substring latency for an opt-in local History fixture")
    func measuresConfiguredFixture() async throws {
        guard let entryCount = Self.configuredEntryCount else { return }

        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])
        try await seed(entryCount: entryCount, into: store, sessionID: session.id)

        let prefixTimings = try await timings(for: "examp", expectedHostname: "example-store.myshopify.test", store: store)
        let substringTimings = try await timings(for: "shopi", expectedHostname: "example-store.myshopify.test", store: store)
        report(entryCount: entryCount, query: "examp", timings: prefixTimings)
        report(entryCount: entryCount, query: "shopi", timings: substringTimings)
    }

    private static var configuredEntryCount: Int? {
        switch ProcessInfo.processInfo.environment["KEEL_HISTORY_BENCHMARK"] {
        case "10000", "10k", "10K", "1": 10_000
        case "100000", "100k", "100K": 100_000
        default: nil
        }
    }

    private func seed(entryCount: Int, into store: KeelStore, sessionID: UUID) async throws {
        let batchSize = 1_000
        for batchStart in stride(from: 0, to: entryCount, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, entryCount)
            var events: [HistoryVisitEvent] = []
            events.reserveCapacity(batchEnd - batchStart)
            for index in batchStart ..< batchEnd {
                guard let url = URL(string: "https://work\(index).benchmark.test/catalog-\(index)") else {
                    throw HistoryStoreError.invalidURL
                }
                events.append(HistoryVisitEvent(
                    url: url,
                    visitedAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                    browsingSessionID: sessionID,
                    source: .link
                ))
            }
            _ = try await store.recordHistoryVisits(events)
        }
        guard let targetURL = URL(string: "https://example-store.myshopify.test/admin") else {
            throw HistoryStoreError.invalidURL
        }
        _ = try await store.recordHistoryVisit(HistoryVisitEvent(
            url: targetURL,
            title: "Example store control",
            visitedAt: Date(timeIntervalSince1970: TimeInterval(entryCount + 1)),
            browsingSessionID: sessionID,
            source: .typedAddress
        ))
    }

    private func timings(for query: String, expectedHostname: String, store: KeelStore) async throws -> [UInt64] {
        var results: [UInt64] = []
        results.reserveCapacity(200)
        for _ in 0 ..< 200 {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let suggestions = try await store.addressSuggestions(for: query).suggestions
            let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
            #expect(suggestions.contains(where: { $0.hostname == expectedHostname }))
            results.append(elapsed)
        }
        return results
    }

    private func report(entryCount: Int, query: String, timings: [UInt64]) {
        let sorted = timings.sorted()
        guard let minimum = sorted.first, let maximum = sorted.last else {
            Issue.record("Benchmark produced no timings")
            return
        }
        let p99 = percentile(0.99, in: sorted)
        #expect(
            p99 <= Self.addressInteractionBudgetNanoseconds,
            "Address suggestions exceeded the 150 ms p99 interaction budget for \(query) with \(entryCount) History URLs: \(milliseconds(nanoseconds: p99)) ms"
        )
        print(
            "Keel History benchmark entries=\(entryCount) query=\(query) "
                + "p50=\(milliseconds(percentile: 0.50, in: sorted))ms "
                + "p95=\(milliseconds(percentile: 0.95, in: sorted))ms "
                + "p99=\(milliseconds(nanoseconds: p99))ms "
                + "min=\(milliseconds(nanoseconds: minimum))ms "
                + "max=\(milliseconds(nanoseconds: maximum))ms"
        )
    }

    private func percentile(_ percentileValue: Double, in sorted: [UInt64]) -> UInt64 {
        let index = Int((Double(sorted.count - 1) * percentileValue).rounded(.toNearestOrAwayFromZero))
        return sorted[index]
    }

    private func milliseconds(percentile percentileValue: Double, in sorted: [UInt64]) -> String {
        milliseconds(nanoseconds: percentile(percentileValue, in: sorted))
    }

    private func milliseconds(nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }
}
