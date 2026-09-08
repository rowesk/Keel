import Foundation
import XCTest
@testable import KeelFoundation

final class KeelPathProviderTests: XCTestCase {
    func testPathsStayInsideOneStableApplicationSupportDirectory() {
        let paths = KeelPathProvider.paths(
            applicationSupportBaseURL: URL(filePath: "/container/Library/Application Support", directoryHint: .isDirectory)
        )

        XCTAssertEqual(paths.applicationSupportDirectory.path, "/container/Library/Application Support/Keel")
        XCTAssertEqual(paths.databaseURL.path, "/container/Library/Application Support/Keel/Keel.sqlite3")
        XCTAssertEqual(paths.diagnosticsDirectory.path, "/container/Library/Application Support/Keel/Diagnostics")
        XCTAssertEqual(paths.faviconCacheDirectory.path, "/container/Library/Application Support/Keel/Favicons")
        XCTAssertEqual(paths.homeScenesDirectory.path, "/container/Library/Application Support/Keel/HomeScenes")
    }
}
