@testable import KeelStore
import Foundation
import Testing

@Suite("History deletion")
struct HistoryDeletionTests {
    @Test("deletes one hostname group in one branch and rebuilds affected aggregates")
    func deletesHostnameGroupOnly() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])
        let first = try await store.recordHistoryVisit(event("https://alpha.example/one", at: 2, session: session.id))
        _ = try await store.recordHistoryVisit(event("https://alpha.example/two", at: 3, session: session.id))
        _ = try await store.recordHistoryVisit(event("https://beta.example", at: 4, session: session.id))
        _ = try await store.recordHistoryVisit(event("https://alpha.example/three", at: 5, session: session.id))
        let group = try #require((try await store.historyHostnameGroups(in: session.id)).first(where: { $0.id == first.hostnameGroupID }))
        try await store.deleteHistory(.hostnameGroup(sessionID: session.id, branchID: group.branchID, groupID: group.id))

        let remaining = try await store.historyVisits(in: session.id)
        #expect(remaining.map(\.url.absoluteString) == ["https://beta.example/", "https://alpha.example/three"])
        #expect((try await store.historyCandidates(matching: "one")).isEmpty)
        #expect((try await store.historyHostnameGroups(in: session.id)).count == 2)
    }

    @Test("selection, session, and all deletion leave state-store data alone")
    func keepsStateTablesAndCleansAdaptiveRows() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        let queueURL = URL(string: "https://queue.example")!
        _ = try await store.apply([.upsertSession(session), .captureQueuedDestination(queueURL)])
        let one = try await store.recordHistoryVisit(event("https://remove.example", at: 2, session: session.id))
        let two = try await store.recordHistoryVisit(event("https://keep.example", at: 3, session: session.id))
        try await store.recordAddressChoice(input: "remove", chosenURL: one.url, at: Date(timeIntervalSince1970: 4))
        try await store.deleteHistory(.visits([one.id]))
        #expect((try await store.historyCandidates(matching: "remove")).isEmpty)
        #expect(try fixture.count("address_choice_history") == 0)
        #expect((try await store.runtimeState()).queue.map(\.url) == [queueURL])
        #expect(try fixture.count("browsing_sessions") == 1)

        try await store.deleteHistory(.session(session.id))
        #expect((try await store.historyVisits(in: session.id)).isEmpty)
        #expect(try fixture.count("browsing_sessions") == 1)
        #expect((try await store.runtimeState()).queue.map(\.url) == [queueURL])
        _ = two

        let secondSession = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 5), endedAt: Date(timeIntervalSince1970: 7))
        _ = try await store.apply([.upsertSession(secondSession)])
        _ = try await store.recordHistoryVisit(event("https://all.example", at: 6, session: secondSession.id))
        try await store.deleteHistory(.all)
        #expect(try fixture.count("history_visits") == 0)
        #expect(try fixture.count("history_urls") == 0)
        #expect(try fixture.count("queue") == 1)
    }

    @Test("rolls back visits, aggregates, and state rows after a later History mutation fails")
    func rollsHistoryBatchBackAtomically() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        let queueURL = URL(string: "https://queue.example")!
        let setupStore = try KeelStore(databaseURL: fixture.databaseURL)
        _ = try await setupStore.apply([.upsertSession(session), .captureQueuedDestination(queueURL)])
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: Date.init, faultInjector: { index in
            if index == 1 { throw HistoryFixtureFault.injected }
        })
        let events = [event("https://one.example", at: 2, session: session.id), event("https://two.example", at: 3, session: session.id)]
        await #expect(throws: HistoryFixtureFault.injected) {
            _ = try await store.recordHistoryVisits(events)
        }
        #expect((try await store.historyVisits(in: session.id)).isEmpty)
        #expect(try fixture.count("history_urls") == 0)
        #expect(try fixture.count("history_hostname_groups") == 0)
        #expect((try await store.runtimeState()).queue.map(\.url) == [queueURL])
        #expect(try fixture.count("browsing_sessions") == 1)
    }

    @Test("deletes a selected middle run and merges its adjacent hostname groups")
    func deletesSelectionAndMergesAdjacentGroups() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])
        _ = try await store.recordHistoryVisit(event("https://alpha.example/one", at: 2, session: session.id))
        let middleOne = try await store.recordHistoryVisit(event("https://beta.example/one", at: 3, session: session.id))
        let middleTwo = try await store.recordHistoryVisit(event("https://beta.example/two", at: 4, session: session.id))
        _ = try await store.recordHistoryVisit(event("https://alpha.example/two", at: 5, session: session.id))
        try await store.deleteHistory(.visits([middleOne.id, middleTwo.id]))

        #expect((try await store.historyVisits(in: session.id)).map(\.url.absoluteString) == ["https://alpha.example/one", "https://alpha.example/two"])
        #expect((try await store.historyHostnameGroups(in: session.id)).map(\.hostname) == ["alpha.example"])
        #expect((try await store.historyCandidates(matching: "beta")).isEmpty)
    }

    @Test("falls back to the prior title and favicon when the newest visit is removed")
    func restoresAggregateMetadataAfterNewestVisitDeletion() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])
        let timestamp = Date(timeIntervalSince1970: 2)
        let old = try await store.recordHistoryVisit(HistoryVisitEvent(url: URL(string: "https://metadata.example")!, title: "Old title", visitedAt: timestamp, browsingSessionID: session.id, source: .link, faviconReferenceKey: "old-icon"))
        let newest = try await store.recordHistoryVisit(HistoryVisitEvent(url: old.url, title: "New title", visitedAt: timestamp, browsingSessionID: session.id, source: .link, faviconReferenceKey: "new-icon"))
        let before = try #require((try await store.historyCandidates(matching: "metadata")).first)
        #expect(before.title == "New title")
        #expect(before.faviconReferenceKey == "new-icon")
        try await store.deleteHistory(.visits([newest.id]))
        let after = try #require((try await store.historyCandidates(matching: "metadata")).first)
        #expect(after.title == "Old title")
        #expect(after.faviconReferenceKey == "old-icon")
    }

    @Test("rolls a deletion back after its second visit mutation fails")
    func rollsDeletionBackAtomically() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        let setup = try KeelStore(databaseURL: fixture.databaseURL)
        _ = try await setup.apply([.upsertSession(session)])
        let first = try await setup.recordHistoryVisit(event("https://rollback.example", at: 2, session: session.id))
        let second = try await setup.recordHistoryVisit(event("https://rollback.example", at: 3, session: session.id))
        let faulting = try KeelStore(databaseURL: fixture.databaseURL, now: Date.init, faultInjector: { index in
            if index == 1 { throw HistoryFixtureFault.injected }
        })
        await #expect(throws: HistoryFixtureFault.injected) {
            try await faulting.deleteHistory(.visits([first.id, second.id]))
        }
        #expect((try await faulting.historyVisits(in: session.id)).map(\.id) == [first.id, second.id])
        let candidate = try #require((try await faulting.historyCandidates(matching: "rollback")).first)
        #expect(candidate.visitCount == 2)
    }

    private func event(_ value: String, at timestamp: TimeInterval, session: UUID) -> HistoryVisitEvent {
        HistoryVisitEvent(url: URL(string: value)!, visitedAt: Date(timeIntervalSince1970: timestamp), browsingSessionID: session, source: .link)
    }
}

private enum HistoryFixtureFault: Error, Equatable, Sendable {
    case injected
}


private extension HistoryFixture {
    func count(_ table: String) throws -> Int64 {
        let database = try SQLiteDatabase(url: databaseURL)
        guard let count = try database.scalarInteger("SELECT COUNT(*) FROM \(table)") else { throw KeelStoreError.corruptData }
        return count
    }
}
