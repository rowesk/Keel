import WebKit
import XCTest
@testable import KeelWeb

@MainActor
final class KeelWebsiteDataStoreTests: XCTestCase {
    func testEveryCallerReceivesTheSamePersistentDataStore() {
        XCTAssertTrue(KeelWebsiteDataStore.shared === KeelWebsiteDataStore.shared)
        XCTAssertTrue(KeelWebsiteDataStore.shared === WKWebsiteDataStore.default())
    }
}
