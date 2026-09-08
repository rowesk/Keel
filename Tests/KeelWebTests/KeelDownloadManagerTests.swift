import Foundation
import XCTest
@testable import KeelWeb

@MainActor
final class KeelDownloadManagerTests: XCTestCase {
    func testFourNoisyDownloadsProduceOneImmediateAndOneBatchedProgressRefresh() {
        var batcher = KeelDownloadProgressBatcher(minimumInterval: 0.1)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let identifiers = (0 ..< 4).map { _ in UUID() }

        XCTAssertEqual(batcher.receive(identifier: identifiers[0], at: start), .publishNow)
        XCTAssertEqual(batcher.takePending(at: start), [identifiers[0]])

        for identifier in identifiers {
            XCTAssertEqual(
                batcher.receive(identifier: identifier, at: start.addingTimeInterval(0.01)),
                .deferUntil(start.addingTimeInterval(0.1))
            )
        }
        for identifier in identifiers.reversed() {
            XCTAssertEqual(
                batcher.receive(identifier: identifier, at: start.addingTimeInterval(0.02)),
                .deferUntil(start.addingTimeInterval(0.1))
            )
        }

        XCTAssertEqual(
            batcher.takePending(at: start.addingTimeInterval(0.1)),
            identifiers.sorted { $0.uuidString < $1.uuidString }
        )
    }

    func testTerminalDownloadLeavesNoDeferredProgressPublication() {
        var batcher = KeelDownloadProgressBatcher(minimumInterval: 0.1)
        let identifier = UUID()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(batcher.receive(identifier: identifier, at: start), .publishNow)
        _ = batcher.takePending(at: start)
        XCTAssertEqual(batcher.receive(identifier: identifier, at: start.addingTimeInterval(0.01)), .deferUntil(start.addingTimeInterval(0.1)))
        batcher.remove(identifier: identifier)

        XCTAssertEqual(batcher.takePending(at: start.addingTimeInterval(0.1)), [])
    }

    func testCancelAndWaitReturnsOnlyAfterTheFinishedEventIsPublished() async throws {
        var events: [KeelDownloadLifecycleEvent] = []
        let manager = makeManager { events.append($0) }
        let requestor = DeferredCancellationRequestor()
        let identifier = manager.registerForTesting(
            snapshot: snapshot(id: UUID()),
            cancellationRequestor: requestor
        )
        let completion = CompletionFlag()

        let task = Task { @MainActor in
            await manager.cancelAndWait(id: identifier)
            completion.didReturn = true
        }
        await Task.yield()

        XCTAssertEqual(requestor.requestCount, 1)
        XCTAssertFalse(completion.didReturn)
        XCTAssertFalse(events.contains { if case .finished = $0 { true } else { false } })

        requestor.completeNext()
        await task.value

        XCTAssertTrue(completion.didReturn)
        guard case let .finished(snapshot)? = events.last else {
            return XCTFail("Expected a terminal download event before cancellation returned")
        }
        XCTAssertEqual(snapshot.id, identifier)
        XCTAssertEqual(snapshot.state, .cancelled)
    }

    func testDelegateFailureAndCancelCompletionFinishOnceAndReleaseEveryWaiter() async throws {
        var events: [KeelDownloadLifecycleEvent] = []
        let manager = makeManager { events.append($0) }
        let requestor = DeferredCancellationRequestor()
        let identifier = manager.registerForTesting(
            snapshot: snapshot(id: UUID()),
            cancellationRequestor: requestor
        )
        let first = CompletionFlag()
        let second = CompletionFlag()

        async let firstWait: Void = manager.cancelAndWait(id: identifier)
        async let secondWait: Void = manager.cancelAndWait(id: identifier)
        await Task.yield()
        XCTAssertEqual(requestor.requestCount, 1)

        manager.receiveFailureForTesting(id: identifier, errorCode: -999)
        await firstWait
        first.didReturn = true
        await secondWait
        second.didReturn = true
        requestor.completeNext()
        await Task.yield()

        XCTAssertTrue(first.didReturn)
        XCTAssertTrue(second.didReturn)
        let finished = events.compactMap { event -> KeelDownloadSnapshot? in
            guard case let .finished(snapshot) = event else { return nil }
            return snapshot
        }
        XCTAssertEqual(finished, [try XCTUnwrap(manager.snapshot(id: identifier))])
        XCTAssertEqual(finished.first?.state, .cancelled)
    }

    func testCancelAllWaitsForEveryActiveTransfer() async throws {
        let manager = makeManager()
        let firstRequestor = DeferredCancellationRequestor()
        let secondRequestor = DeferredCancellationRequestor()
        let firstID = manager.registerForTesting(snapshot: snapshot(id: UUID()), cancellationRequestor: firstRequestor)
        let secondID = manager.registerForTesting(snapshot: snapshot(id: UUID()), cancellationRequestor: secondRequestor)
        let completion = CompletionFlag()

        let task = Task { @MainActor in
            await manager.cancelAllAndWait()
            completion.didReturn = true
        }
        for _ in 0 ..< 4 { await Task.yield() }

        XCTAssertEqual(firstRequestor.requestCount, 1)
        XCTAssertEqual(secondRequestor.requestCount, 1)
        XCTAssertFalse(completion.didReturn)

        firstRequestor.completeNext()
        for _ in 0 ..< 2 { await Task.yield() }
        XCTAssertFalse(completion.didReturn)

        secondRequestor.completeNext()
        await task.value

        XCTAssertTrue(completion.didReturn)
        XCTAssertEqual(manager.snapshot(id: firstID)?.state, .cancelled)
        XCTAssertEqual(manager.snapshot(id: secondID)?.state, .cancelled)
    }

    private func makeManager(
        lifecycleSink: @escaping KeelDownloadLifecycleSink = { _ in }
    ) -> KeelDownloadManager {
        KeelDownloadManager(
            destinationDirectory: FileManager.default.temporaryDirectory,
            lifecycleSink: lifecycleSink
        )
    }

    private func snapshot(id: UUID) -> KeelDownloadSnapshot {
        KeelDownloadSnapshot(
            id: id,
            sourceHostname: "files.example",
            filename: "report.pdf",
            state: .inProgress,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
    }
}

@MainActor
private final class DeferredCancellationRequestor: KeelDownloadCancellationRequesting {
    private var completions: [@MainActor @Sendable () -> Void] = []
    private(set) var requestCount = 0

    func requestCancellation(completion: @escaping @MainActor @Sendable () -> Void) {
        requestCount += 1
        completions.append(completion)
    }

    func completeNext() {
        guard !completions.isEmpty else { return }
        completions.removeFirst()()
    }
}

@MainActor
private final class CompletionFlag {
    var didReturn = false
}
