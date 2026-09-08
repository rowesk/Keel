import AppKit
import Foundation
import XCTest
@testable import KeelWeb

final class KeelFaviconDiskCacheTests: XCTestCase {
    func testOldestEntryLeavesWhenTheEntryCountBoundIsPassed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let cache = KeelFaviconDiskCache(
            directory: directory,
            bounds: .init(maximumEntries: 2, maximumBytes: 1024),
            now: { clock.now }
        )

        await cache.store(Data([1, 2, 3]), for: "https://one.example/favicon.ico")
        clock.advance(1)
        await cache.store(Data([1, 2, 3]), for: "https://two.example/favicon.ico")
        clock.advance(1)
        await cache.store(Data([1, 2, 3]), for: "https://three.example/favicon.ico")

        let statistics = await cache.statistics()
        XCTAssertEqual(statistics.entryCount, 2)
        let oldest = await cache.entry(for: "https://one.example/favicon.ico")
        XCTAssertNil(oldest)
        let newest = await cache.entry(for: "https://three.example/favicon.ico")
        XCTAssertEqual(newest, .icon(Data([1, 2, 3])))
        XCTAssertEqual(payloadFileCount(in: directory), 2)
    }

    func testOldestEntryLeavesWhenTheByteBoundIsPassed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let cache = KeelFaviconDiskCache(
            directory: directory,
            bounds: .init(maximumEntries: 100, maximumBytes: 20),
            now: { clock.now }
        )

        for host in ["one", "two", "three"] {
            await cache.store(Data(repeating: 7, count: 8), for: "https://\(host).example/favicon.ico")
            clock.advance(1)
        }

        let statistics = await cache.statistics()
        XCTAssertEqual(statistics.entryCount, 2)
        XCTAssertEqual(statistics.byteCount, 16)
        let oldest = await cache.entry(for: "https://one.example/favicon.ico")
        XCTAssertNil(oldest)
        XCTAssertEqual(payloadFileCount(in: directory), 2)
    }

    func testAnIconLargerThanTheWholeBudgetIsNotStored() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = KeelFaviconDiskCache(directory: directory, bounds: .init(maximumEntries: 4, maximumBytes: 16))

        await cache.store(Data(repeating: 9, count: 32), for: "https://huge.example/favicon.ico")

        let statistics = await cache.statistics()
        XCTAssertEqual(statistics.entryCount, 0)
        XCTAssertEqual(payloadFileCount(in: directory), 0)
    }

    func testNegativeAnswersExpireBeforeIcons() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let cache = KeelFaviconDiskCache(
            directory: directory,
            bounds: .init(maximumEntries: 8, maximumBytes: 1024, positiveLifetime: 100, negativeLifetime: 10),
            now: { clock.now }
        )

        await cache.store(Data([4]), for: "https://has-icon.example/favicon.ico")
        await cache.store(nil, for: "https://no-icon.example/favicon.ico")
        let freshNegative = await cache.entry(for: "https://no-icon.example/favicon.ico")
        XCTAssertEqual(freshNegative, .missing)

        clock.advance(20)

        let expiredNegative = await cache.entry(for: "https://no-icon.example/favicon.ico")
        XCTAssertNil(expiredNegative)
        let icon = await cache.entry(for: "https://has-icon.example/favicon.ico")
        XCTAssertEqual(icon, .icon(Data([4])))
    }

    @MainActor
    func testASecondLoaderReadsTheIconFromDiskWithoutRefetching() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = KeelFaviconDiskCache(directory: directory)
        let iconData = try pngData()

        let firstTransport = RecordingTransport(responses: [
            KeelFaviconTransportResponse(
                data: iconData,
                url: try XCTUnwrap(URL(string: "https://example.com/favicon.ico")),
                statusCode: 200,
                mimeType: "image/png"
            ),
        ])
        let first = KeelFaviconLoader(transport: firstTransport, diskCache: cache)
        let firstResults = await results(from: first, pageURL: try XCTUnwrap(URL(string: "https://example.com/a")))
        XCTAssertEqual(firstResults.map(\.id), ["row"])
        XCTAssertEqual(firstTransport.requestCount, 1)

        // A second loader stands in for the next launch: the memory cache is gone.
        let secondTransport = RecordingTransport(responses: [])
        let second = KeelFaviconLoader(transport: secondTransport, diskCache: cache)
        let secondResults = await results(from: second, pageURL: try XCTUnwrap(URL(string: "https://example.com/b")))
        XCTAssertEqual(secondResults.map(\.id), ["row"])
        XCTAssertEqual(secondTransport.requestCount, 0)
    }

    @MainActor
    func testASecondLoaderTrustsTheStoredNegativeAnswer() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = KeelFaviconDiskCache(directory: directory)

        let firstTransport = RecordingTransport(responses: [
            KeelFaviconTransportResponse(
                data: Data([0]),
                url: try XCTUnwrap(URL(string: "https://blank.example/favicon.ico")),
                statusCode: 404
            ),
        ])
        let first = KeelFaviconLoader(transport: firstTransport, diskCache: cache)
        let firstResults = await results(from: first, pageURL: try XCTUnwrap(URL(string: "https://blank.example/a")))
        XCTAssertTrue(firstResults.isEmpty)
        XCTAssertEqual(firstTransport.requestCount, 1)

        let secondTransport = RecordingTransport(responses: [])
        let second = KeelFaviconLoader(transport: secondTransport, diskCache: cache)
        let secondResults = await results(from: second, pageURL: try XCTUnwrap(URL(string: "https://blank.example/b")))
        XCTAssertTrue(secondResults.isEmpty)
        XCTAssertEqual(secondTransport.requestCount, 0)
    }

    @MainActor
    private func results(from loader: KeelFaviconLoader, pageURL: URL) async -> [KeelFaviconResult] {
        await withCheckedContinuation { continuation in
            loader.load(for: [KeelFaviconRequest(id: "row", pageURL: pageURL)], generation: 1) { results in
                continuation.resume(returning: results)
            }
        }
    }

    private func payloadFileCount(in directory: URL) -> Int {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.filter { $0.hasSuffix(".icon") }.count
    }

    private func pngData() throws -> Data {
        try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLq2QAAAABJRU5ErkJggg=="))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "KeelFaviconDiskCacheTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        date += interval
    }
}

@MainActor
private final class RecordingTransport: KeelFaviconTransport {
    private var responses: [KeelFaviconTransportResponse]
    private(set) var requestCount = 0

    init(responses: [KeelFaviconTransportResponse]) {
        self.responses = responses
    }

    func load(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> KeelFaviconTransportResponse {
        requestCount += 1
        guard !responses.isEmpty else { throw KeelFaviconLoaderError.invalidResponse }
        return responses.removeFirst()
    }
}
