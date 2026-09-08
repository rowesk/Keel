import AppKit

/// Startup recovery never opens, replaces, or deletes the database.
@MainActor
final class KeelRecoveryController: NSObject {
    private let savePanel: any KeelDiagnosticsSavePanelPresenting
    private(set) var diagnosticData = Data()
    private var window: NSWindow?
    private var retry: (() -> Void)?

    init(savePanel: any KeelDiagnosticsSavePanelPresenting) {
        self.savePanel = savePanel
    }

    static func diagnosticData(for error: Error) -> Data {
        // Error descriptions and userInfo can contain SQL, paths or browsing data.
        let code = (error as NSError).code
        return Data("Keel startup failure\nError code: \(code)\nThe original database has been preserved.\n".utf8)
    }

    func showStartupFailure(error: Error, presentsWindow: Bool = true, retry: @escaping () -> Void) {
        diagnosticData = Self.diagnosticData(for: error)
        self.retry = retry
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 210),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Keel could not open its data"
            window.isReleasedWhenClosed = false
            let message = NSTextField(wrappingLabelWithString: "Keel could not open its local data. Your database has been preserved. Retry after resolving the storage problem, or export a diagnostic for support.")
            let retryButton = NSButton(title: "Retry", target: self, action: #selector(retryStartup))
            let exportButton = NSButton(title: "Export diagnostic", target: self, action: #selector(exportDiagnostic))
            let buttons = NSStackView(views: [retryButton, exportButton])
            let stack = NSStackView(views: [message, buttons])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 24
            stack.translatesAutoresizingMaskIntoConstraints = false
            window.contentView?.addSubview(stack)
            if let content = window.contentView {
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                    stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                    stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
                ])
            }
            window.center()
            self.window = window
        }
        if presentsWindow { window?.makeKeyAndOrderFront(nil) }
    }

    @discardableResult
    func reopenIfNeeded() -> Bool {
        guard let window else { return false }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func close() { window?.close() }
    @objc func retryStartup() { retry?() }
    @objc private func exportDiagnostic() {
        savePanel.save(data: diagnosticData, suggestedFileName: "Keel-startup-diagnostic.txt", in: window) { [weak self] result in
            guard case .failure(.writeFailed) = result, let window = self?.window else { return }
            let alert = NSAlert()
            alert.messageText = "The diagnostic could not be saved"
            alert.informativeText = "Choose another location and try exporting again."
            alert.beginSheetModal(for: window)
        }
    }
}
