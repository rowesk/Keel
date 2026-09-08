import Foundation

public struct KeelNavigationRequest: Equatable, Sendable {
    public let url: URL
    public let isPageOwned: Bool
    public let shouldPerformDownload: Bool
    /// Display-only origin context for an external-application approval.
    public let sourceURL: URL?
    public let isTargetBlank: Bool
    public let queueIntent: Bool
    public let responseCanShowMIMEType: Bool?
    public let externalApplicationTrigger: KeelExternalApplicationTrigger
    /// Ephemeral page identity used only to suppress repeated automatic handoffs.
    public let sourcePageID: UUID?

    public init(
        url: URL,
        isPageOwned: Bool = false,
        shouldPerformDownload: Bool = false,
        sourceURL: URL? = nil,
        isTargetBlank: Bool = false,
        queueIntent: Bool = false,
        responseCanShowMIMEType: Bool? = nil,
        externalApplicationTrigger: KeelExternalApplicationTrigger = .automaticPage,
        sourcePageID: UUID? = nil
    ) {
        self.url = url
        self.isPageOwned = isPageOwned
        self.shouldPerformDownload = shouldPerformDownload
        self.sourceURL = sourceURL
        self.isTargetBlank = isTargetBlank
        self.queueIntent = queueIntent
        self.responseCanShowMIMEType = responseCanShowMIMEType
        self.externalApplicationTrigger = externalApplicationTrigger
        self.sourcePageID = sourcePageID
    }
}

/// How an external application handoff originated. It is product context, not a URL.
public enum KeelExternalApplicationTrigger: Equatable, Sendable {
    case typed
    case userActivatedPage
    case automaticPage
}

/// Display metadata only. Resolving this value never opens the target application.
public struct KeelExternalApplicationTarget: Equatable, Sendable {
    public let scheme: String
    public let applicationName: String?
    public let bundleIdentifier: String?

    public init(scheme: String, applicationName: String? = nil, bundleIdentifier: String? = nil) {
        self.scheme = scheme
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
    }

    public var displayedName: String {
        applicationName ?? "an application that handles \(scheme) links"
    }
}

/// The AppKit adapter may resolve handler metadata using the system. The policy itself
/// has no launching capability, which keeps unapproved schemes fail-closed in tests.
public protocol KeelExternalApplicationResolving: Sendable {
    func target(for url: URL, scheme: String) -> KeelExternalApplicationTarget
}

public struct KeelDefaultExternalApplicationResolver: KeelExternalApplicationResolving {
    public init() {}

    public func target(for _: URL, scheme: String) -> KeelExternalApplicationTarget {
        KeelExternalApplicationTarget(scheme: scheme)
    }
}

public enum KeelExternalApplicationApprovalDefault: Equatable, Sendable {
    case deny
}

public struct KeelExternalApplicationApproval: Equatable, Sendable {
    public let sourceHostname: String
    public let url: URL
    public let target: KeelExternalApplicationTarget
    public let trigger: KeelExternalApplicationTrigger
    /// This is never persisted or shown. It scopes automatic-attempt suppression to one page.
    public let sourcePageID: UUID?
    public let defaultDecision: KeelExternalApplicationApprovalDefault

    public init(
        sourceHostname: String,
        url: URL,
        target: KeelExternalApplicationTarget,
        trigger: KeelExternalApplicationTrigger = .automaticPage,
        sourcePageID: UUID? = nil,
        defaultDecision: KeelExternalApplicationApprovalDefault = .deny
    ) {
        self.sourceHostname = sourceHostname
        self.url = url
        self.target = target
        self.trigger = trigger
        self.sourcePageID = sourcePageID
        self.defaultDecision = defaultDecision
    }
}

public enum KeelUnsupportedNavigation: Equatable, Sendable {
    case unsupportedScheme(String?)
}

public enum KeelNavigationDecision: Equatable, Sendable {
    case allowInActivePage
    case enqueue
    case download
    case requestExternalApplicationApproval(KeelExternalApplicationApproval)
    case cancel(KeelUnsupportedNavigation)
}

public enum KeelNavigationPolicy {
    /// An explicit attachment remains a download even when WebKit can display its MIME type.
    static func isAttachment(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse,
              let disposition = response.value(forHTTPHeaderField: "Content-Disposition") else { return false }
        return disposition.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "attachment"
    }

    public static func decision(
        for request: KeelNavigationRequest,
        externalApplicationResolver: some KeelExternalApplicationResolving = KeelDefaultExternalApplicationResolver()
    ) -> KeelNavigationDecision {
        guard let scheme = request.url.scheme?.lowercased(), !scheme.isEmpty else {
            return .cancel(.unsupportedScheme(nil))
        }
        // Internal forms belong to WebKit's existing page, never typed input or the queue.
        if request.isPageOwned && !request.queueIntent {
            if request.url.absoluteString == "about:blank" { return .allowInActivePage }
            if ["blob", "data"].contains(scheme), request.shouldPerformDownload {
                return .download
            }
        }
        guard supportedSchemes.contains(scheme) else {
            guard !nonExternalSchemes.contains(scheme) else {
                return .cancel(.unsupportedScheme(scheme))
            }
            let sourceHostname = request.sourceURL?.host ?? "Keel"
            let target = externalApplicationResolver.target(for: request.url, scheme: scheme)
            return .requestExternalApplicationApproval(
                KeelExternalApplicationApproval(
                    sourceHostname: sourceHostname,
                    url: request.url,
                    target: target,
                    trigger: request.externalApplicationTrigger,
                    sourcePageID: request.sourcePageID
                )
            )
        }
        if request.shouldPerformDownload || request.responseCanShowMIMEType == false { return .download }
        if request.queueIntent { return .enqueue }
        return .allowInActivePage
    }

    private static let supportedSchemes: Set<String> = ["http", "https"]
    /// These URL forms execute or resolve inside the current document. They are not
    /// system-application handoffs and must stay blocked rather than be mislabelled.
    private static let nonExternalSchemes: Set<String> = ["about", "blob", "data", "javascript"]
}
