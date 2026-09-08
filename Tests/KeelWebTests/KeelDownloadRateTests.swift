import Foundation
import XCTest
@testable import KeelWeb

@MainActor
final class KeelDownloadRateTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    func testRateFollowsTheRecentWindowRatherThanTheWholeTransfer() throws {
        var estimator = KeelDownloadRateEstimator(window: 5, stallThreshold: 3)

        // Ten slow seconds at 100 KB/s, then five fast ones at 1 MB/s. A total-over-
        // elapsed average would report about 400 KB/s for a transfer running at 1 MB/s.
        var received: Int64 = 0
        for second in 1 ... 10 {
            received += 100_000
            estimator.record(receivedBytes: received, at: start.addingTimeInterval(TimeInterval(second)))
        }
        for second in 11 ... 15 {
            received += 1_000_000
            estimator.record(receivedBytes: received, at: start.addingTimeInterval(TimeInterval(second)))
        }

        let estimate = estimator.estimate(at: start.addingTimeInterval(15))
        let bytesPerSecond = try XCTUnwrap(estimate.bytesPerSecond)
        XCTAssertEqual(bytesPerSecond, 1_000_000, accuracy: 20_000)
        XCTAssertFalse(estimate.isStalled)
    }

    func testASingleSampleGivesNoRateBecauseNoIntervalHasBeenObserved() {
        var estimator = KeelDownloadRateEstimator()
        estimator.record(receivedBytes: 4_096, at: start)

        XCTAssertEqual(estimator.estimate(at: start), .unknown)
    }

    func testAStandingByteCountReadsAsStalledInsteadOfTheLastRate() {
        var estimator = KeelDownloadRateEstimator(window: 5, stallThreshold: 3)
        estimator.record(receivedBytes: 1_000, at: start)
        estimator.record(receivedBytes: 3_000, at: start.addingTimeInterval(1))

        XCTAssertEqual(estimator.estimate(at: start.addingTimeInterval(1)).bytesPerSecond, 2_000)

        // Callbacks keep arriving with the same byte count.
        estimator.record(receivedBytes: 3_000, at: start.addingTimeInterval(3))
        let stalled = estimator.estimate(at: start.addingTimeInterval(4.5))

        XCTAssertTrue(stalled.isStalled)
        XCTAssertNil(stalled.bytesPerSecond)
    }

    func testTheManagerPublishesARateAndThenAStallForTheSameTransfer() {
        var clock = start
        var events: [KeelDownloadLifecycleEvent] = []
        let manager = KeelDownloadManager(
            destinationDirectory: FileManager.default.temporaryDirectory,
            now: { clock },
            lifecycleSink: { events.append($0) }
        )
        let identifier = manager.registerForTesting(
            snapshot: KeelDownloadSnapshot(
                id: UUID(),
                sourceHostname: "files.example",
                filename: "report.pdf",
                expectedBytes: 10_000_000,
                state: .inProgress,
                createdAt: start
            ),
            cancellationRequestor: IdleCancellationRequestor()
        )

        manager.receiveProgressForTesting(id: identifier, receivedBytes: 1_000_000)
        clock = start.addingTimeInterval(1)
        manager.receiveProgressForTesting(id: identifier, receivedBytes: 3_000_000)

        XCTAssertEqual(manager.snapshot(id: identifier)?.bytesPerSecond, 2_000_000)
        XCTAssertEqual(manager.snapshot(id: identifier)?.isStalled, false)

        clock = start.addingTimeInterval(9)
        manager.receiveProgressForTesting(id: identifier, receivedBytes: 3_000_000)

        XCTAssertNil(manager.snapshot(id: identifier)?.bytesPerSecond)
        XCTAssertEqual(manager.snapshot(id: identifier)?.isStalled, true)
        XCTAssertFalse(events.isEmpty)
    }

    func testFinishingClearsTheRateSoATerminalCardNeverQuotesASpeed() {
        var clock = start
        let manager = KeelDownloadManager(
            destinationDirectory: FileManager.default.temporaryDirectory,
            now: { clock }
        )
        let identifier = manager.registerForTesting(
            snapshot: KeelDownloadSnapshot(
                id: UUID(),
                sourceHostname: "files.example",
                filename: "report.pdf",
                expectedBytes: 4_000,
                state: .inProgress,
                createdAt: start
            ),
            cancellationRequestor: IdleCancellationRequestor()
        )
        manager.receiveProgressForTesting(id: identifier, receivedBytes: 1_000)
        clock = start.addingTimeInterval(1)
        manager.receiveProgressForTesting(id: identifier, receivedBytes: 4_000)
        manager.receiveTerminalStateForTesting(id: identifier, state: .completed)

        XCTAssertNil(manager.snapshot(id: identifier)?.bytesPerSecond)
        XCTAssertEqual(manager.snapshot(id: identifier)?.isStalled, false)
    }
}

@MainActor
private final class IdleCancellationRequestor: KeelDownloadCancellationRequesting {
    func requestCancellation(completion: @escaping @MainActor @Sendable () -> Void) {}
}
