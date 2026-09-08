@testable import KeelStore
import Foundation
import Testing

@Suite("History paging and search")
struct HistoryPagingTests {
    @Test("pages ended sessions newest first and stops when nothing older remains")
    func pagesEndedSessionsNewestFirst() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let sessions = try await seedSessions(store, count: 5)

        let first = try await store.endedHistorySessionPage(limit: 2)
        #expect(first.sessions.map(\.id) == [sessions[4], sessions[3]])
        let firstCursor = try #require(first.nextCursor)

        let second = try await store.endedHistorySessionPage(limit: 2, before: firstCursor)
        #expect(second.sessions.map(\.id) == [sessions[2], sessions[1]])
        let secondCursor = try #require(second.nextCursor)

        let third = try await store.endedHistorySessionPage(limit: 2, before: secondCursor)
        #expect(third.sessions.map(\.id) == [sessions[0]])
        #expect(third.nextCursor == nil)
    }

    @Test("rejects a page size outside the bound")
    func rejectsInvalidPageSize() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)

        await #expect(throws: HistoryStoreError.invalidSessionPageLimit) {
            _ = try await store.endedHistorySessionPage(limit: 0)
        }
        await #expect(throws: HistoryStoreError.invalidSessionPageLimit) {
            _ = try await store.endedHistorySessionPage(limit: KeelStore.historySessionPageLimit + 1)
        }
    }

    @Test("the compatibility listing stops at the page bound rather than returning every session")
    func compatibilityListingIsBounded() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        _ = try await seedSessions(store, count: 4)

        let summaries = try await store.endedHistorySessions()
        #expect(summaries.count == 4)
        #expect(summaries.count <= KeelStore.historySessionPageLimit)
    }

    @Test("loads the visits for a whole page of sessions in one call")
    func loadsVisitsForASessionBatch() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let sessions = try await seedSessions(store, count: 3)

        let grouped = try await store.historyVisits(inSessions: [sessions[0], sessions[2]])
        #expect(Set(grouped.keys) == [sessions[0], sessions[2]])
        #expect(grouped[sessions[0]]?.map(\.url.absoluteString) == ["https://site0.example/a", "https://site0.example/b"])
        #expect(try await store.historyVisits(inSessions: []).isEmpty)
    }

    @Test("search finds a visit from a session no page ever loaded")
    func searchReachesUnloadedSessions() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let sessions = try await seedSessions(store, count: 6)
        let buried = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1), endedAt: Date(timeIntervalSince1970: 2), hostname: "archive.example")
        _ = try await store.apply([.upsertSession(buried)])
        _ = try await store.recordHistoryVisit(
            HistoryVisitEvent(
                url: URL(string: "https://archive.example/gardening")!,
                title: "Gardening notes",
                visitedAt: Date(timeIntervalSince1970: 2),
                browsingSessionID: buried.id,
                source: .link
            )
        )

        let page = try await store.endedHistorySessionPage(limit: 2)
        #expect(!page.sessions.map(\.id).contains(buried.id))

        let matches = try await store.searchHistoryVisits(matching: "gardening")
        #expect(matches.visits.map(\.url.absoluteString) == ["https://archive.example/gardening"])
        #expect(matches.sessions.map(\.id) == [buried.id])
        #expect(!matches.reachedLimit)
        #expect(!sessions.contains(buried.id))
    }

    @Test("search matches hostname, path and title, and reports when the bound cuts the result")
    func searchMatchesEveryFieldAndReportsTruncation() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1), endedAt: Date(timeIntervalSince1970: 100), hostname: "docs.example")
        _ = try await store.apply([.upsertSession(session)])
        for index in 0 ..< 4 {
            _ = try await store.recordHistoryVisit(
                HistoryVisitEvent(
                    url: URL(string: "https://docs.example/manual/\(index)")!,
                    title: "Handbook \(index)",
                    visitedAt: Date(timeIntervalSince1970: TimeInterval(10 + index)),
                    browsingSessionID: session.id,
                    source: .link
                )
            )
        }

        #expect(try await store.searchHistoryVisits(matching: "docs").visits.count == 4)
        #expect(try await store.searchHistoryVisits(matching: "manual").visits.count == 4)
        #expect(try await store.searchHistoryVisits(matching: "handbook").visits.count == 4)
        #expect(try await store.searchHistoryVisits(matching: "handbook manual").visits.count == 4)
        #expect(try await store.searchHistoryVisits(matching: "nothinghere").visits.isEmpty)
        #expect(try await store.searchHistoryVisits(matching: "   ").visits.isEmpty)

        let bounded = try await store.searchHistoryVisits(matching: "docs", limit: 2)
        #expect(bounded.visits.count == 2)
        #expect(bounded.reachedLimit)
        // Newest first, so the bound keeps the most recent matches.
        #expect(bounded.visits.map(\.title) == ["Handbook 3", "Handbook 2"])

        await #expect(throws: HistoryStoreError.invalidSearchLimit) {
            _ = try await store.searchHistoryVisits(matching: "docs", limit: 0)
        }
    }

    @Test("deleting a session removes it from later pages and from search")
    func deletionHoldsAcrossPages() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let sessions = try await seedSessions(store, count: 4)

        try await store.deleteHistory(.session(sessions[1]))

        var seen: [UUID] = []
        var cursor: HistorySessionCursor?
        repeat {
            let page = try await store.endedHistorySessionPage(limit: 2, before: cursor)
            seen += page.sessions.map(\.id)
            cursor = page.nextCursor
        } while cursor != nil
        #expect(seen == [sessions[3], sessions[2], sessions[0]])
        #expect(try await store.searchHistoryVisits(matching: "site1").visits.isEmpty)
    }

    @Test("returns recorded titles for a whole set of addresses in one call")
    func returnsRecordedTitlesForASet() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let sessions = try await seedSessions(store, count: 2)
        _ = sessions

        let known = URL(string: "https://site0.example/a")!
        let unknown = URL(string: "https://nowhere.example/z")!
        let titles = try await store.recordedTitles(for: [known, unknown])

        #expect(titles == [known: "Site 0 a"])
        #expect(try await store.recordedTitles(for: []).isEmpty)
    }

    /// Sessions 0 ... count-1, oldest first, two visits each.
    private func seedSessions(_ store: KeelStore, count: Int) async throws -> [UUID] {
        var identifiers: [UUID] = []
        for index in 0 ..< count {
            let start = TimeInterval(1_000 + index * 100)
            let session = BrowsingSession(
                id: UUID(),
                startedAt: Date(timeIntervalSince1970: start),
                endedAt: Date(timeIntervalSince1970: start + 50),
                hostname: "site\(index).example"
            )
            _ = try await store.apply([.upsertSession(session)])
            for (offset, suffix) in ["a", "b"].enumerated() {
                _ = try await store.recordHistoryVisit(
                    HistoryVisitEvent(
                        url: URL(string: "https://site\(index).example/\(suffix)")!,
                        title: "Site \(index) \(suffix)",
                        visitedAt: Date(timeIntervalSince1970: start + TimeInterval(offset + 1)),
                        browsingSessionID: session.id,
                        source: .link
                    )
                )
            }
            identifiers.append(session.id)
        }
        return identifiers
    }
}
