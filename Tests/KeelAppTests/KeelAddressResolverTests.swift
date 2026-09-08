import XCTest
@testable import KeelApp
import KeelStore

final class KeelAddressResolverTests: XCTestCase {
    func testBareHostnameUsesHTTPSNavigation() {
        let result = KeelAddressResolver.resolve(
            "example-store.myshopify.test/admin",
            searchProvider: .google
        )

        XCTAssertEqual(
            result,
            .navigation(URL(string: "https://example-store.myshopify.test/admin")!)
        )
    }

    func testExplicitNonHTTPSURLIsNotChangedIntoSearch() {
        let result = KeelAddressResolver.resolve(
            "http://localhost:3000/products",
            searchProvider: .google
        )

        XCTAssertEqual(result, .navigation(URL(string: "http://localhost:3000/products")!))
    }

    func testExplicitCustomSchemeRemainsANavigationRequest() {
        let result = KeelAddressResolver.resolve(
            "rtsp://camera.example/live",
            searchProvider: .google
        )

        XCTAssertEqual(result, .navigation(URL(string: "rtsp://camera.example/live")!))
    }

    func testSchemeWithoutAuthorityRemainsANavigationRequest() {
        let result = KeelAddressResolver.resolve(
            "mailto:hello@example.com",
            searchProvider: .google
        )

        XCTAssertEqual(result, .navigation(URL(string: "mailto:hello@example.com")!))
    }

    func testMagnetSchemeRemainsANavigationRequest() {
        let result = KeelAddressResolver.resolve(
            "magnet:?xt=urn:btih:1234",
            searchProvider: .google
        )

        XCTAssertEqual(result, .navigation(URL(string: "magnet:?xt=urn:btih:1234")!))
    }

    func testLocalhostPortUsesHTTPSNavigation() {
        let result = KeelAddressResolver.resolve("localhost:3000/dashboard", searchProvider: .google)

        XCTAssertEqual(result, .navigation(URL(string: "https://localhost:3000/dashboard")!))
    }

    func testHostnamePortUsesHTTPSNavigation() {
        let result = KeelAddressResolver.resolve("preview.example:8080/dashboard", searchProvider: .google)

        XCTAssertEqual(result, .navigation(URL(string: "https://preview.example:8080/dashboard")!))
    }

    func testHostnamePathUsesHTTPSNavigation() {
        let result = KeelAddressResolver.resolve("example.co.uk/account", searchProvider: .google)

        XCTAssertEqual(result, .navigation(URL(string: "https://example.co.uk/account")!))
    }

    func testSearchUsesConfiguredProvider() {
        let result = KeelAddressResolver.resolve("Keel browser", searchProvider: .duckDuckGo)

        XCTAssertEqual(
            result,
            .search(URL(string: "https://duckduckgo.com/?q=Keel%20browser")!)
        )
    }
    func testCustomQueryPreservesReservedCharactersAndUnicode() throws {
        let query = "salt & pepper + 50% café # 東京"
        let result = KeelAddressResolver.resolve(query, searchProvider: .custom(template: "https://example.test/search?q={query}&fixed=yes"))
        guard case let .search(url) = result else { return XCTFail("Expected custom search") }
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "q", value: query), URLQueryItem(name: "fixed", value: "yes")])
        XCTAssertNil(components.fragment)
        XCTAssertTrue(url.absoluteString.contains("%2B"))
    }

    func testCustomSearchSupportsPathDataPositions() throws {
        let query = "a / b + café"
        for template in ["https://example.test/find/{query}"] {
            guard case let .search(url) = KeelAddressResolver.resolve(query, searchProvider: .custom(template: template)) else {
                return XCTFail("Expected custom search")
            }
            XCTAssertTrue(url.absoluteString.contains("a%20%2F%20b%20%2B%20caf%C3%A9"))
        }
    }

    func testCustomSearchRejectsAuthorityAndSchemePlaceholders() {
        for template in ["https://{query}.example.test/", "{query}://example.test/", "https://{query}@example.test/", "https://example.test/no-placeholder", "https://example.test/#query={query}", "https://example.test/?q={query}#fixed"] {
            XCTAssertNil(KeelAddressResolver.resolve("some search", searchProvider: .custom(template: template)))
        }
    }
}
