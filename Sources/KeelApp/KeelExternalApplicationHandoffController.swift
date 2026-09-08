import AppKit
import KeelStore
import KeelWeb

/// A resolved application is deliberately separate from a requested URL. The URL never
/// enters alert text, persistence, or diagnostics.
@MainActor
struct KeelExternalApplicationResolvedTarget: Equatable {
    let applicationURL: URL
    let applicationName: String
    let bundleIdentifier: String?
}

@MainActor
enum KeelExternalApplicationPromptDecision: Equatable {
    case allowOnce
    case alwaysAllow
    case cancel
}

@MainActor
struct KeelExternalApplicationPrompt: Equatable {
    let source: String
    let scheme: String
    let applicationName: String

    init(approval: KeelExternalApplicationApproval, target: KeelExternalApplicationResolvedTarget) {
        source = approval.sourceHostname
        scheme = approval.target.scheme
        applicationName = target.applicationName
    }
}

@MainActor
protocol KeelExternalApplicationWorkspace {
    func resolveApplication(for url: URL) -> KeelExternalApplicationResolvedTarget?
    func open(
        _ url: URL,
        with target: KeelExternalApplicationResolvedTarget,
        completion: @escaping @MainActor (Error?) -> Void
    )
}

@MainActor
protocol KeelExternalApplicationPromptPresenting {
    func present(
        _ prompt: KeelExternalApplicationPrompt,
        in window: NSWindow?,
        completion: @escaping @MainActor (KeelExternalApplicationPromptDecision) -> Void
    )

    func presentError(
        _ error: KeelExternalApplicationHandoffError,
        in window: NSWindow?,
        completion: @escaping @MainActor () -> Void
    )
}

@MainActor
enum KeelExternalApplicationHandoffError: Equatable {
    case noRegisteredHandler(scheme: String)
    case launchFailed(applicationName: String)

    var messageText: String {
        switch self {
        case let .noRegisteredHandler(scheme):
            "Keel cannot open \(scheme) links"
        case let .launchFailed(applicationName):
            "Keel could not open \(applicationName)"
        }
    }

    var informativeText: String {
        switch self {
        case let .noRegisteredHandler(scheme):
            "No application on this Mac is registered to handle \(scheme) links."
        case let .launchFailed(applicationName):
            "\(applicationName) did not accept this link."
        }
    }
}

@MainActor
final class KeelSystemExternalApplicationWorkspace: KeelExternalApplicationWorkspace {
    func resolveApplication(for url: URL) -> KeelExternalApplicationResolvedTarget? {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            return nil
        }
        let name = FileManager.default.displayName(atPath: applicationURL.path)
        return KeelExternalApplicationResolvedTarget(
            applicationURL: applicationURL,
            applicationName: name,
            bundleIdentifier: Bundle(url: applicationURL)?.bundleIdentifier
        )
    }

    func open(
        _ url: URL,
        with target: KeelExternalApplicationResolvedTarget,
        completion: @escaping @MainActor (Error?) -> Void
    ) {
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: target.applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            Task { @MainActor in
                completion(error)
            }
        }
    }
}

@MainActor
final class KeelAppKitExternalApplicationPromptPresenter: KeelExternalApplicationPromptPresenting {
    func present(
        _ prompt: KeelExternalApplicationPrompt,
        in window: NSWindow?,
        completion: @escaping @MainActor (KeelExternalApplicationPromptDecision) -> Void
    ) {
        guard let window else {
            completion(.cancel)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Open \(prompt.applicationName)?"
        alert.informativeText = "\(prompt.source) wants to open a \(prompt.scheme) link in \(prompt.applicationName)."
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Always Allow")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            let decision: KeelExternalApplicationPromptDecision = switch response {
            case .alertFirstButtonReturn: .allowOnce
            case .alertSecondButtonReturn: .alwaysAllow
            default: .cancel
            }
            completion(decision)
        }
    }

    func presentError(
        _ error: KeelExternalApplicationHandoffError,
        in window: NSWindow?,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let window else {
            completion()
            return
        }
        let alert = NSAlert()
        alert.messageText = error.messageText
        alert.informativeText = error.informativeText
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in completion() }
    }
}

/// Owns the only path that can ask macOS to open another application. This controller
/// resolves an application before the prompt and makes persistence explicit.
@MainActor
final class KeelExternalApplicationHandoffController {
    private let store: KeelStore
    private let workspace: any KeelExternalApplicationWorkspace
    private let promptPresenter: any KeelExternalApplicationPromptPresenting
    private let windowProvider: @MainActor () -> NSWindow?
    private var pendingRequestID: UUID?
    private var automaticAttemptOrder: [AutomaticHandoffAttempt] = []
    private var automaticAttempts: Set<AutomaticHandoffAttempt> = []

    init(
        store: KeelStore,
        workspace: any KeelExternalApplicationWorkspace = KeelSystemExternalApplicationWorkspace(),
        promptPresenter: any KeelExternalApplicationPromptPresenting = KeelAppKitExternalApplicationPromptPresenter(),
        windowProvider: @escaping @MainActor () -> NSWindow?
    ) {
        self.store = store
        self.workspace = workspace
        self.promptPresenter = promptPresenter
        self.windowProvider = windowProvider
    }

    func request(
        _ approval: KeelExternalApplicationApproval,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard approval.target.scheme.lowercased() != "javascript",
              pendingRequestID == nil,
              let key = approvalKey(for: approval),
              registerAutomaticAttemptIfNeeded(approval: approval, key: key)
        else {
            completion(false)
            return
        }

        let requestID = UUID()
        pendingRequestID = requestID
        guard let target = workspace.resolveApplication(for: approval.url) else {
            presentError(.noRegisteredHandler(scheme: key.scheme), requestID: requestID, completion: completion)
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            let remembered = (try? await store.hasExternalApplicationApproval(for: key)) == true
            guard pendingRequestID == requestID else {
                return
            }
            if remembered {
                launch(approval.url, target: target, requestID: requestID, completion: completion)
                return
            }
            let prompt = KeelExternalApplicationPrompt(approval: approval, target: target)
            promptPresenter.present(prompt, in: windowProvider()) { [weak self] decision in
                self?.resolve(
                    decision,
                    approvalURL: approval.url,
                    key: key,
                    target: target,
                    requestID: requestID,
                    completion: completion
                )
            }
        }
    }

    private func resolve(
        _ decision: KeelExternalApplicationPromptDecision,
        approvalURL: URL,
        key: ExternalApplicationApprovalKey,
        target: KeelExternalApplicationResolvedTarget,
        requestID: UUID,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard pendingRequestID == requestID else {
            return
        }
        switch decision {
        case .cancel:
            finish(requestID: requestID, opened: false, completion: completion)
        case .allowOnce:
            launch(approvalURL, target: target, requestID: requestID, completion: completion)
        case .alwaysAllow:
            Task { [weak self] in
                guard let self else { return }
                _ = try? await store.apply([.rememberExternalApplicationApproval(key)])
                guard pendingRequestID == requestID else { return }
                launch(approvalURL, target: target, requestID: requestID, completion: completion)
            }
        }
    }

    private func launch(
        _ url: URL,
        target: KeelExternalApplicationResolvedTarget,
        requestID: UUID,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard pendingRequestID == requestID else {
            return
        }
        workspace.open(url, with: target) { [weak self] error in
            guard let self, pendingRequestID == requestID else {
                return
            }
            if error == nil {
                finish(requestID: requestID, opened: true, completion: completion)
            } else {
                presentError(
                    .launchFailed(applicationName: target.applicationName),
                    requestID: requestID,
                    completion: completion
                )
            }
        }
    }

    private func presentError(
        _ error: KeelExternalApplicationHandoffError,
        requestID: UUID,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        promptPresenter.presentError(error, in: windowProvider()) { [weak self] in
            self?.finish(requestID: requestID, opened: false, completion: completion)
        }
    }

    private func finish(
        requestID: UUID,
        opened: Bool,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard pendingRequestID == requestID else {
            return
        }
        pendingRequestID = nil
        completion(opened)
    }

    private func approvalKey(for approval: KeelExternalApplicationApproval) -> ExternalApplicationApprovalKey? {
        let principal: ExternalApplicationApprovalPrincipal
        switch approval.trigger {
        case .typed:
            principal = .keel
        case .userActivatedPage, .automaticPage:
            guard let website = try? ExternalApplicationApprovalPrincipal.validatedWebsiteHostname(approval.sourceHostname) else {
                return nil
            }
            principal = website
        }
        return try? ExternalApplicationApprovalKey(principal: principal, scheme: approval.target.scheme)
    }

    /// A page may attempt the same side effect repeatedly after a prompt completes or
    /// from a remembered permission. One page, principal, and scheme get one automatic
    /// attempt. The small FIFO bound prevents a long session from retaining page IDs.
    private func registerAutomaticAttemptIfNeeded(
        approval: KeelExternalApplicationApproval,
        key: ExternalApplicationApprovalKey
    ) -> Bool {
        guard approval.trigger == .automaticPage else {
            return true
        }
        let attempt = AutomaticHandoffAttempt(key: key, pageID: approval.sourcePageID)
        guard automaticAttempts.insert(attempt).inserted else {
            return false
        }
        automaticAttemptOrder.append(attempt)
        if automaticAttemptOrder.count > Self.maximumAutomaticAttemptRecords {
            let expired = automaticAttemptOrder.removeFirst()
            automaticAttempts.remove(expired)
        }
        return true
    }

    private static let maximumAutomaticAttemptRecords = 128
}

private struct AutomaticHandoffAttempt: Hashable {
    let key: ExternalApplicationApprovalKey
    let pageID: UUID?
}
