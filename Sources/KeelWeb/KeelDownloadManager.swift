import Foundation
import WebKit

public enum KeelDownloadState: Equatable, Sendable {
    case inProgress
    case completed
    case cancelled
    case failed(errorCode: Int?)

    public var isTerminal: Bool {
        self != .inProgress
    }
}

public struct KeelDownloadSnapshot: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sourceHostname: String
    public let filename: String
    public let destinationURL: URL?
    public let receivedBytes: Int64
    public let expectedBytes: Int64?
    public let state: KeelDownloadState
    public let createdAt: Date
    public let completedAt: Date?
    /// Smoothed over recent callbacks, not averaged over the whole transfer. Nil
    /// while the rate is still unknown and while the transfer is stalled.
    public let bytesPerSecond: Double?
    /// The transfer has not moved a byte for long enough to say so out loud.
    public let isStalled: Bool

    public init(
        id: UUID,
        sourceHostname: String,
        filename: String,
        destinationURL: URL? = nil,
        receivedBytes: Int64 = 0,
        expectedBytes: Int64? = nil,
        state: KeelDownloadState,
        createdAt: Date,
        completedAt: Date? = nil,
        bytesPerSecond: Double? = nil,
        isStalled: Bool = false
    ) {
        self.id = id
        self.sourceHostname = sourceHostname
        self.filename = filename
        self.destinationURL = destinationURL
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
        self.state = state
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.bytesPerSecond = bytesPerSecond
        self.isStalled = isStalled
    }
}

/// Turns a sequence of progress callbacks into a transfer rate. It keeps a short
/// trailing window because a total-bytes-over-total-elapsed average keeps quoting a
/// speed the transfer stopped running at minutes ago, and it never admits a stall.
public struct KeelDownloadRateEstimator: Equatable, Sendable {
    public struct Estimate: Equatable, Sendable {
        public let bytesPerSecond: Double?
        public let isStalled: Bool

        public static let unknown = Estimate(bytesPerSecond: nil, isStalled: false)

        public init(bytesPerSecond: Double?, isStalled: Bool) {
            self.bytesPerSecond = bytesPerSecond
            self.isStalled = isStalled
        }
    }

    private struct Sample: Equatable {
        let date: Date
        let receivedBytes: Int64
    }

    private let window: TimeInterval
    private let stallThreshold: TimeInterval
    private var samples: [Sample] = []

    public init(window: TimeInterval = 5, stallThreshold: TimeInterval = 3) {
        self.window = window
        self.stallThreshold = stallThreshold
    }

    /// Records movement only. A callback that carries the same byte count leaves the
    /// window alone, so the newest sample always dates the last real progress.
    public mutating func record(receivedBytes: Int64, at date: Date) {
        if let last = samples.last {
            if receivedBytes < last.receivedBytes {
                samples.removeAll(keepingCapacity: true)
            } else if receivedBytes == last.receivedBytes || date <= last.date {
                return
            }
        }
        samples.append(Sample(date: date, receivedBytes: receivedBytes))
        let cutoff = date.addingTimeInterval(-window)
        // Keeps one sample older than the cutoff so the window always spans an interval.
        while samples.count > 2, samples[1].date <= cutoff {
            samples.removeFirst()
        }
    }

    public func estimate(at date: Date) -> Estimate {
        guard let newest = samples.last else { return .unknown }
        if date.timeIntervalSince(newest.date) >= stallThreshold {
            return Estimate(bytesPerSecond: nil, isStalled: true)
        }
        guard let oldest = samples.first, samples.count >= 2 else { return .unknown }
        let interval = newest.date.timeIntervalSince(oldest.date)
        let moved = Double(newest.receivedBytes - oldest.receivedBytes)
        guard interval > 0, moved > 0 else { return .unknown }
        return Estimate(bytesPerSecond: moved / interval, isStalled: false)
    }
}

public enum KeelDownloadLifecycleEvent: Equatable, Sendable {
    case started(KeelDownloadSnapshot)
    /// Coalesced snapshots published at a bounded cadence while downloads are active.
    case progress([KeelDownloadSnapshot])
    case updated(KeelDownloadSnapshot)
    case finished(KeelDownloadSnapshot)

    public var snapshots: [KeelDownloadSnapshot] {
        switch self {
        case let .started(snapshot), let .updated(snapshot), let .finished(snapshot): [snapshot]
        case let .progress(snapshots): snapshots
        }
    }
}

public typealias KeelDownloadLifecycleSink = @MainActor (KeelDownloadLifecycleEvent) -> Void

@MainActor
protocol KeelDownloadCancellationRequesting: AnyObject {
    func requestCancellation(completion: @escaping @MainActor @Sendable () -> Void)
}

@MainActor
private final class KeelWebKitDownloadCancellationRequestor: KeelDownloadCancellationRequesting {
    private let download: WKDownload

    init(download: WKDownload) {
        self.download = download
    }

    func requestCancellation(completion: @escaping @MainActor @Sendable () -> Void) {
        download.cancel { _ in completion() }
    }
}

/// Decides when noisy transfer progress can refresh the shelf. It deliberately owns
/// no WebKit objects or timers, so timing behaviour stays deterministic in tests.
struct KeelDownloadProgressBatcher {
    enum Disposition: Equatable {
        case publishNow
        case deferUntil(Date)
    }

    private let minimumInterval: TimeInterval
    private var lastPublishedAt: Date?
    private var pendingIdentifiers: Set<UUID> = []

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    mutating func receive(identifier: UUID, at date: Date) -> Disposition {
        pendingIdentifiers.insert(identifier)
        guard let lastPublishedAt else { return .publishNow }
        let deadline = lastPublishedAt.addingTimeInterval(minimumInterval)
        return date >= deadline ? .publishNow : .deferUntil(deadline)
    }

    mutating func takePending(at date: Date) -> [UUID] {
        lastPublishedAt = date
        defer { pendingIdentifiers.removeAll(keepingCapacity: true) }
        return pendingIdentifiers.sorted { $0.uuidString < $1.uuidString }
    }

    mutating func remove(identifier: UUID) {
        pendingIdentifiers.remove(identifier)
    }
}

private struct KeelDownloadCancellationGroupWaiter {
    var remainingIdentifiers: Set<UUID>
    let continuation: CheckedContinuation<Void, Never>
}

@MainActor
public final class KeelDownloadManager: NSObject, WKDownloadDelegate {
    public let destinationDirectory: URL

    private let fileManager: FileManager
    private let now: () -> Date
    private let lifecycleSink: KeelDownloadLifecycleSink?
    private var records: [UUID: KeelDownloadSnapshot] = [:]
    private var downloads: [UUID: WKDownload] = [:]
    private var cancellationRequestors: [UUID: any KeelDownloadCancellationRequesting] = [:]
    private var identifiersByDownload: [ObjectIdentifier: UUID] = [:]
    private var progressObservations: [UUID: NSKeyValueObservation] = [:]
    private var reservedDestinations: Set<URL> = []
    private var cancelledIdentifiers: Set<UUID> = []
    private var progressBatcher = KeelDownloadProgressBatcher(minimumInterval: 0.1)
    private var rateEstimators: [UUID: KeelDownloadRateEstimator] = [:]
    private var progressPublicationTask: Task<Void, Never>?
    private var stallWatchdogTask: Task<Void, Never>?
    private var terminalWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var cancellationGroupWaiters: [UUID: KeelDownloadCancellationGroupWaiter] = [:]

    public init(
        destinationDirectory: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        lifecycleSink: KeelDownloadLifecycleSink? = nil
    ) {
        self.destinationDirectory = destinationDirectory
        self.fileManager = fileManager
        self.now = now
        self.lifecycleSink = lifecycleSink
    }

    public static func defaultDestinationDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
    }
    @discardableResult
    public func register(download: WKDownload, sourceURL: URL? = nil) -> UUID {
        let identifier = UUID()
        let sourceURL = sourceURL ?? download.originalRequest?.url
        let fallbackName = sourceURL?.lastPathComponent ?? "download"
        let snapshot = KeelDownloadSnapshot(
            id: identifier,
            sourceHostname: sourceURL?.host ?? "unknown",
            filename: KeelDownloadNaming.filename(
                suggestedFilename: fallbackName,
                mimeType: nil
            ),
            state: .inProgress,
            createdAt: now()
        )

        records[identifier] = snapshot
        downloads[identifier] = download
        cancellationRequestors[identifier] = KeelWebKitDownloadCancellationRequestor(download: download)
        identifiersByDownload[ObjectIdentifier(download)] = identifier
        download.delegate = self
        progressObservations[identifier] = download.progress.observe(
            \.completedUnitCount,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshProgress(for: identifier)
            }
        }
        publish(.started(snapshot))
        return identifier
    }

    public var snapshots: [KeelDownloadSnapshot] {
        refreshProgress()
        return records.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString > $1.id.uuidString
        }
    }

    public func snapshot(id: UUID) -> KeelDownloadSnapshot? {
        refreshProgress()
        return records[id]
    }

    public func refreshProgress() {
        for identifier in downloads.keys { refreshProgress(for: identifier) }
    }

    public func cancel(id: UUID) {
        requestCancellation(id)
    }

    /// Waits for WebKit's cancellation completion or terminal delegate callback. It
    /// does not report completion when cancellation was merely requested.
    public func cancelAndWait(id: UUID) async {
        guard let record = records[id],
              !record.state.isTerminal,
              cancellationRequestors[id] != nil
        else { return }
        await withCheckedContinuation { continuation in
            terminalWaiters[id, default: []].append(continuation)
            requestCancellation(id)
        }
    }

    /// Starts cancellation for every active transfer, then completes only after each
    /// transfer has published its terminal event.
    public func cancelAllAndWait() async {
        let activeIdentifiers = records.values
            .filter { !$0.state.isTerminal }
            .map(\.id)
        guard !activeIdentifiers.isEmpty else { return }
        await withCheckedContinuation { continuation in
            let groupID = UUID()
            cancellationGroupWaiters[groupID] = KeelDownloadCancellationGroupWaiter(
                remainingIdentifiers: Set(activeIdentifiers),
                continuation: continuation
            )
            for identifier in activeIdentifiers {
                requestCancellation(identifier)
            }
        }
    }

    /// Test-only registration seam. Production transfers enter through `register`.
    @discardableResult
    func registerForTesting(
        snapshot: KeelDownloadSnapshot,
        cancellationRequestor: any KeelDownloadCancellationRequesting
    ) -> UUID {
        records[snapshot.id] = snapshot
        cancellationRequestors[snapshot.id] = cancellationRequestor
        publish(.started(snapshot))
        return snapshot.id
    }

    /// Test-only progress seam. Production progress arrives through KVO on `WKDownload`.
    func receiveProgressForTesting(id: UUID, receivedBytes: Int64, expectedBytes: Int64? = nil) {
        guard let record = records[id] else { return }
        applyProgress(
            identifier: id,
            receivedBytes: receivedBytes,
            expectedBytes: expectedBytes ?? record.expectedBytes
        )
    }

    /// Test-only delegate seam for proving cancellation and failure races.
    func receiveTerminalStateForTesting(id: UUID, state: KeelDownloadState) {
        finish(identifier: id, state: state)
    }

    /// Test-only delegate seam which preserves the production cancellation mapping.
    func receiveFailureForTesting(id: UUID, errorCode: Int?) {
        let state: KeelDownloadState = cancelledIdentifiers.contains(id)
            ? .cancelled
            : .failed(errorCode: errorCode)
        finish(identifier: id, state: state)
    }

    private func requestCancellation(_ identifier: UUID) {
        guard let record = records[identifier],
              !record.state.isTerminal,
              let requestor = cancellationRequestors[identifier]
        else { return }
        guard cancelledIdentifiers.insert(identifier).inserted else { return }
        requestor.requestCancellation { [weak self] in
            Task { @MainActor [weak self] in
                self?.finish(identifier: identifier, state: .cancelled)
            }
        }
    }

    public func dismissTerminal(id: UUID) {
        guard let record = records[id], record.state.isTerminal else { return }
        records[id] = nil
    }

    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        guard let identifier = identifiersByDownload[ObjectIdentifier(download)], let record = records[identifier] else {
            return nil
        }

        do {
            let filename = KeelDownloadNaming.filename(
                suggestedFilename: suggestedFilename,
                responseSuggestedFilename: response.suggestedFilename,
                responseURL: response.url,
                mimeType: response.mimeType,
                fallbackName: record.filename
            )
            let destination = try reserveDestination(named: filename)
            let expectedBytes = response.expectedContentLength > 0 ? response.expectedContentLength : record.expectedBytes
            let updated = KeelDownloadSnapshot(
                id: record.id,
                sourceHostname: record.sourceHostname,
                filename: filename,
                destinationURL: destination,
                receivedBytes: record.receivedBytes,
                expectedBytes: expectedBytes,
                state: record.state,
                createdAt: record.createdAt,
                completedAt: record.completedAt,
                bytesPerSecond: record.bytesPerSecond,
                isStalled: record.isStalled
            )
            records[identifier] = updated
            publish(.updated(updated))
            return destination
        } catch {
            finish(identifier: identifier, state: .failed(errorCode: (error as NSError).code))
            return nil
        }
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let identifier = identifiersByDownload[ObjectIdentifier(download)] else { return }
        refreshProgress()
        finish(identifier: identifier, state: .completed)
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let identifier = identifiersByDownload[ObjectIdentifier(download)] else { return }
        refreshProgress()
        let state: KeelDownloadState = cancelledIdentifiers.contains(identifier)
            ? .cancelled
            : .failed(errorCode: (error as NSError).code)
        finish(identifier: identifier, state: state)
    }

    private func reserveDestination(named filename: String) throws -> URL {
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let fileExtension = (filename as NSString).pathExtension
        let baseName = (filename as NSString).deletingPathExtension
        var index = 1
        while true {
            let suffix = index == 1 ? "" : " (\(index))"
            let candidateName = fileExtension.isEmpty
                ? baseName + suffix
                : baseName + suffix + "." + fileExtension
            let candidate = destinationDirectory.appending(path: candidateName, directoryHint: .notDirectory)
            // FileManager needs a filesystem path. URL.path() escapes spaces in
            // suffixes such as " (2)", hiding existing files from this check.
            if !reservedDestinations.contains(candidate), !fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
                reservedDestinations.insert(candidate)
                return candidate
            }
            index += 1
        }
    }

    private func refreshProgress(for identifier: UUID) {
        guard let download = downloads[identifier], let record = records[identifier], !record.state.isTerminal else { return }
        let progress = download.progress
        applyProgress(
            identifier: identifier,
            receivedBytes: max(0, progress.completedUnitCount),
            expectedBytes: progress.totalUnitCount > 0 ? progress.totalUnitCount : record.expectedBytes
        )
    }

    private func applyProgress(identifier: UUID, receivedBytes: Int64, expectedBytes: Int64?) {
        guard let record = records[identifier], !record.state.isTerminal else { return }
        let date = now()
        var estimator = rateEstimators[identifier] ?? KeelDownloadRateEstimator()
        estimator.record(receivedBytes: receivedBytes, at: date)
        rateEstimators[identifier] = estimator
        let estimate = estimator.estimate(at: date)

        let movedBytes = receivedBytes != record.receivedBytes || expectedBytes != record.expectedBytes
        let changedRate = estimate.bytesPerSecond != record.bytesPerSecond || estimate.isStalled != record.isStalled
        guard movedBytes || changedRate else { return }

        records[identifier] = KeelDownloadSnapshot(
            id: record.id,
            sourceHostname: record.sourceHostname,
            filename: record.filename,
            destinationURL: record.destinationURL,
            receivedBytes: receivedBytes,
            expectedBytes: expectedBytes,
            state: record.state,
            createdAt: record.createdAt,
            completedAt: record.completedAt,
            bytesPerSecond: estimate.bytesPerSecond,
            isStalled: estimate.isStalled
        )
        scheduleStallWatchdog()
        queueProgressPublication(for: identifier)
    }

    /// WebKit stops calling back when a transfer stops moving, so nothing else would
    /// ever revisit the last rate it reported. This re-reads the estimator on a slow
    /// beat while transfers are running and publishes only when the verdict changes.
    private func scheduleStallWatchdog() {
        guard stallWatchdogTask == nil, !downloads.isEmpty else { return }
        stallWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.stallWatchdogTask = nil
            self.refreshStalledTransfers()
        }
    }

    private func refreshStalledTransfers() {
        for identifier in downloads.keys {
            guard let record = records[identifier] else { continue }
            applyProgress(
                identifier: identifier,
                receivedBytes: record.receivedBytes,
                expectedBytes: record.expectedBytes
            )
        }
        scheduleStallWatchdog()
    }

    private func finish(identifier: UUID, state: KeelDownloadState) {
        guard let record = records[identifier], !record.state.isTerminal else { return }
        let terminal = KeelDownloadSnapshot(
            id: record.id,
            sourceHostname: record.sourceHostname,
            filename: record.filename,
            destinationURL: record.destinationURL,
            receivedBytes: record.receivedBytes,
            expectedBytes: record.expectedBytes,
            state: state,
            createdAt: record.createdAt,
            completedAt: now(),
            bytesPerSecond: nil,
            isStalled: false
        )
        records[identifier] = terminal
        progressBatcher.remove(identifier: identifier)
        rateEstimators[identifier] = nil
        downloads[identifier] = nil
        cancellationRequestors[identifier] = nil
        identifiersByDownload = identifiersByDownload.filter { $0.value != identifier }
        progressObservations[identifier] = nil
        if let destination = record.destinationURL { reservedDestinations.remove(destination) }
        cancelledIdentifiers.remove(identifier)
        publish(.finished(terminal))
        let waiters = terminalWaiters.removeValue(forKey: identifier) ?? []
        for waiter in waiters { waiter.resume() }
        resumeCancellationGroups(finishedIdentifier: identifier)
    }

    private func queueProgressPublication(for identifier: UUID) {
        switch progressBatcher.receive(identifier: identifier, at: now()) {
        case .publishNow:
            publishPendingProgress()
        case let .deferUntil(deadline):
            scheduleProgressPublication(for: deadline)
        }
    }

    private func scheduleProgressPublication(for deadline: Date) {
        guard progressPublicationTask == nil else { return }
        let delay = max(0, deadline.timeIntervalSince(now()))
        progressPublicationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.progressPublicationTask = nil
            self.publishPendingProgress()
        }
    }

    private func publishPendingProgress() {
        let identifiers = progressBatcher.takePending(at: now())
        let snapshots = identifiers.compactMap { records[$0] }
        guard !snapshots.isEmpty else { return }
        publish(.progress(snapshots))
    }

    private func resumeCancellationGroups(finishedIdentifier identifier: UUID) {
        var updatedGroups: [UUID: KeelDownloadCancellationGroupWaiter] = [:]
        var continuations: [CheckedContinuation<Void, Never>] = []
        for (groupID, waiter) in cancellationGroupWaiters {
            var updated = waiter
            updated.remainingIdentifiers.remove(identifier)
            if updated.remainingIdentifiers.isEmpty {
                continuations.append(updated.continuation)
            } else {
                updatedGroups[groupID] = updated
            }
        }
        cancellationGroupWaiters = updatedGroups
        for continuation in continuations { continuation.resume() }
    }

    private func publish(_ event: KeelDownloadLifecycleEvent) {
        lifecycleSink?(event)
    }
}
