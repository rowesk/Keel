@testable import KeelStore
import Foundation
import Testing

@Suite("History recording")
struct HistoryRecordingTests {
    @Test("records safe top-level HTTP visits and persists them")
    func recordsSafeVisitsAndReopens() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])

        let event = HistoryVisitEvent(
            url: try #require(URL(string: "HTTP://user:secret@Example.COM:80/path?q=keel#section")),
            title: "Keel page",
            visitedAt: Date(timeIntervalSince1970: 2),
            browsingSessionID: session.id,
            source: .typedAddress,
            faviconReferenceKey: "example.com"
        )
        let visit = try await store.recordHistoryVisit(event)
        #expect(visit.url.absoluteString == "http://example.com/path?q=keel")
        #expect(visit.title == "Keel page")

        let reopened = try KeelStore(databaseURL: fixture.databaseURL)
        let visits = try await reopened.historyVisits(in: session.id)
        #expect(visits == [visit])
        #expect((try await reopened.historyCandidates(matching: "exam")).isEmpty)
        let exact = try #require((try await reopened.addressSuggestions(for: "http://example.com/path?q=keel").suggestions).first)
        #expect(exact.url.absoluteString == "http://example.com/path?q=keel")
        #expect(exact.faviconReferenceKey == "example.com")
    }

    @Test("rejects non-web schemes")
    func rejectsNonWebSchemes() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: .now)
        _ = try await store.apply([.upsertSession(session)])
        let event = HistoryVisitEvent(url: try #require(URL(string: "file:///private/report.pdf")), visitedAt: .now, browsingSessionID: session.id, source: .external)
        await #expect(throws: HistoryStoreError.invalidURL) { _ = try await store.recordHistoryVisit(event) }
    }

    @Test("uses explicit navigation rules without accidental duplicates")
    func recordsExplicitNavigationKinds() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])
        let initial = try await store.recordHistoryVisit(HistoryVisitEvent(url: try #require(URL(string: "https://one.example/start")), title: "Start", visitedAt: Date(timeIntervalSince1970: 2), browsingSessionID: session.id, source: .link))
        let reloaded = try await store.recordHistoryVisit(HistoryVisitEvent(url: initial.url, title: "Reloaded", visitedAt: Date(timeIntervalSince1970: 3), browsingSessionID: session.id, navigationKind: .reload, source: .link, currentVisitID: initial.id))
        #expect(reloaded.id == initial.id)
        let redirected = try await store.recordHistoryVisit(HistoryVisitEvent(url: try #require(URL(string: "https://two.example/final")), visitedAt: Date(timeIntervalSince1970: 4), browsingSessionID: session.id, navigationKind: .redirect, source: .link))
        _ = redirected
        for (offset, kind) in [HistoryNavigationKind.back, .forward, .pushState, .popState, .hashNavigation].enumerated() {
            _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: try #require(URL(string: "https://one.example/\(kind.rawValue)#anchor")), visitedAt: Date(timeIntervalSince1970: TimeInterval(5 + offset)), browsingSessionID: session.id, navigationKind: kind, source: .link))
        }
        let replaced = try await store.recordHistoryVisit(HistoryVisitEvent(url: try #require(URL(string: "https://three.example/replaced")), visitedAt: Date(timeIntervalSince1970: 20), browsingSessionID: session.id, navigationKind: .replaceState, source: .link, currentVisitID: initial.id))
        #expect(replaced.id == initial.id)
        try await store.updateHistoryTitle(visitID: initial.id, title: "Final title")

        let visits = try await store.historyVisits(in: session.id)
        #expect(visits.count == 7)
        #expect(visits.map(\.navigationKind).contains(.redirect))
        #expect(visits.map(\.navigationKind).contains(.back))
        #expect(visits.map(\.navigationKind).contains(.forward))
        #expect(visits.map(\.navigationKind).contains(.pushState))
        #expect(visits.map(\.navigationKind).contains(.popState))
        #expect(visits.map(\.navigationKind).contains(.hashNavigation))
        #expect(visits.first(where: { $0.id == initial.id })?.title == "Final title")
        #expect((try await store.historyCandidates(matching: "three")).count == 1)
    }

    @Test("keeps the typed signal when reload and replaceState change the current source")
    func preservesTypedCountAcrossInPlaceNavigation() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let session = BrowsingSession(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.apply([.upsertSession(session)])
        let url = URL(string: "https://typed.example/start")!
        let typed = try await store.recordHistoryVisit(HistoryVisitEvent(url: url, visitedAt: Date(timeIntervalSince1970: 2), browsingSessionID: session.id, source: .typedAddress))
        _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: url, visitedAt: Date(timeIntervalSince1970: 3), browsingSessionID: session.id, navigationKind: .reload, source: .link, currentVisitID: typed.id))
        _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: URL(string: "https://typed.example/replaced")!, visitedAt: Date(timeIntervalSince1970: 4), browsingSessionID: session.id, navigationKind: .replaceState, source: .link, currentVisitID: typed.id))
        let candidate = try #require((try await store.historyCandidates(matching: "typed")).first)
        #expect(candidate.typedCount == 1)
        #expect(candidate.lastTypedAt == Date(timeIntervalSince1970: 2))
    }
}
