import AppKit
import CryptoKit
import Foundation
import KeelFoundation

/// A palette row that can receive a favicon after the caller's stable-list delay.
@MainActor
public struct KeelFaviconRequest: Hashable {
    public let id: String
    public let pageURL: URL

    public init(id: String, pageURL: URL) {
        self.id = id
        self.pageURL = pageURL
    }
}

/// An icon replacement for one palette row. The App should crossfade only this image.
@MainActor
public struct KeelFaviconResult {
    public static let crossfadeDuration: TimeInterval = 0.14

    public let id: String
    public let image: NSImage

    public init(id: String, image: NSImage) {
        self.id = id
        self.image = image
    }
}

public struct KeelFaviconTransportResponse: Sendable {
    public let data: Data
    public let url: URL
    public let statusCode: Int
    public let mimeType: String?

    public init(data: Data, url: URL, statusCode: Int, mimeType: String? = nil) {
        self.data = data
        self.url = url
        self.statusCode = statusCode
        self.mimeType = mimeType
    }
}

@MainActor
public protocol KeelFaviconTransport: AnyObject {
    func load(_ request: URLRequest, maximumResponseBytes: Int) async throws -> KeelFaviconTransportResponse
}

@MainActor
public final class KeelFaviconURLSessionTransport: KeelFaviconTransport {
    private let session: URLSession
    private let redirectDelegate: KeelFaviconNoRedirectDelegate

    public convenience init() {
        self.init(configuration: Self.secureEphemeralConfiguration())
    }

    public init(configuration: URLSessionConfiguration) {
        let redirectDelegate = KeelFaviconNoRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        self.session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    public static func secureEphemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    public func load(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> KeelFaviconTransportResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw KeelFaviconLoaderError.invalidResponse
        }
        if response.expectedContentLength > Int64(maximumResponseBytes) {
            throw KeelFaviconLoaderError.responseTooLarge
        }

        var data = Data()
        data.reserveCapacity(min(maximumResponseBytes, Int(max(response.expectedContentLength, 0))))
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw KeelFaviconLoaderError.responseTooLarge
            }
            data.append(byte)
        }
        return KeelFaviconTransportResponse(
            data: data,
            url: response.url ?? request.url ?? URL(fileURLWithPath: "/"),
            statusCode: response.statusCode,
            mimeType: response.mimeType
        )
    }
}

private final class KeelFaviconNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public enum KeelFaviconLoaderError: Error, Equatable, Sendable {
    case invalidResponse
    case responseTooLarge
}

/// Fetches one conventional favicon per origin. The caller owns the 180 ms visible-list
/// debounce; this type owns origin privacy, cache bounds, request coalescing, and stale
/// generation suppression.
@MainActor
public final class KeelFaviconLoader {
    public static let defaultCacheCapacity = 128
    public static let maximumResponseBytes = 512 * 1024

    private let transport: any KeelFaviconTransport
    private let diskCache: KeelFaviconDiskCache?
    private let maximumResponseBytes: Int
    private var positiveCache: KeelFaviconLRUCache<NSImage>
    private var negativeCache: KeelFaviconLRUCache<Void>
    private var inFlight: [KeelFaviconOrigin: KeelFaviconInFlightRequest] = [:]
    private var activeGeneration: Int?
    private var activeLoadTask: Task<Void, Never>?

    /// The loader the App uses. It fetches over the network and keeps a bounded
    /// on-disk cache, so a relaunch no longer refetches every icon.
    public convenience init() {
        self.init(
            transport: KeelFaviconURLSessionTransport(),
            diskCache: KeelFaviconSharedDiskCache.value
        )
    }

    public init(
        transport: any KeelFaviconTransport,
        diskCache: KeelFaviconDiskCache? = nil,
        cacheCapacity: Int = KeelFaviconLoader.defaultCacheCapacity,
        maximumResponseBytes: Int = KeelFaviconLoader.maximumResponseBytes
    ) {
        precondition(cacheCapacity > 0, "Favicon cache capacity must be positive")
        precondition(maximumResponseBytes > 0, "Favicon response limit must be positive")
        self.transport = transport
        self.diskCache = diskCache
        self.maximumResponseBytes = maximumResponseBytes
        self.positiveCache = KeelFaviconLRUCache(capacity: cacheCapacity)
        self.negativeCache = KeelFaviconLRUCache(capacity: cacheCapacity)
    }

    /// Cancels the prior visible-list load. Completion runs only if this generation is
    /// still current, so the App can apply results without a second stale-result guard.
    @discardableResult
    public func load(
        for requests: [KeelFaviconRequest],
        generation: Int,
        completion: @escaping @MainActor ([KeelFaviconResult]) -> Void
    ) -> Task<Void, Never> {
        activeLoadTask?.cancel()
        cancelInFlightRequests()
        activeGeneration = generation

        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            let results = await self.results(for: requests)
            guard !Task.isCancelled, self.activeGeneration == generation else { return }
            completion(results)
        }
        activeLoadTask = task
        return task
    }

    public func cancel(generation: Int) {
        guard activeGeneration == generation else { return }
        activeGeneration = nil
        activeLoadTask?.cancel()
        activeLoadTask = nil
        cancelInFlightRequests()
    }

    public func faviconURL(for pageURL: URL) -> URL? {
        KeelFaviconOrigin(pageURL: pageURL)?.faviconURL
    }

    private func results(for requests: [KeelFaviconRequest]) async -> [KeelFaviconResult] {
        let origins = Set(requests.compactMap { KeelFaviconOrigin(pageURL: $0.pageURL) })
        var images: [KeelFaviconOrigin: NSImage] = [:]

        for origin in origins {
            guard !Task.isCancelled else { return [] }
            if let image = await image(for: origin) {
                images[origin] = image
            }
        }

        return requests.compactMap { request in
            guard let origin = KeelFaviconOrigin(pageURL: request.pageURL), let image = images[origin] else {
                return nil
            }
            return KeelFaviconResult(id: request.id, image: image)
        }
    }

    private func image(for origin: KeelFaviconOrigin) async -> NSImage? {
        if let image = positiveCache.value(for: origin) {
            return image
        }
        if negativeCache.contains(origin) {
            return nil
        }
        if let existingRequest = inFlight[origin] {
            return await existingRequest.task.value
        }

        let identifier = UUID()
        let task: Task<NSImage?, Never> = Task { @MainActor [weak self] in
            guard let self else { return nil }
            return await self.fetchImage(for: origin)
        }
        inFlight[origin] = KeelFaviconInFlightRequest(id: identifier, task: task)
        let image = await task.value
        if inFlight[origin]?.id == identifier {
            inFlight[origin] = nil
        }
        return image
    }

    private func fetchImage(for origin: KeelFaviconOrigin) async -> NSImage? {
        if let stored = await diskCache?.entry(for: origin.cacheKey) {
            guard !Task.isCancelled else { return nil }
            switch stored {
            case let .icon(data):
                if let image = NSImage(data: data), image.isValid {
                    positiveCache.insert(image, for: origin)
                    return image
                }
            case .missing:
                negativeCache.insert((), for: origin)
                return nil
            }
        }

        var request = URLRequest(url: origin.faviconURL)
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8

        do {
            let response = try await transport.load(request, maximumResponseBytes: maximumResponseBytes)
            guard !Task.isCancelled else { return nil }
            guard response.statusCode == 200,
                  response.url == origin.faviconURL,
                  response.data.count <= maximumResponseBytes,
                  let image = NSImage(data: response.data),
                  image.isValid
            else {
                negativeCache.insert((), for: origin)
                await diskCache?.store(nil, for: origin.cacheKey)
                return nil
            }

            positiveCache.insert(image, for: origin)
            await diskCache?.store(response.data, for: origin.cacheKey)
            return image
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            negativeCache.insert((), for: origin)
            await diskCache?.store(nil, for: origin.cacheKey)
            return nil
        }
    }

    private func cancelInFlightRequests() {
        let requests = inFlight.values
        inFlight.removeAll(keepingCapacity: true)
        for request in requests {
            request.task.cancel()
        }
    }
}

private struct KeelFaviconInFlightRequest {
    let id: UUID
    let task: Task<NSImage?, Never>
}

private struct KeelFaviconOrigin: Hashable {
    let scheme: String
    let host: String
    let port: Int?

    init?(pageURL: URL) {
        guard let scheme = pageURL.scheme?.lowercased(),
              let host = pageURL.host?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        self.port = pageURL.port
    }

    var cacheKey: String {
        faviconURL.absoluteString
    }

    var faviconURL: URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.path = "/favicon.ico"
        guard let url = components.url else {
            preconditionFailure("A validated favicon origin must form a URL")
        }
        return url
    }
}

private struct KeelFaviconLRUCache<Value> {
    private let capacity: Int
    private var values: [KeelFaviconOrigin: Value] = [:]
    private var recency: [KeelFaviconOrigin] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func value(for key: KeelFaviconOrigin) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    mutating func insert(_ value: Value, for key: KeelFaviconOrigin) {
        values[key] = value
        touch(key)
        while values.count > capacity, let oldest = recency.first {
            values.removeValue(forKey: oldest)
            recency.removeFirst()
        }
    }

    func contains(_ key: KeelFaviconOrigin) -> Bool {
        values[key] != nil
    }

    private mutating func touch(_ key: KeelFaviconOrigin) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

/// One disk cache per process, rooted in the Keel application support directory.
/// Two loaders with different lifetimes share it, so neither overwrites the other's index.
enum KeelFaviconSharedDiskCache {
    static let value: KeelFaviconDiskCache? = {
        guard let paths = try? KeelPathProvider.paths() else { return nil }
        return KeelFaviconDiskCache(directory: paths.faviconCacheDirectory)
    }()
}

/// A bounded favicon cache on disk. Every launch used to refetch every icon over the
/// network, including icons for sites that have never had one.
///
/// The actor keeps its index in memory and does all file work off the main actor.
/// Nothing here is authoritative: a missing, truncated, or unreadable file costs one
/// refetch, so recovery is always "fetch it again" rather than repair.
public actor KeelFaviconDiskCache {
    /// Total entries, total payload bytes, and how long each kind of answer survives.
    /// A negative answer expires sooner because a site can add a favicon at any time.
    public struct Bounds: Sendable, Equatable {
        public let maximumEntries: Int
        public let maximumBytes: Int
        public let positiveLifetime: TimeInterval
        public let negativeLifetime: TimeInterval

        public init(
            maximumEntries: Int = 256,
            maximumBytes: Int = 4 * 1024 * 1024,
            positiveLifetime: TimeInterval = 30 * 24 * 60 * 60,
            negativeLifetime: TimeInterval = 3 * 24 * 60 * 60
        ) {
            precondition(maximumEntries > 0, "Favicon disk cache must hold at least one entry")
            precondition(maximumBytes > 0, "Favicon disk cache must allow at least one byte")
            self.maximumEntries = maximumEntries
            self.maximumBytes = maximumBytes
            self.positiveLifetime = positiveLifetime
            self.negativeLifetime = negativeLifetime
        }
    }

    public enum Entry: Sendable, Equatable {
        case icon(Data)
        /// The origin was fetched and had no usable favicon.
        case missing
    }

    public struct Statistics: Sendable, Equatable {
        public let entryCount: Int
        public let byteCount: Int
    }

    private struct Record: Codable, Sendable {
        let key: String
        /// `nil` for a negative answer, which needs no payload file.
        let fileName: String?
        let byteCount: Int
        let storedAt: Date
    }

    private let directory: URL
    private let bounds: Bounds
    private let now: @Sendable () -> Date
    private var records: [String: Record]?

    public init(
        directory: URL,
        bounds: Bounds = Bounds(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directory = directory
        self.bounds = bounds
        self.now = now
    }

    public func entry(for key: String) -> Entry? {
        var records = loadedRecords()
        guard let record = records[key] else { return nil }

        let lifetime = record.fileName == nil ? bounds.negativeLifetime : bounds.positiveLifetime
        let age = now().timeIntervalSince(record.storedAt)
        guard age >= 0, age <= lifetime else {
            discard(record, from: &records)
            save(records)
            return nil
        }
        guard let fileName = record.fileName else { return .missing }
        guard let data = try? Data(contentsOf: directory.appending(path: fileName)) else {
            discard(record, from: &records)
            save(records)
            return nil
        }
        return .icon(data)
    }

    /// Records an icon, or a negative answer when `data` is nil.
    public func store(_ data: Data?, for key: String) {
        var records = loadedRecords()
        if let existing = records[key] { discard(existing, from: &records) }

        if let data {
            // An icon larger than the whole budget would evict everything else on write.
            guard data.count <= bounds.maximumBytes else { return }
            let fileName = Self.fileName(for: key)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appending(path: fileName), options: .atomic)
            } catch {
                return
            }
            records[key] = Record(key: key, fileName: fileName, byteCount: data.count, storedAt: now())
        } else {
            records[key] = Record(key: key, fileName: nil, byteCount: 0, storedAt: now())
        }

        evictUntilWithinBounds(&records)
        save(records)
    }

    public func statistics() -> Statistics {
        let records = loadedRecords()
        return Statistics(
            entryCount: records.count,
            byteCount: records.values.reduce(0) { $0 + $1.byteCount }
        )
    }

    private func evictUntilWithinBounds(_ records: inout [String: Record]) {
        var byOldest = records.values.sorted { $0.storedAt < $1.storedAt }
        var byteCount = byOldest.reduce(0) { $0 + $1.byteCount }
        while byOldest.count > bounds.maximumEntries || byteCount > bounds.maximumBytes {
            let oldest = byOldest.removeFirst()
            byteCount -= oldest.byteCount
            discard(oldest, from: &records)
        }
    }

    private func discard(_ record: Record, from records: inout [String: Record]) {
        if let fileName = record.fileName {
            try? FileManager.default.removeItem(at: directory.appending(path: fileName))
        }
        records[record.key] = nil
    }

    private func loadedRecords() -> [String: Record] {
        if let records { return records }
        let decoded = (try? Data(contentsOf: indexURL))
            .flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
        let records = Dictionary(decoded.map { ($0.key, $0) }, uniquingKeysWith: { _, newer in newer })
        self.records = records
        return records
    }

    private func save(_ records: [String: Record]) {
        self.records = records
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoded = try JSONEncoder().encode(Array(records.values))
            try encoded.write(to: indexURL, options: .atomic)
        } catch {
            // The index is rebuilt from an empty cache on the next launch.
        }
    }

    private var indexURL: URL {
        directory.appending(path: "index.json")
    }

    /// Hashed so an origin never becomes a path component.
    private static func fileName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".icon"
    }
}
