import Foundation
import XCTest
@testable import KeelWeb

/// A failed navigation used to show a blank white view with no message, no code
/// and no way to retry. These pin the words a person actually reads.
final class KeelPageFailureTests: XCTestCase {
    func testOfflineSaysSoRatherThanShowingNothing() {
        let failure = KeelPageFailure(
            host: "news.ycombinator.com",
            code: NSURLErrorNotConnectedToInternet,
            underlyingDescription: "offline"
        )
        XCTAssertEqual(failure.title, "You are offline")
        XCTAssertEqual(failure.symbolName, "wifi.slash")
        XCTAssertFalse(failure.isSecurityFailure)
        XCTAssertTrue(failure.message.contains("network connection"))
    }

    func testACertificateFailureIsNamedAsOneAndNotAsANetworkDrop() {
        let failure = KeelPageFailure(
            host: "expired.example.test",
            code: NSURLErrorServerCertificateUntrusted,
            underlyingDescription: "untrusted"
        )
        XCTAssertTrue(failure.isSecurityFailure)
        XCTAssertEqual(failure.title, "This connection is not private")
        XCTAssertEqual(failure.symbolName, "lock.trianglebadge.exclamationmark")
        // Fail closed, and say that nothing was sent.
        XCTAssertTrue(failure.message.contains("stopped before sending"))
    }

    func testAMissingHostNamesTheHostWithoutItsWwwPrefix() {
        let failure = KeelPageFailure(
            host: "www.example.com",
            code: NSURLErrorCannotFindHost,
            underlyingDescription: "dns"
        )
        XCTAssertEqual(failure.title, "Cannot find example.com")
    }

    func testACrashedContentProcessReadsDifferentlyFromANetworkFailure() {
        let failure = KeelPageFailure(
            host: "example.com",
            code: KeelPageFailure.webContentProcessTerminated,
            underlyingDescription: ""
        )
        XCTAssertEqual(failure.title, "This page stopped responding")
        // No NSURLError number to show, so none is shown.
        XCTAssertEqual(failure.detail, "")
    }

    func testAnUnrecognisedFailureStillShowsItsCode() {
        let failure = KeelPageFailure(host: "example.com", code: -1234, underlyingDescription: "boom")
        XCTAssertEqual(failure.detail, "Error -1234")
        XCTAssertEqual(failure.message, "boom")
    }
}
