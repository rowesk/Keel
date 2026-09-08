import AppKit
import XCTest
@testable import KeelApp

@MainActor
final class KeelRecoveryTests: XCTestCase {
    func testRetryRunsTheSuppliedRecoveryAndRetainsExportableFailure() {
        let recovery = KeelRecoveryController(savePanel: RecoverySavePanel())
        var retries = 0
        recovery.showStartupFailure(error: NSError(domain: "storage", code: 14), presentsWindow: false) {
            retries += 1
        }
        let diagnostic = recovery.diagnosticData
        recovery.retryStartup()
        XCTAssertEqual(retries, 1)
        XCTAssertEqual(recovery.diagnosticData, diagnostic)
        XCTAssertTrue(String(decoding: diagnostic, as: UTF8.self).contains("14"))
        recovery.close()
    }

    func testStartupDiagnosticExcludesErrorDescriptionAndUserInfo() {
        let secret = "https://private.example/search?q=secret"
        let error = NSError(domain: secret, code: 42, userInfo: [NSLocalizedDescriptionKey: secret])
        let data = KeelRecoveryController.diagnosticData(for: error)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("42"))
        XCTAssertFalse(text.contains(secret))
        XCTAssertLessThan(data.count, 256)
    }
}

@MainActor
private final class RecoverySavePanel: KeelDiagnosticsSavePanelPresenting {
    func save(data: Data, suggestedFileName: String, in window: NSWindow?,
              completion: @escaping @MainActor (Result<URL, KeelDiagnosticsSaveError>) -> Void) {
        completion(.failure(.cancelled))
    }
}
