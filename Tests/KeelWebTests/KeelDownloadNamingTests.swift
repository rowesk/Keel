import XCTest
@testable import KeelWeb

final class KeelDownloadNamingTests: XCTestCase {
    func testPreservesRoyalMailServerFilenameIncludingItsExtension() {
        XCTAssertEqual(
            KeelDownloadNaming.filename(
                suggestedFilename: "RoyalMail-postage-label.pdf",
                mimeType: "application/octet-stream"
            ),
            "RoyalMail-postage-label.pdf"
        )
    }

    func testDelegateSuggestionWinsOverResponseMetadata() throws {
        let responseURL = try XCTUnwrap(URL(string: "https://business.royalmail.com/postage/incorrect"))
        XCTAssertEqual(
            KeelDownloadNaming.filename(
                suggestedFilename: "RoyalMail-label.pdf",
                responseSuggestedFilename: "response-name.pdf",
                responseURL: responseURL,
                mimeType: "application/pdf"
            ),
            "RoyalMail-label.pdf"
        )
    }

    func testAddsPDFExtensionForRoyalMailWhenEveryFilenameIsMissingAnExtension() throws {
        let responseURL = try XCTUnwrap(URL(string: "https://business.royalmail.com/postage/label"))
        XCTAssertEqual(
            KeelDownloadNaming.filename(
                suggestedFilename: "Unknown",
                responseSuggestedFilename: "Unknown",
                responseURL: responseURL,
                mimeType: "application/pdf; charset=binary"
            ),
            "label.pdf"
        )
    }

    func testUsesResponseSuggestedFilenameBeforeTheResponseURLLeaf() throws {
        let responseURL = try XCTUnwrap(URL(string: "https://files.example/export/incorrect-name"))
        XCTAssertEqual(
            KeelDownloadNaming.filename(
                suggestedFilename: "Unknown",
                responseSuggestedFilename: "correct-name.csv",
                responseURL: responseURL,
                mimeType: "text/csv"
            ),
            "correct-name.csv"
        )
    }

    func testDecodesAndSanitizesATraversalFilename() {
        XCTAssertEqual(
            KeelDownloadNaming.filename(
                suggestedFilename: "..%2F..%2Froyal:mail-label",
                mimeType: "application/pdf"
            ),
            "royal-mail-label.pdf"
        )
    }

    func testDoesNotGuessForUnknownBinaryContent() {
        XCTAssertEqual(
            KeelDownloadNaming.filename(
                suggestedFilename: nil,
                mimeType: "application/octet-stream",
                fallbackName: "download"
            ),
            "download"
        )
    }
}
