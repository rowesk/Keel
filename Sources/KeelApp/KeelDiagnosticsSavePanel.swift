import AppKit
import Foundation

@MainActor
final class KeelDiagnosticsPresenceCache {
    private(set) var hasDiagnostics: Bool

    init(hasDiagnostics: Bool = false) {
        self.hasDiagnostics = hasDiagnostics
    }

    func update(hasDiagnostics: Bool) {
        self.hasDiagnostics = hasDiagnostics
    }
}

enum KeelDiagnosticsSaveError: Error, Equatable, Sendable {
    case noWindow
    case cancelled
    case writeFailed
}

@MainActor
protocol KeelDiagnosticsSavePanelPresenting: AnyObject {
    func save(
        data: Data,
        suggestedFileName: String,
        in window: NSWindow?,
        completion: @escaping @MainActor (Result<URL, KeelDiagnosticsSaveError>) -> Void
    )
}

@MainActor
final class KeelAppKitDiagnosticsSavePanel: KeelDiagnosticsSavePanelPresenting {
    func save(
        data: Data,
        suggestedFileName: String,
        in window: NSWindow?,
        completion: @escaping @MainActor (Result<URL, KeelDiagnosticsSaveError>) -> Void
    ) {
        guard let window else {
            completion(.failure(.noWindow))
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFileName
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else {
                completion(.failure(.cancelled))
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                completion(.success(url))
            } catch {
                completion(.failure(.writeFailed))
            }
        }
    }
}

@MainActor
protocol KeelAppErrorPresenting: AnyObject {
    func present(message: String, informativeText: String, in window: NSWindow?)
}

@MainActor
final class KeelAppKitErrorPresenter: KeelAppErrorPresenting {
    func present(message: String, informativeText: String, in window: NSWindow?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informativeText
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}
