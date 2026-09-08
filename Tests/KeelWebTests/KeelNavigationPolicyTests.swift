import XCTest
@testable import KeelWeb

final class KeelNavigationPolicyTests: XCTestCase {
    func testOnlyExplicitAttachmentDispositionForcesDownload() throws {
        for (header, expected) in [
            ("attachment; filename=report.txt", true), (" ATTACHMENT ; filename=report.txt", true),
            ("inline; filename=attachment.txt", false), ("attachment-other", false), ("", false),
        ] {
            let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.com/report")!,
                statusCode: 200, httpVersion: nil, headerFields: ["content-disposition": header]))
            XCTAssertEqual(KeelNavigationPolicy.isAttachment(response), expected)
        }
    }

    func testInternalFormsRequirePageOwnershipAndDownloadIntent() throws {
        for value in ["about:blank", "blob:https://example.com/id", "data:text/plain,export", "javascript:alert(1)"] {
            let url = try XCTUnwrap(URL(string: value))
            guard case .cancel = KeelNavigationPolicy.decision(for: .init(url: url)) else {
                XCTFail("Typed internal URL was permitted: \(value)")
                continue
            }
        }
        XCTAssertEqual(KeelNavigationPolicy.decision(for: .init(url: URL(string: "about:blank")!, isPageOwned: true)), .allowInActivePage)
        for value in ["blob:https://example.com/id", "data:text/plain,export"] {
            let url = URL(string: value)!
            XCTAssertEqual(KeelNavigationPolicy.decision(for: .init(url: url, isPageOwned: true, shouldPerformDownload: true)), .download)
            guard case .cancel = KeelNavigationPolicy.decision(for: .init(url: url, isPageOwned: true)) else {
                return XCTFail("Non-download internal URL was permitted")
            }
        }
        XCTAssertEqual(KeelNavigationPolicy.decision(for: .init(url: URL(string: "https://example.com/file")!, shouldPerformDownload: true)), .download)
    }

    func testAllowsHTTPAndHTTPSInTheActivePage() throws {
        for value in ["http://example.com", "https://example.com"] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertEqual(
                KeelNavigationPolicy.decision(for: KeelNavigationRequest(url: url)),
                .allowInActivePage
            )
        }
    }

    func testTargetBlankStillUsesTheActivePage() throws {
        let url = try XCTUnwrap(URL(string: "https://listing.example/product"))
        XCTAssertEqual(
            KeelNavigationPolicy.decision(for: KeelNavigationRequest(url: url, isTargetBlank: true)),
            .allowInActivePage
        )
    }

    func testQueueIntentBecomesAQueueDecision() throws {
        let url = try XCTUnwrap(URL(string: "https://work.example/next"))
        XCTAssertEqual(
            KeelNavigationPolicy.decision(for: KeelNavigationRequest(url: url, queueIntent: true)),
            .enqueue
        )
    }

    func testNonDisplayableResponseBecomesDownloadBeforeQueueIntent() throws {
        let url = try XCTUnwrap(URL(string: "https://files.example/export"))
        XCTAssertEqual(
            KeelNavigationPolicy.decision(
                for: KeelNavigationRequest(url: url, queueIntent: true, responseCanShowMIMEType: false)
            ),
            .download
        )
    }

    func testExternalSchemesRequestFailClosedApprovalWithResolvedDisplayMetadata() throws {
        let url = try XCTUnwrap(URL(string: "mailto:hello@example.com"))
        let source = try XCTUnwrap(URL(string: "https://shop.example/checkout"))
        XCTAssertEqual(
            KeelNavigationPolicy.decision(
                for: KeelNavigationRequest(url: url, sourceURL: source),
                externalApplicationResolver: StubExternalApplicationResolver()
            ),
            .requestExternalApplicationApproval(
                KeelExternalApplicationApproval(
                    sourceHostname: "shop.example",
                    url: url,
                    target: KeelExternalApplicationTarget(
                        scheme: "mailto",
                        applicationName: "Mail",
                        bundleIdentifier: "com.apple.mail"
                    ),
                    defaultDecision: .deny
                )
            )
        )
    }

    func testRTSPAndMagnetLinksAlsoRequestApprovalWithoutLaunchingAnything() throws {
        for value in ["rtsp://camera.example/live", "magnet:?xt=urn:btih:1234"] {
            let url = try XCTUnwrap(URL(string: value))
            let decision = KeelNavigationPolicy.decision(for: KeelNavigationRequest(url: url))
            guard case let .requestExternalApplicationApproval(approval) = decision else {
                return XCTFail("Expected an external-app approval for \(value)")
            }
            XCTAssertEqual(approval.url, url)
            XCTAssertEqual(approval.target.scheme, try XCTUnwrap(url.scheme))
            XCTAssertEqual(approval.defaultDecision, .deny)
        }
    }

    func testDocumentInternalSchemesStayCancelled() throws {
        let url = try XCTUnwrap(URL(string: "javascript:alert(1)"))
        XCTAssertEqual(
            KeelNavigationPolicy.decision(for: KeelNavigationRequest(url: url)),
            .cancel(.unsupportedScheme("javascript"))
        )
    }

    func testExternalApprovalCarriesTypedAndPageTriggerContextWithoutUsingTheTargetURLAsSource() throws {
        let mailto = try XCTUnwrap(URL(string: "mailto:orders@example.com"))
        let page = try XCTUnwrap(URL(string: "https://shop.example/checkout"))

        let typed = KeelNavigationPolicy.decision(
            for: KeelNavigationRequest(url: mailto, externalApplicationTrigger: .typed)
        )
        let userActivated = KeelNavigationPolicy.decision(
            for: KeelNavigationRequest(
                url: mailto,
                sourceURL: page,
                externalApplicationTrigger: .userActivatedPage
            )
        )
        let automatic = KeelNavigationPolicy.decision(
            for: KeelNavigationRequest(
                url: mailto,
                sourceURL: page,
                externalApplicationTrigger: .automaticPage
            )
        )

        guard case let .requestExternalApplicationApproval(typedApproval) = typed,
              case let .requestExternalApplicationApproval(userApproval) = userActivated,
              case let .requestExternalApplicationApproval(automaticApproval) = automatic
        else {
            return XCTFail("Expected external application approvals")
        }
        XCTAssertEqual(typedApproval.sourceHostname, "Keel")
        XCTAssertEqual(typedApproval.trigger, .typed)
        XCTAssertEqual(userApproval.sourceHostname, "shop.example")
        XCTAssertEqual(userApproval.trigger, .userActivatedPage)
        XCTAssertEqual(automaticApproval.trigger, .automaticPage)
    }
}

private struct StubExternalApplicationResolver: KeelExternalApplicationResolving {
    func target(for _: URL, scheme: String) -> KeelExternalApplicationTarget {
        XCTAssertEqual(scheme, "mailto")
        return KeelExternalApplicationTarget(
            scheme: scheme,
            applicationName: "Mail",
            bundleIdentifier: "com.apple.mail"
        )
    }
}
