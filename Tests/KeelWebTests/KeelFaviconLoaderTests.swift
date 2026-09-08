import AppKit
import Foundation
import XCTest
@testable import KeelWeb

@MainActor
final class KeelFaviconLoaderTests: XCTestCase {
    func testRequestsOnlyOriginFaviconWithoutCookies() async throws {
        let transport = FaviconTransport()
        transport.responses = [try validResponse(for: "https://example.com/favicon.ico")]
        let loader = KeelFaviconLoader(transport: transport)

        let completion = expectation(description: "favicon completion")
        loader.load(
            for: [KeelFaviconRequest(id: "row", pageURL: try url("https://example.com/private/path?q=secret#fragment"))],
            generation: 1
        ) { results in
            XCTAssertEqual(results.map(\.id), ["row"])
            completion.fulfill()
        }
        await fulfillment(of: [completion], timeout: 1)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url, try url("https://example.com/favicon.ico"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testSecureEphemeralConfigurationDoesNotPersistCookiesOrUseURLCache() {
        let configuration = KeelFaviconURLSessionTransport.secureEphemeralConfiguration()

        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testDuplicateOriginsCoalesceIntoOneRequest() async throws {
        let transport = FaviconTransport()
        transport.responses = [try validResponse(for: "https://example.com/favicon.ico")]
        let loader = KeelFaviconLoader(transport: transport)
        let completion = expectation(description: "favicon completion")

        loader.load(
            for: [
                KeelFaviconRequest(id: "one", pageURL: try url("https://example.com/a")),
                KeelFaviconRequest(id: "two", pageURL: try url("https://example.com/b")),
            ],
            generation: 1
        ) { results in
            XCTAssertEqual(Set(results.map(\.id)), Set(["one", "two"]))
            completion.fulfill()
        }
        await fulfillment(of: [completion], timeout: 1)

        XCTAssertEqual(transport.requests.count, 1)
    }

    func testRejectsOversizedAndRedirectedResponsesIntoNegativeCache() async throws {
        let transport = FaviconTransport()
        let origin = try url("https://example.com/favicon.ico")
        transport.responses = [
            KeelFaviconTransportResponse(data: Data(repeating: 0, count: 33), url: origin, statusCode: 200),
            KeelFaviconTransportResponse(data: try pngData(), url: try url("https://elsewhere.example/favicon.ico"), statusCode: 200),
        ]
        let loader = KeelFaviconLoader(transport: transport, maximumResponseBytes: 32)

        let oversized = await results(from: loader, request: KeelFaviconRequest(id: "oversized", pageURL: try url("https://example.com/a")), generation: 1)
        XCTAssertTrue(oversized.isEmpty)
        let sameOriginAgain = await results(from: loader, request: KeelFaviconRequest(id: "cached", pageURL: try url("https://example.com/b")), generation: 2)
        XCTAssertTrue(sameOriginAgain.isEmpty)
        XCTAssertEqual(transport.requests.count, 1)

        let redirect = await results(from: loader, request: KeelFaviconRequest(id: "redirect", pageURL: try url("https://redirect.example/a")), generation: 3)
        XCTAssertTrue(redirect.isEmpty)
    }

    func testPositiveAndNegativeCachesEvictLeastRecentlyUsedOrigin() async throws {
        let transport = FaviconTransport()
        transport.responses = [
            try validResponse(for: "https://one.example/favicon.ico"),
            try validResponse(for: "https://two.example/favicon.ico"),
            try validResponse(for: "https://one.example/favicon.ico"),
            KeelFaviconTransportResponse(data: Data([0]), url: try url("https://bad-one.example/favicon.ico"), statusCode: 200),
            KeelFaviconTransportResponse(data: Data([0]), url: try url("https://bad-two.example/favicon.ico"), statusCode: 200),
            KeelFaviconTransportResponse(data: Data([0]), url: try url("https://bad-one.example/favicon.ico"), statusCode: 200),
        ]
        let loader = KeelFaviconLoader(transport: transport, cacheCapacity: 1)

        _ = await results(from: loader, request: KeelFaviconRequest(id: "one", pageURL: try url("https://one.example/a")), generation: 1)
        _ = await results(from: loader, request: KeelFaviconRequest(id: "two", pageURL: try url("https://two.example/a")), generation: 2)
        _ = await results(from: loader, request: KeelFaviconRequest(id: "one", pageURL: try url("https://one.example/b")), generation: 3)
        _ = await results(from: loader, request: KeelFaviconRequest(id: "bad-one", pageURL: try url("https://bad-one.example/a")), generation: 4)
        _ = await results(from: loader, request: KeelFaviconRequest(id: "bad-two", pageURL: try url("https://bad-two.example/a")), generation: 5)
        _ = await results(from: loader, request: KeelFaviconRequest(id: "bad-one", pageURL: try url("https://bad-one.example/b")), generation: 6)

        XCTAssertEqual(transport.requests.count, 6)
    }

    func testCancellationDoesNotUpdateThePalette() async throws {
        let transport = DeferredFaviconTransport()
        let loader = KeelFaviconLoader(transport: transport)
        let inverted = expectation(description: "cancelled work must not update")
        inverted.isInverted = true

        loader.load(
            for: [KeelFaviconRequest(id: "row", pageURL: try url("https://example.com/a"))],
            generation: 1
        ) { _ in
            inverted.fulfill()
        }
        await transport.waitForRequest()
        loader.cancel(generation: 1)
        transport.resolveNext(with: try validResponse(for: "https://example.com/favicon.ico"))

        await fulfillment(of: [inverted], timeout: 0.1)
    }

    func testSupersededGenerationCannotUpdateNewPaletteRows() async throws {
        let transport = DeferredFaviconTransport()
        let loader = KeelFaviconLoader(transport: transport)
        let stale = expectation(description: "stale generation must not update")
        stale.isInverted = true
        let current = expectation(description: "current generation updates")

        loader.load(
            for: [KeelFaviconRequest(id: "stale", pageURL: try url("https://stale.example/a"))],
            generation: 1
        ) { _ in
            stale.fulfill()
        }
        await transport.waitForRequest()
        loader.load(
            for: [KeelFaviconRequest(id: "current", pageURL: try url("https://current.example/a"))],
            generation: 2
        ) { results in
            XCTAssertEqual(results.map(\.id), ["current"])
            current.fulfill()
        }
        await transport.waitForRequest()
        transport.resolveNext(with: try validResponse(for: "https://stale.example/favicon.ico"))
        transport.resolveNext(with: try validResponse(for: "https://current.example/favicon.ico"))

        await fulfillment(of: [current, stale], timeout: 1)
    }

    private func results(
        from loader: KeelFaviconLoader,
        request: KeelFaviconRequest,
        generation: Int
    ) async -> [KeelFaviconResult] {
        await withCheckedContinuation { continuation in
            loader.load(for: [request], generation: generation) { results in
                continuation.resume(returning: results)
            }
        }
    }

    private func validResponse(for value: String) throws -> KeelFaviconTransportResponse {
        KeelFaviconTransportResponse(data: try pngData(), url: try url(value), statusCode: 200, mimeType: "image/png")
    }

    private func pngData() throws -> Data {
        try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLq2QAAAABJRU5ErkJggg=="))
    }

    private func url(_ value: String) throws -> URL {
        try XCTUnwrap(URL(string: value))
    }
}

@MainActor
private final class FaviconTransport: KeelFaviconTransport {
    var requests: [URLRequest] = []
    var responses: [KeelFaviconTransportResponse] = []

    func load(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> KeelFaviconTransportResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw KeelFaviconLoaderError.invalidResponse
        }
        return responses.removeFirst()
    }
}

@MainActor
private final class DeferredFaviconTransport: KeelFaviconTransport {
    private var requests: [URLRequest] = []
    private var continuations: [CheckedContinuation<KeelFaviconTransportResponse, Error>] = []

    func load(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> KeelFaviconTransportResponse {
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForRequest() async {
        while requests.isEmpty {
            await Task.yield()
        }
        requests.removeFirst()
    }

    func resolveNext(with response: KeelFaviconTransportResponse) {
        guard !continuations.isEmpty else {
            XCTFail("Expected a pending favicon request")
            return
        }
        continuations.removeFirst().resume(returning: response)
    }
}
