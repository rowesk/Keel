import XCTest
@testable import KeelFoundation

final class KeelIdentityTests: XCTestCase {
    func testProductionBundleIdentityIsStable() {
        XCTAssertEqual(KeelIdentity.bundleIdentifier, "com.chrisrowe.keel")
        XCTAssertEqual(KeelIdentity.displayName, "Keel")
        XCTAssertEqual(KeelIdentity.minimumMacOSVersion, "26.0")
    }
}
