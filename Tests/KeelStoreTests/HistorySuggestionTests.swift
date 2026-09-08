@testable import KeelStore
import Foundation
import Testing

@Suite("History suggestions")
struct HistorySuggestionTests {
    @Test("matches Shopify fragments with explicit local match quality")
    func matchesShopifyFragments() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])
        let url = try #require(URL(string: "https://example-store.myshopify.test/admin"))
        _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: url, title: "Example store control", visitedAt: Date(timeIntervalSince1970: 2), browsingSessionID: session.id, source: .typedAddress))

        let examp = try await store.addressSuggestions(for: "examp").suggestions
        #expect(examp.map(\.url) == [url])
        #expect(examp.first?.match == HistorySuggestionMatch(quality: .hostnamePrefix, field: .hostname))
        #expect((try await store.addressSuggestions(for: "fragrances").suggestions).first?.match == HistorySuggestionMatch(quality: .tokenBoundaryPrefix, field: .hostname))
        #expect((try await store.addressSuggestions(for: "shopi").suggestions).first?.match == HistorySuggestionMatch(quality: .contiguousSubstring, field: .hostname))
        #expect((try await store.addressSuggestions(for: "admin").suggestions).first?.match == HistorySuggestionMatch(quality: .tokenBoundaryPrefix, field: .path))
    }

    @Test("ranks exact and hostname-prefix matches before adaptive popularity")
    func ranksMatchQualityFirst() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])
        let exactURL = try #require(URL(string: "https://example.com/"))
        let prefixURL = try #require(URL(string: "https://example.come.test/"))
        _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: exactURL, visitedAt: Date(timeIntervalSince1970: 2), browsingSessionID: session.id, source: .link))
        _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: prefixURL, visitedAt: Date(timeIntervalSince1970: 3), browsingSessionID: session.id, source: .typedAddress))
        let prefixSuggestion = try #require((try await store.addressSuggestions(for: "example.com").suggestions).first(where: { $0.url == prefixURL }))
        for _ in 0 ..< 12 {
            try await store.recordAddressChoice(input: "example.com", historyURLID: prefixSuggestion.historyURLID)
        }

        let suggestions = try await store.addressSuggestions(for: "example.com").suggestions
        #expect(suggestions.first?.url == exactURL)
        #expect(suggestions.first?.match.quality == .exactURLOrHostname)
        #expect((try await store.addressSuggestions(for: "https://example.com/").suggestions).first?.match == HistorySuggestionMatch(quality: .exactURLOrHostname, field: .canonicalURL))
    }

    @Test("canonical exact input survives slash port and fragment normalization")
    func canonicalExactInputFindsTheStoredURL() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])
        let storedURL = try #require(URL(string: "https://example.com/"))
        _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: storedURL, visitedAt: Date(timeIntervalSince1970: 2), browsingSessionID: session.id, source: .typedAddress))

        for input in ["https://example.com", "https://example.com:443/#section", "HTTPS://EXAMPLE.COM/#section"] {
            let result = try await store.addressSuggestions(for: input)
            let suggestion = try #require(result.suggestions.first)
            #expect(suggestion.url == storedURL)
            #expect(suggestion.match == HistorySuggestionMatch(quality: .exactURLOrHostname, field: .canonicalURL))
            #expect(result.defaultSuggestionID == suggestion.historyURLID)
            #expect(try await store.historyURL(forID: suggestion.historyURLID) == storedURL)
        }
    }

    @Test("partial matching cannot surface a query-bearing History URL")
    func partialMatchingExcludesQueryBearingURLs() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])
        let queryURL = try #require(URL(string: "https://example.com/search?q=private-value"))
        _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: queryURL, visitedAt: Date(timeIntervalSince1970: 2), browsingSessionID: session.id, source: .typedAddress))

        #expect((try await store.addressSuggestions(for: "example.com").suggestions).isEmpty)
        #expect((try await store.addressSuggestions(for: "xamp").suggestions).isEmpty)
        let exact = try #require((try await store.addressSuggestions(for: "https://example.com/search?q=private-value#fragment").suggestions).first)
        #expect(exact.url == queryURL)
        #expect(exact.match == HistorySuggestionMatch(quality: .exactURLOrHostname, field: .canonicalURL))
        await #expect(throws: HistoryStoreError.invalidAddressChoiceInput) {
            try await store.recordAddressChoice(input: "example.com", historyURLID: exact.historyURLID)
        }
    }

    @Test("records a stable History selection inside a mixed Store transaction")
    func recordsAddressChoiceAtomicallyWithQueueChanges() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])
        let selectedURL = try #require(URL(string: "https://selected.example/"))
        let queuedURL = try #require(URL(string: "https://queued.example/"))
        _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: selectedURL, visitedAt: Date(timeIntervalSince1970: 2), browsingSessionID: session.id, source: .typedAddress))
        let selected = try #require((try await store.addressSuggestions(for: "selected").suggestions).first)

        let commit = try await store.apply([
            .recordAddressChoice(input: "selected", historyURLID: selected.historyURLID),
            .captureQueuedDestination(queuedURL),
        ])
        #expect(commit.outcomes.count == 2)
        #expect((try await store.addressSuggestions(for: "selected").suggestions).first?.addressChoiceCount == 1)
        #expect(commit.runtimeState.queue.map(\.url) == [queuedURL])
    }

    @Test("keeps a normal phrase as a non-hostname match")
    func marksNormalPhraseAsNonHostnameMatch() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])
        let url = try #require(URL(string: "https://directory.example/vendors"))
        _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: url, title: "Fragrance suppliers", visitedAt: Date(timeIntervalSince1970: 2), browsingSessionID: session.id, source: .link))

        let result = try await store.addressSuggestions(for: "fragrance suppliers")
        let suggestion = try #require(result.suggestions.first)
        #expect(suggestion.match.quality == .tokenBoundaryPrefix)
        #expect(suggestion.match.field == .title)
        #expect(result.defaultSuggestionID == nil)
    }

    @Test("promotes an adaptive selection, then lets its advantage decay")
    func promotesAndDecaysAdaptiveChoice() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let clock = SuggestionClock(Date(timeIntervalSince1970: 1_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        let session = BrowsingSession(id: UUID(), startedAt: clock.value)
        _ = try await store.apply([.upsertSession(session)])
        let selectedURL = try #require(URL(string: "https://alpha-one.example/"))
        let frequentURL = try #require(URL(string: "https://alpha-two.example/"))
        _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: selectedURL, visitedAt: clock.value, browsingSessionID: session.id, source: .link))
        var frequentVisit: HistoryVisit?
        for offset in 0 ..< 3 {
            frequentVisit = try await store.recordHistoryVisit(HistoryVisitEvent(url: frequentURL, visitedAt: clock.value.addingTimeInterval(TimeInterval(offset + 1)), browsingSessionID: session.id, source: .link))
        }
        let frequent = try #require(frequentVisit)
        let selected = try #require((try await store.addressSuggestions(for: "alpha").suggestions).first(where: { $0.url == selectedURL }))
        try await store.recordAddressChoice(input: "alpha", historyURLID: selected.historyURLID)
        #expect((try await store.addressSuggestions(for: "alpha").suggestions).first?.url == selectedURL)

        clock.value = clock.value.addingTimeInterval(365 * 86_400)
        let decayed = try await store.addressSuggestions(for: "alpha").suggestions
        #expect(decayed.first?.url == frequent.url)
    }

    @Test("deleting any visit for a URL removes its adaptive input mapping")
    func deletionRemovesAdaptiveChoicesForSurvivingURL() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])
        let url = try #require(URL(string: "https://private-delete.example/"))
        let first = try await store.recordHistoryVisit(HistoryVisitEvent(url: url, visitedAt: Date(timeIntervalSince1970: 2), browsingSessionID: session.id, source: .link))
        _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: url, visitedAt: Date(timeIntervalSince1970: 3), browsingSessionID: session.id, source: .link))
        let suggestion = try #require((try await store.addressSuggestions(for: "private").suggestions).first)
        try await store.recordAddressChoice(input: "private", historyURLID: suggestion.historyURLID)
        try await store.deleteHistory(.visits([first.id]))

        let after = try #require((try await store.addressSuggestions(for: "private").suggestions).first)
        #expect(after.addressChoiceCount == 0)
        #expect(after.lastAddressChoiceAt == nil)
    }

    @Test("uses a bounded prefix lookup before applying the visible cap")
    func keepsARelevantOlderResultWithinTheVisibleLimit() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])
        let desiredURL = try #require(URL(string: "https://example-store.myshopify.test/admin"))
        _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: desiredURL, visitedAt: Date(timeIntervalSince1970: 2), browsingSessionID: session.id, source: .typedAddress))
        for index in 0 ..< 600 {
            let url = try #require(URL(string: "https://unrelated\(index).example/catalog"))
            _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: url, visitedAt: Date(timeIntervalSince1970: TimeInterval(index + 3)), browsingSessionID: session.id, source: .link))
        }

        let suggestions = try await store.addressSuggestions(for: "examp", limit: 6).suggestions
        #expect(suggestions.map(\.url).contains(desiredURL))
        #expect(suggestions.count <= 6)
    }

    @Test("uses indexed range scans for hostname and token prefixes")
    func usesIndexedPrefixQueries() throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        _ = try KeelStore(databaseURL: fixture.databaseURL)
        let database = try SQLiteDatabase(url: fixture.databaseURL)
        let lowerBound = "examp"
        let upperBound = lowerBound + "\u{10FFFF}"
        let hostnamePlan = try database.rows(
            "EXPLAIN QUERY PLAN SELECT id FROM history_urls WHERE host_folded >= ? AND host_folded < ?",
            values: [.text(lowerBound), .text(upperBound)]
        )
        let tokenPlan = try database.rows(
            "EXPLAIN QUERY PLAN SELECT history_url_id FROM history_url_terms WHERE token >= ? AND token < ?",
            values: [.text(lowerBound), .text(upperBound)]
        )
        let substringHeadPlan = try database.rows(
            "EXPLAIN QUERY PLAN SELECT id FROM history_urls ORDER BY last_visited_at DESC LIMIT 500"
        )
        #expect(hostnamePlan.compactMap { $0.text(3) }.joined(separator: " ").contains("history_urls_host_index"))
        #expect(tokenPlan.compactMap { $0.text(3) }.joined(separator: " ").contains("history_url_terms_token_index"))
        #expect(substringHeadPlan.compactMap { $0.text(3) }.joined(separator: " ").contains("history_urls_last_visited_index"))
    }
}

private final class SuggestionClock: @unchecked Sendable {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}
