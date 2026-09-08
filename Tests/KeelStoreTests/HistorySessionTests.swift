@testable import KeelStore
import Foundation
import Testing

@Suite("History sessions")
struct HistorySessionTests {
    @Test("lists ended sessions by their most recent visit with compact display information")
    func listsEndedSessionsInVisitOrder() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let older = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1), endedAt: Date(timeIntervalSince1970: 4), hostname: "older.example")
        let newer = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 5), endedAt: Date(timeIntervalSince1970: 9), hostname: "newer.example")
        let active = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 10), hostname: "active.example")
        _ = try await store.apply([.upsertSession(older), .upsertSession(newer), .upsertSession(active)])
        _ = try await store.recordHistoryVisit(event("https://older.example/one", title: "Older", at: 2, session: older.id))
        _ = try await store.recordHistoryVisit(event("https://newer.example/one", title: "First", at: 6, session: newer.id))
        _ = try await store.recordHistoryVisit(event("https://newer.example/two", title: "Newest", at: 8, session: newer.id, icon: "newer.example"))
        _ = try await store.recordHistoryVisit(event("https://active.example", title: "Active", at: 11, session: active.id))

        let summaries = try await store.endedHistorySessions()
        #expect(summaries.map(\.id) == [newer.id, older.id])
        let latest = try #require(summaries.first)
        #expect(latest.startedAt == newer.startedAt)
        #expect(latest.endedAt == newer.endedAt)
        #expect(latest.firstVisitedAt == Date(timeIntervalSince1970: 6))
        #expect(latest.lastVisitedAt == Date(timeIntervalSince1970: 8))
        #expect(latest.visitCount == 2)
        #expect(latest.hostname == "newer.example")
        #expect(latest.title == "Newest")
        #expect(latest.displayURL == "https://newer.example/two")
        #expect(latest.faviconReferenceKey == "newer.example")
    }

    private func event(_ value: String, title: String, at timestamp: TimeInterval, session: UUID, icon: String? = nil) -> HistoryVisitEvent {
        HistoryVisitEvent(url: URL(string: value)!, title: title, visitedAt: Date(timeIntervalSince1970: timestamp), browsingSessionID: session, source: .link, faviconReferenceKey: icon)
    }
}
