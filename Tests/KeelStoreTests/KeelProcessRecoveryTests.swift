@testable import KeelStore
import Darwin
import Foundation
import KeelFoundation
import Testing

@Suite("Store process recovery")
struct KeelProcessRecoveryTests {
    private static let childDirectoryKey = "KEEL_STORE_CRASH_CHILD_DIRECTORY"
    private static let sessionID = UUID(uuidString: "5AD447D8-9425-40A7-891A-5CD12861C897")!
    private static let date = Date(timeIntervalSince1970: 1_800_000_000)
    private static let activeURL = URL(string: "https://active.example/committed")!
    private static let queuedURLs = [URL(string: "https://first.example/")!, URL(string: "https://second.example/")!]

    @Test("SIGKILL preserves committed Store state and rolls back an unfinished apply")
    func committedStateSurvivesKilledWriter() async throws {
        if let path = ProcessInfo.processInfo.environment[Self.childDirectoryKey] {
            try await Self.runChild(in: URL(fileURLWithPath: path, isDirectory: true))
            return
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-store-crash-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("transaction-open")
        let child = Process()
        // SwiftPM loads the test bundle through this helper on macOS. Reuse the
        // current runner and select only this test, never the app executable.
        let arguments = CommandLine.arguments
        let bundleFlag = try #require(arguments.firstIndex(of: "--test-bundle-path"))
        let bundlePath = try #require(arguments.dropFirst(bundleFlag + 1).first)
        child.executableURL = URL(fileURLWithPath: arguments[0])
        child.arguments = ["--test-bundle-path", bundlePath, "--filter", "KeelProcessRecoveryTests/committedStateSurvivesKilledWriter", bundlePath, "--testing-library", "swift-testing"]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.childDirectoryKey] = directory.path
        environment["KEEL_ALLOW_FOREGROUND_TESTS"] = "0"
        child.environment = environment
        let logURL = directory.appendingPathComponent("child.log")
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        child.standardOutput = log
        child.standardError = log
        try child.run()
        defer {
            if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !FileManager.default.fileExists(atPath: ready.path), child.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let childOutput = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        try #require(FileManager.default.fileExists(atPath: ready.path), "Child did not reach the unfinished transaction: \(childOutput)")
        try #require(child.isRunning)
        try #require(kill(child.processIdentifier, SIGKILL) == 0)
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGKILL)

        let reopened = try KeelStore(databaseURL: directory.appendingPathComponent("keel.sqlite"), now: { Self.date })
        let state = try await reopened.runtimeState()
        #expect(state.queue.map(\.url) == Self.queuedURLs)
        #expect(state.queue.map(\.sequence) == [0, 1])
        #expect(state.activeSession == Self.session)
        #expect(state.resumeCheckpoint == Self.checkpoint)
        let visits = try await reopened.historyVisits(in: Self.sessionID)
        #expect(visits.count == 1)
        #expect(visits.first?.url == Self.activeURL)
        #expect(visits.first?.title == "Committed History")
        // A new write proves the killed connection left no live writer lock and
        // the uncommitted capture did not consume a durable queue sequence.
        let commit = try await reopened.apply([.captureQueuedDestination(URL(string: "https://after.example/")!)])
        #expect(commit.runtimeState.queue.map(\.sequence) == [0, 1, 2])
    }

    private static var session: BrowsingSession {
        BrowsingSession(id: sessionID, startedAt: date, hostname: "active.example")
    }

    private static var checkpoint: ResumeCheckpoint {
        ResumeCheckpoint(url: activeURL, sessionID: sessionID, savedAt: date, interactionState: Data([1, 2, 3, 4]))
    }

    private static func runChild(in directory: URL) async throws {
        let databaseURL = directory.appendingPathComponent("keel.sqlite")
        let store = try KeelStore(databaseURL: databaseURL, now: { Self.date })
        _ = try await store.apply([
            .upsertSession(session), .replaceResumeCheckpoint(checkpoint),
            .captureQueuedDestination(queuedURLs[0]), .captureQueuedDestination(queuedURLs[1]),
        ])
        _ = try await store.recordHistoryVisit(HistoryVisitEvent(url: activeURL, title: "Committed History", visitedAt: date, browsingSessionID: sessionID, source: .typedAddress))
        let writer = try KeelStore(databaseURL: databaseURL, now: { Self.date }, faultInjector: { index in
            guard index == 1 else { return }
            // The first command has changed queue and queue_sequence inside
            // apply's transaction. Signal only now, before COMMIT is possible.
            try Data("ready".utf8).write(to: directory.appendingPathComponent("transaction-open"), options: .atomic)
            // Bound the child even if its parent disappears before killing it.
            Thread.sleep(forTimeInterval: 30)
            throw ChildTimeout.parentDidNotKillWriter
        })
        _ = try await writer.apply([
            .captureQueuedDestination(URL(string: "https://uncommitted.example/")!),
            .replaceResumeCheckpoint(nil),
        ])
    }

    private enum ChildTimeout: Error { case parentDidNotKillWriter }
}
