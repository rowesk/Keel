@testable import KeelStore
import Foundation
import Testing

@Suite("History grouping")
struct HistoryGroupingTests {
    @Test("groups consecutive root hostnames and leaves the root branch intact during a detour")
    func groupsRootAndDetourSeparately() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])
        let rootA = try await store.recordHistoryVisit(event("https://alpha.example/one", at: 2, session: session.id))
        _ = rootA
        _ = try await store.recordHistoryVisit(event("https://alpha.example/two", at: 3, session: session.id))
        _ = try await store.recordHistoryVisit(event("https://beta.example", at: 4, session: session.id))
        _ = try await store.recordHistoryVisit(event("https://alpha.example/three", at: 5, session: session.id))
        let detourID = UUID()
        let detour = try await store.recordHistoryVisit(event("https://checkout.example", at: 6, session: session.id, branch: .transactionalDetour(id: detourID)))
        _ = try await store.recordHistoryVisit(event("https://alpha.example/four", at: 7, session: session.id))

        let groups = try await store.historyHostnameGroups(in: session.id)
        let rootGroups = groups.filter { $0.branchID.rawValue.hasPrefix("root:") }
        let detourGroups = groups.filter { $0.branchID == detour.branchID }
        #expect(rootGroups.map(\.hostname) == ["alpha.example", "beta.example", "alpha.example"])
        #expect(detourGroups.map(\.hostname) == ["checkout.example"])
        #expect((try await store.historyVisits(in: session.id)).filter { $0.branchID == detour.branchID }.count == 1)
    }

    @Test("uses insertion sequence when visits share a timestamp")
    func keepsEqualTimestampVisitAndGroupOrderDeterministic() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])
        let timestamp = Date(timeIntervalSince1970: 2)
        let first = HistoryVisitEvent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, url: URL(string: "https://alpha.example/first")!, visitedAt: timestamp, browsingSessionID: session.id, source: .link)
        let middle = HistoryVisitEvent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, url: URL(string: "https://beta.example")!, visitedAt: timestamp, browsingSessionID: session.id, source: .link)
        let last = HistoryVisitEvent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, url: URL(string: "https://alpha.example/last")!, visitedAt: timestamp, browsingSessionID: session.id, source: .link)
        _ = try await store.recordHistoryVisits([first, middle, last])

        #expect((try await store.historyVisits(in: session.id)).map(\.url.absoluteString) == ["https://alpha.example/first", "https://beta.example/", "https://alpha.example/last"])
        #expect((try await store.historyHostnameGroups(in: session.id)).map(\.hostname) == ["alpha.example", "beta.example", "alpha.example"])
    }

    private func event(_ value: String, at timestamp: TimeInterval, session: UUID, branch: HistoryBranch = .root) -> HistoryVisitEvent {
        HistoryVisitEvent(url: URL(string: value)!, visitedAt: Date(timeIntervalSince1970: timestamp), browsingSessionID: session, branch: branch, source: .link)
    }
}
