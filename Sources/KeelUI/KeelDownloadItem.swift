import Foundation

public struct KeelDownloadItem: Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let hostname: String
    public let filename: String
    public let path: String?
    public let receivedBytes: Int64
    public let expectedBytes: Int64?
    public let status: KeelDownloadStatus
    public let createdAt: Date
    public let completedAt: Date?
    /// Smoothed transfer rate from the live snapshot. Nil when nothing is running,
    /// when too little has arrived to judge, and while the transfer is stalled.
    public let bytesPerSecond: Double?
    public let isStalled: Bool

    public init(
        id: UUID,
        hostname: String,
        filename: String,
        path: String? = nil,
        receivedBytes: Int64 = 0,
        expectedBytes: Int64? = nil,
        status: KeelDownloadStatus,
        createdAt: Date,
        completedAt: Date? = nil,
        bytesPerSecond: Double? = nil,
        isStalled: Bool = false
    ) {
        self.id = id
        self.hostname = hostname
        self.filename = filename
        self.path = path
        self.receivedBytes = max(0, receivedBytes)
        self.expectedBytes = expectedBytes.map { max(0, $0) }
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.bytesPerSecond = bytesPerSecond.map { max(0, $0) }
        self.isStalled = isStalled
    }

    public var canOpen: Bool { status == .completed && path != nil }

    public var progress: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(max(Double(receivedBytes) / Double(expectedBytes), 0), 1)
    }

    /// "2.4 MB of 18.1 MB" while running, "18.1 MB" once finished, nil when the
    /// server never said. Downloads previously showed no size at all.
    public var sizeDescription: String? {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        if status.isInProgress {
            guard let expectedBytes, expectedBytes > 0 else {
                return receivedBytes > 0 ? formatter.string(fromByteCount: receivedBytes) : nil
            }
            return "\(formatter.string(fromByteCount: receivedBytes)) of \(formatter.string(fromByteCount: expectedBytes))"
        }
        let total = expectedBytes ?? receivedBytes
        guard total > 0 else { return nil }
        return formatter.string(fromByteCount: total)
    }

    /// The line under the filename: size, when it landed, and where it came from.
    public var detailDescription: String {
        var parts: [String] = []
        if let sizeDescription { parts.append(sizeDescription) }
        parts.append(hostname)
        if let completedAt, !status.isInProgress {
            parts.append(completedAt.keelRelativeDescription())
        } else if !status.isInProgress {
            parts.append(createdAt.keelRelativeDescription())
        }
        return parts.joined(separator: " · ")
    }

    /// Seconds left at the current rate. Nil when the server never said how large the
    /// file is, when the rate is unknown, and while the transfer is stalled, because
    /// each of those would only produce a number that keeps growing.
    public var estimatedTimeRemaining: TimeInterval? {
        guard status.isInProgress, !isStalled,
              let bytesPerSecond, bytesPerSecond > 0,
              let expectedBytes, expectedBytes > receivedBytes
        else { return nil }
        return Double(expectedBytes - receivedBytes) / bytesPerSecond
    }

    /// "1.2 MB/s" while bytes are arriving, "Stalled" once they stop.
    public var transferRateDescription: String? {
        guard status.isInProgress else { return nil }
        if isStalled { return "Stalled" }
        guard let bytesPerSecond, bytesPerSecond >= 1 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    /// Stops estimating past a day. Beyond that the number says nothing useful.
    public var remainingTimeDescription: String? {
        guard let remaining = estimatedTimeRemaining, remaining < 86_400 else { return nil }
        if remaining < 60 {
            return "\(max(1, Int(remaining.rounded())))s left"
        }
        if remaining < 3_600 {
            return "\(max(1, Int((remaining / 60).rounded()))) min left"
        }
        return "\(max(1, Int((remaining / 3_600).rounded()))) hr left"
    }

    /// The ticking half of a running row: rate, then time remaining when both are known.
    public var progressMetricsDescription: String? {
        let parts = [transferRateDescription, remainingTimeDescription].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public var accessibilitySummary: String {
        var summary = "\(filename), \(hostname), \(status.label)"
        if let progress {
            summary += ", \(Int(progress * 100)) percent"
        }
        if let progressMetricsDescription {
            summary += ", \(progressMetricsDescription)"
        }
        if status.isInProgress && progress == nil {
            summary += ", Total size unknown"
        }
        if status == .completed && !canOpen {
            summary += ", File unavailable"
        }
        if case let .failed(message) = status, let message, !message.isEmpty {
            summary += ", \(message)"
        }
        return summary
    }
}
