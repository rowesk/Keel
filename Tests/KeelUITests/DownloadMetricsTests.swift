import Foundation
import XCTest
@testable import KeelUI

final class DownloadMetricsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testOpenRequiresACompletedFileWithAPath() {
        for status: KeelDownloadStatus in [.inProgress, .cancelled, .failed(message: nil), .completed] {
            let item = KeelDownloadItem(id: UUID(), hostname: "example.test", filename: "file.zip",
                                        path: "/tmp/file.zip", status: status, createdAt: start)
            XCTAssertEqual(item.canOpen, status == .completed)
        }
        let missing = KeelDownloadItem(id: UUID(), hostname: "example.test", filename: "missing.zip",
                                       status: .completed, createdAt: start)
        XCTAssertFalse(missing.canOpen)
    }

    func testARunningDownloadReportsRateAndTimeRemaining() {
        let item = makeItem(receivedBytes: 2_000_000, expectedBytes: 10_000_000, bytesPerSecond: 2_000_000)

        XCTAssertEqual(item.transferRateDescription, "2 MB/s")
        XCTAssertEqual(item.remainingTimeDescription, "4s left")
        XCTAssertEqual(item.progressMetricsDescription, "2 MB/s · 4s left")
    }

    func testAnUnknownTotalSizeGivesARateButNoEstimate() {
        let item = makeItem(receivedBytes: 2_000_000, expectedBytes: nil, bytesPerSecond: 500_000)

        XCTAssertEqual(item.transferRateDescription, "500 KB/s")
        XCTAssertNil(item.estimatedTimeRemaining)
        XCTAssertNil(item.remainingTimeDescription)
        XCTAssertEqual(item.progressMetricsDescription, "500 KB/s")
    }

    func testAStalledDownloadSaysSoInsteadOfCountingDown() {
        let item = makeItem(
            receivedBytes: 2_000_000,
            expectedBytes: 10_000_000,
            bytesPerSecond: nil,
            isStalled: true
        )

        XCTAssertEqual(item.transferRateDescription, "Stalled")
        XCTAssertNil(item.remainingTimeDescription)
        XCTAssertEqual(item.progressMetricsDescription, "Stalled")
    }

    func testAFinishedDownloadShowsNoRunningMetrics() {
        let item = KeelDownloadItem(
            id: UUID(),
            hostname: "files.example.test",
            filename: "report.pdf",
            receivedBytes: 10_000_000,
            expectedBytes: 10_000_000,
            status: .completed,
            createdAt: start,
            completedAt: start.addingTimeInterval(5),
            bytesPerSecond: 2_000_000
        )

        XCTAssertNil(item.progressMetricsDescription)
        XCTAssertNil(item.estimatedTimeRemaining)
    }

    func testASlowTrickleReportsMinutesRatherThanSecondsAndStopsPastADay() {
        let minutes = makeItem(receivedBytes: 0, expectedBytes: 600_000, bytesPerSecond: 1_000)
        XCTAssertEqual(minutes.remainingTimeDescription, "10 min left")

        let hours = makeItem(receivedBytes: 0, expectedBytes: 7_200_000, bytesPerSecond: 1_000)
        XCTAssertEqual(hours.remainingTimeDescription, "2 hr left")

        let beyondADay = makeItem(receivedBytes: 0, expectedBytes: 200_000_000, bytesPerSecond: 1_000)
        XCTAssertNil(beyondADay.remainingTimeDescription)
        XCTAssertEqual(beyondADay.progressMetricsDescription, "1 KB/s")
    }

    func testAccessibilitySummaryExplainsUnavailableAndFailedDownloads() {
        let missing = KeelDownloadItem(id: UUID(), hostname: "files.example.test", filename: "report.pdf",
                                       status: .completed, createdAt: start)
        XCTAssertTrue(missing.accessibilitySummary.contains("File unavailable"))
        let failed = KeelDownloadItem(id: UUID(), hostname: "files.example.test", filename: "report.pdf",
                                      status: .failed(message: "The connection was lost."), createdAt: start)
        XCTAssertTrue(failed.accessibilitySummary.contains("The connection was lost."))
        let unknown = makeItem(receivedBytes: 1024, expectedBytes: nil, bytesPerSecond: nil)
        XCTAssertTrue(unknown.accessibilitySummary.contains("Total size unknown"))
        XCTAssertFalse(unknown.accessibilitySummary.contains("percent"))
    }

    private func makeItem(
        receivedBytes: Int64,
        expectedBytes: Int64?,
        bytesPerSecond: Double?,
        isStalled: Bool = false
    ) -> KeelDownloadItem {
        KeelDownloadItem(
            id: UUID(),
            hostname: "files.example.test",
            filename: "report.pdf",
            receivedBytes: receivedBytes,
            expectedBytes: expectedBytes,
            status: .inProgress,
            createdAt: start,
            bytesPerSecond: bytesPerSecond,
            isStalled: isStalled
        )
    }
}
