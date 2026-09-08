@testable import KeelStore
import Foundation
import KeelFoundation
import SQLite3
import Testing

@Suite("Keel store")
struct KeelStoreTests {
    @Test("migrates a fresh integrated database and reopens its state store")
    func migratesAndReopens() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let first = try KeelStore(databaseURL: fixture.databaseURL)
        #expect(try await first.runtimeState().settings == KeelSettings())
        _ = first
        let second = try KeelStore(databaseURL: fixture.databaseURL)
        #expect(try await second.runtimeState().queue.isEmpty)
        let tables = try fixture.tableNames()
        #expect(["settings", "queue", "resume_checkpoint", "close_undo", "browsing_sessions", "downloads", "diagnostics"].allSatisfy(tables.contains))
        #expect(["history_branches", "history_hostname_groups", "history_urls", "history_url_terms", "history_visit_sequence", "history_visits", "address_choice_history"].allSatisfy(tables.contains))
        #expect(tables.contains("external_application_approvals"))
    }

    @Test("persists state across reopen and keeps exact queue duplicates in place")
    func persistsRuntimeState() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 10_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        let firstURL = try #require(URL(string: "https://first.example/path"))
        let secondURL = try #require(URL(string: "https://second.example"))
        let session = BrowsingSession(id: UUID(), startedAt: clock.value, hostname: "first.example")
        let checkpoint = ResumeCheckpoint(url: firstURL, sessionID: session.id, savedAt: clock.value, interactionState: Data([1, 2, 3]))
        let download = DownloadRecord(id: UUID(), hostname: "first.example", filename: "invoice.pdf", pathReference: "Downloads/invoice.pdf", byteCount: 42, state: .completed, createdAt: clock.value, completedAt: clock.value)
        let settings = KeelSettings(queueRetention: .days7, keepsClosedPageReady: false, searchProvider: .custom(template: "https://search.example/?q={query}"), diagnosticModeExpiresAt: nil)

        let state = try await store.apply([.captureQueuedDestination(firstURL), .captureQueuedDestination(secondURL), .captureQueuedDestination(firstURL), .upsertSession(session), .replaceResumeCheckpoint(checkpoint), .updateDownload(download), .replaceSettings(settings)])
        #expect(state.runtimeState.queue.map(\.url) == [firstURL, secondURL])
        #expect(state.runtimeState.queue.map(\.sequence) == [0, 1])
        #expect(state.outcomes == [.captured(state.runtimeState.queue[0]), .captured(state.runtimeState.queue[1]), .captured(nil), .completed, .completed, .completed, .completed])

        let reopened = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        let restored = try await reopened.runtimeState()
        #expect(restored.queue.map(\.url) == [firstURL, secondURL])
        #expect(restored.resumeCheckpoint == checkpoint)
        #expect(restored.activeSession == session)
        #expect(restored.downloads == [download])
        #expect(restored.settings == settings)
    }

    @Test("uses current expiry settings at the exact boundary")
    func appliesExpiryAtBoundaryAndAfterSettingsChange() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 100_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        let url = try #require(URL(string: "https://expires.example"))
        _ = try await store.apply([.captureQueuedDestination(url)])

        clock.value = clock.value.addingTimeInterval(TimeInterval(QueueRetention.hours24.rawValue))
        _ = try await store.apply([.replaceSettings(KeelSettings(queueRetention: .hours24))])
        #expect(try await store.runtimeState().queue.isEmpty)
    }

    @Test("restores one latest deletion batch in original FIFO order")
    func restoresLatestQueueDeletionUndo() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 100_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        let one = try #require(URL(string: "https://one.example"))
        let two = try #require(URL(string: "https://two.example"))
        let three = try #require(URL(string: "https://three.example"))
        let initial = try await store.apply([.captureQueuedDestination(one), .captureQueuedDestination(two), .captureQueuedDestination(three)])
        _ = try await store.apply([.removeQueuedDestinations(ids: [initial.runtimeState.queue[0].id, initial.runtimeState.queue[2].id])])
        _ = try await store.apply([.removeQueuedDestinations(ids: [initial.runtimeState.queue[1].id])])
        clock.value = clock.value.addingTimeInterval(59)
        let restored = try await store.apply([.restoreLatestQueueDeletionUndo])
        #expect(restored.runtimeState.queue.map(\.url) == [two])
        #expect(restored.runtimeState.queueDeletionUndo == nil)
    }

    @Test("restores a deleted row ahead of a newer prepend without a sequence collision")
    func restoresDeletedRowAheadOfNewerPrepend() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 100_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        let deletedURL = try #require(URL(string: "https://deleted.example"))
        let existingURL = try #require(URL(string: "https://existing.example"))
        let newerURL = try #require(URL(string: "https://newer.example"))
        let seeded = try await store.apply([.captureQueuedDestination(deletedURL), .captureQueuedDestination(existingURL)])
        let deleted = seeded.runtimeState.queue[0]
        let existing = seeded.runtimeState.queue[1]

        _ = try await store.apply([.removeQueuedDestinations(ids: [deleted.id])])
        let prepended = try await store.apply([.prependQueuedDestination(newerURL)])
        let restored = try await store.apply([.restoreLatestQueueDeletionUndo])

        #expect(restored.runtimeState.queue.map(\.url) == [newerURL, deletedURL, existingURL])
        #expect(restored.runtimeState.queue.map(\.id) == [prepended.runtimeState.queue[0].id, deleted.id, existing.id])
        #expect(Set(restored.runtimeState.queue.map(\.sequence)).count == 3)
        #expect(restored.runtimeState.queueDeletionUndo == nil)
    }

    @Test("restores multiple rows around prepends while skipping exact URL duplicates")
    func restoresMultipleRowsAroundPrependsAndSkipsDuplicates() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 100_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        let firstURL = try #require(URL(string: "https://first.example"))
        let duplicateURL = try #require(URL(string: "https://duplicate.example"))
        let thirdURL = try #require(URL(string: "https://third.example"))
        let remainingURL = try #require(URL(string: "https://remaining.example"))
        let seeded = try await store.apply([
            .captureQueuedDestination(firstURL),
            .captureQueuedDestination(duplicateURL),
            .captureQueuedDestination(thirdURL),
            .captureQueuedDestination(remainingURL),
        ])
        let deleted = [seeded.runtimeState.queue[0], seeded.runtimeState.queue[1], seeded.runtimeState.queue[3]]
        let surviving = seeded.runtimeState.queue[2]

        _ = try await store.apply([.removeQueuedDestinations(ids: deleted.map(\.id))])
        let duplicate = try await store.apply([.prependQueuedDestination(duplicateURL)])
        let restored = try await store.apply([.restoreLatestQueueDeletionUndo])

        #expect(restored.runtimeState.queue.map(\.url) == [duplicateURL, firstURL, thirdURL, remainingURL])
        #expect(restored.runtimeState.queue.map(\.id) == [duplicate.runtimeState.queue[0].id, deleted[0].id, surviving.id, deleted[2].id])
        #expect(restored.runtimeState.queue.filter { $0.url == duplicateURL }.count == 1)
        #expect(restored.runtimeState.queueDeletionUndo == nil)
    }

    @Test("does not restore an expired deletion batch")
    func expiredDeletionIsFinal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 100_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        let url = try #require(URL(string: "https://one.example"))
        let captured = try await store.apply([.captureQueuedDestination(url)])
        _ = try await store.apply([.removeQueuedDestinations(ids: [captured.runtimeState.queue[0].id])])
        clock.value = clock.value.addingTimeInterval(61)
        #expect(try await store.apply([.restoreLatestQueueDeletionUndo]).runtimeState.queue.isEmpty)
    }

    @Test("rolls a multi-change batch back on an injected failure")
    func rollsBackAtomically() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 100_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value }, faultInjector: { index in
            if index == 1 { throw FixtureFault.injected }
        })
        let one = try #require(URL(string: "https://one.example"))
        let two = try #require(URL(string: "https://two.example"))
        await #expect(throws: FixtureFault.injected) {
            _ = try await store.apply([.captureQueuedDestination(one), .captureQueuedDestination(two)])
        }
        #expect(try await store.runtimeState().queue.isEmpty)
    }

    @Test("diagnostics expire, retain only safe fields, and can be deleted")
    func diagnosticsAreBoundedAndDeletable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 100_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        let hostname = try DiagnosticHostname("Shop.Example")
        #expect(throws: KeelStoreError.invalidDiagnosticHostname) { _ = try DiagnosticHostname("https://shop.example/path?q=secret") }
        let record = DiagnosticRecord(timestamp: clock.value, eventType: .navigation, hostname: hostname, result: .succeeded, durationMilliseconds: 7)
        _ = try await store.apply([.recordDiagnostic(record)])
        #expect(try await store.diagnostics().isEmpty)

        _ = try await store.apply([.replaceSettings(KeelSettings(diagnosticModeExpiresAt: clock.value.addingTimeInterval(1_800))), .recordDiagnostic(record)])
        #expect(try await store.diagnostics().map(\.hostname.value) == ["shop.example"])
        clock.value = clock.value.addingTimeInterval(1_801)
        _ = try await store.apply([.recordDiagnostic(record), .deleteDiagnostics])
        #expect(try await store.diagnostics().isEmpty)
    }

    @Test("clearing the queue creates one 60-second undo batch without changing automatic expiry")
    func clearingQueueUsesTheSameSingleDeletionUndo() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 100_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        let first = try #require(URL(string: "https://first.example"))
        let second = try #require(URL(string: "https://second.example"))
        _ = try await store.apply([.captureQueuedDestination(first), .captureQueuedDestination(second)])

        let cleared = try await store.apply([.clearQueuedDestinations])
        let undo = try #require(cleared.runtimeState.queueDeletionUndo)
        #expect(cleared.runtimeState.queue.isEmpty)
        #expect(undo.destinations.map(\.url) == [first, second])
        #expect(undo.deadline == clock.value.addingTimeInterval(60))

        clock.value = clock.value.addingTimeInterval(59)
        let restored = try await store.apply([.restoreLatestQueueDeletionUndo])
        #expect(restored.runtimeState.queue.map(\.url) == [first, second])
        #expect(restored.runtimeState.queueDeletionUndo == nil)

        clock.value = clock.value.addingTimeInterval(TimeInterval(QueueRetention.hours72.rawValue))
        #expect(try await store.runtimeState().queue.isEmpty)
    }

    @Test("automatic queue expiry removes work without creating deletion undo")
    func automaticQueueExpiryDoesNotCreateDeletionUndo() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 100_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        let url = try #require(URL(string: "https://expires.example"))
        _ = try await store.apply([.captureQueuedDestination(url)])

        clock.value = clock.value.addingTimeInterval(TimeInterval(QueueRetention.hours72.rawValue))
        let expired = try await store.runtimeState()
        #expect(expired.queue.isEmpty)
        #expect(expired.queueDeletionUndo == nil)
    }

    @Test("legacy invalid custom search falls back without rewriting the stored value")
    func legacyCustomSearchRemainsReadable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let database = try SQLiteDatabase(url: fixture.databaseURL)
        let original = "custom:https://{query}.example/search"
        try database.execute("UPDATE settings SET search_provider = ? WHERE singleton = 1", values: [.text(original)])
        #expect(try await store.runtimeState().settings.searchProvider == .google)
        #expect(try database.scalarText("SELECT search_provider FROM settings WHERE singleton = 1") == original)
        let reopened = try KeelStore(databaseURL: fixture.databaseURL)
        #expect(try await reopened.runtimeState().settings.searchProvider == .google)
        _ = try await reopened.apply([.replaceSettings(KeelSettings(searchProvider: .duckDuckGo))])
        #expect(try await reopened.runtimeState().settings.searchProvider == .duckDuckGo)
    }

    @Test("settings accept built-in providers and reject unsafe custom search URLs")
    func validatesSettingsProviders() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 100_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })

        for provider in [SearchProvider.google, .duckDuckGo, .kagi, .custom(template: "https://search.example/?q={query}"), .custom(template: "https://search.example/find/{query}")] {
            let settings = KeelSettings(queueRetention: .days7, keepsClosedPageReady: false, searchProvider: provider)
            #expect(try await store.apply([.replaceSettings(settings)]).runtimeState.settings == settings)
        }

        for invalid in [
            "https://{query}.example/search",
            "https://example.{query}/search",
            "{query}://search.example/",
            "https://search.example/#q={query}",
            "search.example/?q={query}",
            "file:///tmp/{query}",
            "https://user:secret@search.example/?q={query}",
            "https://search.example/?q={query}#fragment",
            "https://search.example/?q={query}&fallback={query}",
            "https://search.example/?q=missing",
        ] {
            await #expect(throws: KeelStoreError.invalidSettings) {
                _ = try await store.apply([.replaceSettings(KeelSettings(searchProvider: .custom(template: invalid)))])
            }
        }
    }

    @Test("download reads are persistent, bounded, and diagnostics export does not mutate state")
    func readsDownloadsAndExportsDiagnosticsWithoutWrites() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 100_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        let records = (0 ..< 350).map { index in
            DownloadRecord(
                id: UUID(),
                hostname: "downloads.example",
                filename: "file-\(index).pdf",
                byteCount: Int64(index),
                state: .completed,
                createdAt: clock.value.addingTimeInterval(TimeInterval(index)),
                completedAt: clock.value.addingTimeInterval(TimeInterval(index))
            )
        }
        _ = try await store.apply(records.map(StoreChange.updateDownload))

        let started = ContinuousClock.now
        let latest = try await store.downloadRecords(limit: 25)
        let elapsed = ContinuousClock.now - started
        #expect(latest.count == 25)
        #expect(latest.first?.filename == "file-349.pdf")
        #expect(elapsed < .seconds(1))
        await #expect(throws: KeelStoreError.invalidDownloadReadLimit) {
            _ = try await store.downloadRecords(limit: 0)
        }

        let hostname = try DiagnosticHostname("shop.example")
        let diagnostic = DiagnosticRecord(timestamp: clock.value, eventType: .download, hostname: hostname, result: .succeeded)
        _ = try await store.apply([
            .replaceSettings(KeelSettings(diagnosticModeExpiresAt: clock.value.addingTimeInterval(60))),
            .recordDiagnostic(diagnostic),
        ])
        let before = try await store.diagnostics()
        let data = try await store.diagnosticExportData()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(DiagnosticExport.self, from: data)
        #expect(export.records == before)
        #expect(try await store.diagnostics() == before)
    }

    @Test("consumes the FIFO destination atomically without creating queue-deletion undo")
    func consumesOldestQueuedDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 100_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        let one = try #require(URL(string: "https://one.example"))
        let two = try #require(URL(string: "https://two.example"))
        let commit = try await store.apply([.captureQueuedDestination(one), .captureQueuedDestination(two), .consumeOldestQueuedDestination])
        #expect(commit.runtimeState.queue.map(\.url) == [two])
        #expect(commit.runtimeState.queueDeletionUndo == nil)
        guard case let .consumed(destination) = commit.outcomes[2] else {
            Issue.record("Expected consume outcome")
            return
        }
        #expect(destination?.url == one)
    }

    @Test("prepends an Undo-return URL without moving an exact duplicate")
    func prependsUndoReturnURL() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 100_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        let one = try #require(URL(string: "https://one.example"))
        let two = try #require(URL(string: "https://two.example"))
        let returned = try #require(URL(string: "https://returned.example"))
        let seeded = try await store.apply([.captureQueuedDestination(one), .captureQueuedDestination(two)])
        let originalTwo = seeded.runtimeState.queue[1]
        clock.value = clock.value.addingTimeInterval(60)

        let prepended = try await store.apply([.prependQueuedDestination(returned)])
        let duplicate = try await store.apply([.prependQueuedDestination(two)])

        #expect(prepended.runtimeState.queue.map(\.url) == [returned, one, two])
        #expect(prepended.runtimeState.queue.map(\.sequence) == [-1, 0, 1])
        #expect(prepended.runtimeState.queue[2] == originalTwo)
        #expect(duplicate.outcomes == [.captured(nil)])
        #expect(duplicate.runtimeState.queue == prepended.runtimeState.queue)
    }

    @Test("reindexes FIFO order transactionally when prepending reaches Int64 underflow")
    func prependingAtInt64MinimumReindexesQueue() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 100_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        let one = try #require(URL(string: "https://one.example"))
        let two = try #require(URL(string: "https://two.example"))
        let returned = try #require(URL(string: "https://returned.example"))
        let after = try #require(URL(string: "https://after.example"))
        let seeded = try await store.apply([.captureQueuedDestination(one), .captureQueuedDestination(two)])
        let original = seeded.runtimeState.queue
        try fixture.setQueueSequences([
            original[0].id: Int64.min,
            original[1].id: Int64.min + 1,
        ])

        let prepended = try await store.apply([.prependQueuedDestination(returned)])
        let appended = try await store.apply([.captureQueuedDestination(after)])

        #expect(prepended.runtimeState.queue.map(\.url) == [returned, one, two])
        #expect(prepended.runtimeState.queue.map(\.sequence) == [0, 1, 2])
        #expect(prepended.runtimeState.queue[1].capturedAt == original[0].capturedAt)
        #expect(prepended.runtimeState.queue[2].capturedAt == original[1].capturedAt)
        #expect(appended.runtimeState.queue.map(\.sequence) == [0, 1, 2, 3])
    }

    @Test("advancing FIFO starts a session only after consuming an unexpired destination")
    func advancingFIFOStartsSessionOnlyAfterConsume() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 100_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        let queued = try #require(URL(string: "https://queued.example/path"))
        let session = BrowsingSession(id: UUID(), startedAt: clock.value)
        _ = try await store.apply([.captureQueuedDestination(queued)])

        let advanced = try await store.apply([.advanceToOldestQueuedDestination(startingSession: session)])
        guard case let .consumed(destination) = advanced.outcomes[0] else {
            Issue.record("Expected FIFO consumption")
            return
        }
        #expect(destination?.url == queued)
        #expect(advanced.runtimeState.queue.isEmpty)
        #expect(advanced.runtimeState.activeSession == BrowsingSession(id: session.id, startedAt: session.startedAt, hostname: "queued.example"))

        let expiredFixture = try Fixture()
        defer { expiredFixture.remove() }
        let expiredStore = try KeelStore(databaseURL: expiredFixture.databaseURL, now: { clock.value })
        _ = try await expiredStore.apply([.captureQueuedDestination(queued)])
        clock.value = clock.value.addingTimeInterval(TimeInterval(QueueRetention.hours72.rawValue))
        let expired = try await expiredStore.apply([.advanceToOldestQueuedDestination(startingSession: BrowsingSession(id: UUID(), startedAt: clock.value))])
        #expect(expired.outcomes == [.consumed(nil)])
        #expect(expired.runtimeState.queue.isEmpty)
        #expect(expired.runtimeState.activeSession == nil)
    }

    @Test("uses the Keel application-support database path in production")
    func usesProductionPath() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let paths = KeelPaths(applicationSupportDirectory: fixture.directory)
        let store = try KeelStore(paths: paths)
        #expect(store.databaseURL == paths.databaseURL)
        #expect(try await store.runtimeState().settings == KeelSettings())
    }

    @Test("a no-op deletion leaves the latest valid deletion undo untouched")
    func noOpDeletionPreservesUndo() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 100_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        let url = try #require(URL(string: "https://one.example"))
        let captured = try await store.apply([.captureQueuedDestination(url)])
        let deleted = try await store.apply([.removeQueuedDestinations(ids: [captured.runtimeState.queue[0].id])])
        let undo = try #require(deleted.runtimeState.queueDeletionUndo)
        let noOp = try await store.apply([.removeQueuedDestinations(ids: [UUID()])])
        #expect(noOp.runtimeState.queueDeletionUndo == undo)
    }

    @Test("an exact duplicate keeps its original queue age")
    func duplicateKeepsCapturedAt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 100_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        let url = try #require(URL(string: "https://one.example"))
        let first = try await store.apply([.captureQueuedDestination(url)])
        let capturedAt = first.runtimeState.queue[0].capturedAt
        clock.value = clock.value.addingTimeInterval(300)
        let duplicate = try await store.apply([.captureQueuedDestination(url)])
        #expect(duplicate.outcomes == [.captured(nil)])
        #expect(duplicate.runtimeState.queue[0].capturedAt == capturedAt)
    }

    @Test("persists close undo and prunes it at its exact deadline")
    func persistsAndExpiresCloseUndo() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clock = FixtureClock(Date(timeIntervalSince1970: 100_000))
        let record = CloseUndoRecord(url: try #require(URL(string: "https://close.example")), sessionID: UUID(), closedAt: clock.value, deadline: clock.value.addingTimeInterval(60))
        let first = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        _ = try await first.apply([.replaceCloseUndo(record)])
        let reopened = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        #expect(try await reopened.runtimeState().closeUndo == record)
        clock.value = clock.value.addingTimeInterval(60)
        #expect(try await reopened.runtimeState().closeUndo == nil)
    }

    @Test("migration ledger is idempotent and a failed migration preserves existing state")
    func migratesIdempotentlyAndRollsBack() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let database = try SQLiteDatabase(url: fixture.databaseURL)
        try KeelStoreMigrationRunner.apply(database, migrations: KeelStore.migrations)
        try KeelStoreMigrationRunner.apply(database, migrations: KeelStore.migrations)
        #expect(try database.rows("SELECT identifier FROM keel_schema_migrations ORDER BY identifier ASC").compactMap { $0.text(0) } == ["external-apps.0001", "external-apps.0002", "history.0001", "home-scenes.0001", "state.0001", "state.0002"])
        try database.execute("CREATE TABLE sentinel (value TEXT NOT NULL)")
        try database.execute("INSERT INTO sentinel (value) VALUES ('kept')")
        let failing = KeelStoreMigration(identifier: "test.failure") { database in
            try database.execute("CREATE TABLE discarded_by_rollback (value INTEGER)")
            throw FixtureFault.injected
        }
        #expect(throws: FixtureFault.injected) {
            try KeelStoreMigrationRunner.apply(database, migrations: [failing])
        }
        #expect(try database.scalarText("SELECT value FROM sentinel") == "kept")
        #expect(try database.scalarText("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'discarded_by_rollback'") == nil)
    }

    @Test("diagnostic estimated bytes stay within the five MiB cap")
    func keepsDiagnosticEstimatedBytesWithinCap() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.seedOversizedDiagnostic()
        let clock = FixtureClock(Date(timeIntervalSince1970: 100_000))
        let store = try KeelStore(databaseURL: fixture.databaseURL, now: { clock.value })
        let record = DiagnosticRecord(timestamp: clock.value, eventType: .navigation, hostname: try DiagnosticHostname("shop.example"), result: .succeeded)
        _ = try await store.apply([.recordDiagnostic(record)])
        #expect(try await store.diagnosticEstimatedBytes() <= KeelStore.diagnosticByteCap)
        #expect(try await store.diagnostics().count == 1)
    }

    @Test("remembers external app approvals by source and scheme without persisting target URLs")
    func remembersExternalApplicationApprovals() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let approval = try ExternalApplicationApprovalKey(
            principal: .websiteHostname("shop.example"),
            scheme: "MAILTO"
        )
        let otherSource = try ExternalApplicationApprovalKey(principal: .keel, scheme: "mailto")

        #expect(try await store.hasExternalApplicationApproval(for: approval) == false)
        _ = try await store.apply([.rememberExternalApplicationApproval(approval)])
        #expect(try await store.hasExternalApplicationApproval(for: approval))
        #expect(try await store.hasExternalApplicationApproval(for: otherSource) == false)

        _ = try await store.apply([.forgetExternalApplicationApproval(approval)])
        #expect(try await store.hasExternalApplicationApproval(for: approval) == false)
    }

    @Test("keeps typed Keel approvals separate from a website hostname named keel")
    func keepsTypedKeelSeparateFromWebsiteHostname() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let typed = try ExternalApplicationApprovalKey(principal: .keel, scheme: "mailto")
        let website = try ExternalApplicationApprovalKey(principal: .websiteHostname("keel"), scheme: "mailto")

        _ = try await store.apply([.rememberExternalApplicationApproval(typed)])
        #expect(try await store.hasExternalApplicationApproval(for: typed))
        #expect(try await store.hasExternalApplicationApproval(for: website) == false)
    }

    @Test("migrates legacy source approvals as websites so they cannot grant typed Keel")
    func migratesLegacyApprovalsAsWebsites() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let database = try SQLiteDatabase(url: fixture.databaseURL)
        try KeelStoreMigrationRunner.apply(database, migrations: Array(KeelStore.migrations.prefix(3)))
        try database.execute(
            "INSERT INTO external_application_approvals (source, scheme, approved_at) VALUES ('keel', 'mailto', 1)"
        )
        try KeelStoreMigrationRunner.apply(database, migrations: KeelStore.migrations)
        let store = try KeelStore(databaseURL: fixture.databaseURL)
        let typed = try ExternalApplicationApprovalKey(principal: .keel, scheme: "mailto")
        let website = try ExternalApplicationApprovalKey(principal: .websiteHostname("keel"), scheme: "mailto")

        #expect(try await store.hasExternalApplicationApproval(for: typed) == false)
        #expect(try await store.hasExternalApplicationApproval(for: website))
    }

    @Test("rejects invalid website principals in external app approval keys")
    func rejectsURLShapedExternalApplicationApprovalKeys() {
        #expect(throws: KeelStoreError.invalidExternalApplicationApproval) {
            _ = try ExternalApplicationApprovalKey(
                principal: .websiteHostname("https://shop.example/private"),
                scheme: "mailto"
            )
        }
    }
}

private final class FixtureClock: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

private enum FixtureFault: Error, Equatable, Sendable {
    case injected
}

private final class Fixture {
    let directory: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "KeelStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        databaseURL = directory.appending(path: "Keel.sqlite3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func tableNames() throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path(percentEncoded: false), &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else { throw KeelStoreError.corruptData }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &statement, nil) == SQLITE_OK, let statement else { throw KeelStoreError.corruptData }
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 0) { names.append(String(cString: name)) }
        }
        return names
    }

    func setQueueSequences(_ sequences: [UUID: Int64]) throws {
        let database = try SQLiteDatabase(url: databaseURL)
        for (id, sequence) in sequences {
            try database.execute(
                "UPDATE queue SET sequence = ? WHERE id = ?",
                values: [.integer(sequence), .text(id.uuidString)]
            )
        }
    }

    func seedOversizedDiagnostic() throws {
        let database = try SQLiteDatabase(url: databaseURL)
        try KeelStoreMigrationRunner.apply(database, migrations: KeelStore.migrations)
        try database.execute("UPDATE settings SET diagnostic_mode_expires_at = ? WHERE singleton = 1", values: [.real(101_800)])
        try database.execute("INSERT INTO diagnostics (timestamp, event_type, hostname, result, estimated_bytes) VALUES (?, 'navigation', 'seed.example', 'succeeded', ?)", values: [.real(100_000), .integer(KeelStore.diagnosticByteCap + 1)])
    }
}
