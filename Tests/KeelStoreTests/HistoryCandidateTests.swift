@testable import KeelStore
import Foundation
import Testing

@Suite("History candidates")
struct HistoryCandidateTests {
    @Test("filters prefix candidates before applying the cap")
    func returnsLowUseRelevantCandidateBehindUnrelatedVisits() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])
        let desired = try await store.recordHistoryVisit(HistoryVisitEvent(url: URL(string: "https://example-store.myshopify.test/admin")!, title: "Example store admin", visitedAt: Date(timeIntervalSince1970: 1), browsingSessionID: session.id, source: .typedAddress))
        _ = desired
        for index in 0 ..< 600 {
            _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: URL(string: "https://unrelated\(index).example/catalog")!, visitedAt: Date(timeIntervalSince1970: TimeInterval(index + 2)), browsingSessionID: session.id, source: .link))
        }
        let candidates = try await store.historyCandidates(matching: "examp", limit: 6)
        #expect(candidates.map(\.url).contains(URL(string: "https://example-store.myshopify.test/admin")!))
        #expect((try await store.historyCandidates(matching: "fragrances", limit: 6)).count == 1)
        #expect((try await store.historyCandidates(matching: "shopi", limit: 6)).isEmpty)
        #expect((try await store.historyCandidates(matching: "admin", limit: 6)).count == 1)
    }

    @Test("uses the bounded fallback for an internal hostname fragment")
    func findsInternalFragmentInsideRecentHead() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])
        let url = URL(string: "https://example-store.myshopify.test/admin")!
        _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: url, visitedAt: Date(timeIntervalSince1970: 2), browsingSessionID: session.id, source: .typedAddress))
        #expect((try await store.historyCandidates(matching: "shopi", limit: 6)).map(\.url) == [url])
    }

    @Test("keeps adaptive choice counts without exposing query values in URL matching")
    func recordsAddressChoiceSeparately() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])
        let queryURL = try #require(URL(string: "https://example.com/search?q=private-value"))
        let safeURL = try #require(URL(string: "https://example.com/search"))
        _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: queryURL, visitedAt: Date(timeIntervalSince1970: 2), browsingSessionID: session.id, source: .typedAddress))
        _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: safeURL, visitedAt: Date(timeIntervalSince1970: 3), browsingSessionID: session.id, source: .typedAddress))
        try await store.recordAddressChoice(input: "example", chosenURL: safeURL, at: Date(timeIntervalSince1970: 4))
        try await store.recordAddressChoice(input: "example", chosenURL: safeURL, at: Date(timeIntervalSince1970: 5))
        let candidate = try #require((try await store.historyCandidates(matching: "example")).first)
        #expect(candidate.addressChoiceCount == 2)
        #expect(candidate.lastAddressChoiceAt == Date(timeIntervalSince1970: 5))
        let otherInput = try #require((try await store.historyCandidates(matching: "exa")).first)
        #expect(otherInput.addressChoiceCount == 0)
        #expect(otherInput.lastAddressChoiceAt == nil)
        #expect((try await store.historyCandidates(matching: "private")).isEmpty)
    }
}
