import AppKit
import KeelUI

/// One replaceable receipt. It never participates in page layout or keyboard focus.
@MainActor
final class KeelInteractionReceiptController {
    static let duration: TimeInterval = 3
    private let label = NSTextField(labelWithString: "")
    private let panel = KeelReceiptPanel()
    private var topInset: NSLayoutConstraint?
    private var homeBottomInset: NSLayoutConstraint?
    private var dismissal: Task<Void, Never>?
    private(set) var generation = 0
    private(set) var message: String?
    var viewForTesting: NSView { panel }
    var announce: ((String) -> Void)?

    func install(in shell: KeelShellView) {
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 8
        panel.layer?.backgroundColor = KeelDesign.NSSurface.raised.cgColor
        panel.layer?.borderColor = KeelDesign.NSSurface.hairline.cgColor
        panel.layer?.borderWidth = 1
        panel.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = KeelDesign.NSSurface.ink
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        panel.addSubview(label)
        shell.addSubview(panel)
        topInset = panel.topAnchor.constraint(equalTo: shell.contentGuide.topAnchor, constant: 12)
        homeBottomInset = panel.bottomAnchor.constraint(equalTo: shell.contentGuide.bottomAnchor, constant: -72)
        homeBottomInset?.isActive = true
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: shell.contentGuide.centerXAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualTo: shell.contentGuide.widthAnchor, constant: -32),
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: panel.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -9),
        ])
        panel.isHidden = true
    }

    func updateSurface(isHome: Bool) {
        topInset?.isActive = !isHome
        homeBottomInset?.isActive = isHome
    }

    func capture(url: URL, added: Bool) {
        show("\(added ? "Added to queue" : "Already in queue"): \(identity(url))")
    }

    func finish(nextURL: URL?) {
        show(nextURL.map { "Next: \(identity($0))" } ?? "Finished. Queue empty.")
    }

    func show(_ text: String) {
        dismissal?.cancel()
        generation += 1
        let token = generation
        let changed = message != text
        message = text
        label.stringValue = text
        panel.isHidden = false
        if changed {
            if let announce { announce(text) }
            else if let window = panel.window, window.isVisible {
                NSAccessibility.post(element: window, notification: .announcementRequested,
                    userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        }
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.duration))
            guard !Task.isCancelled else { return }
            self?.dismiss(generation: token)
        }
    }

    func dismiss(generation token: Int) {
        guard token == generation else { return }
        dismissal?.cancel()
        dismissal = nil
        message = nil
        panel.isHidden = true
    }

    private func identity(_ url: URL) -> String {
        // Full destination identity without credentials. No metadata or page fetch.
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.host ?? "Destination"
        }
        components.user = nil
        components.password = nil
        return components.string ?? url.host ?? "Destination"
    }
}

private final class KeelReceiptPanel: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = KeelDesign.NSSurface.raised.cgColor
            layer?.borderColor = KeelDesign.NSSurface.hairline.cgColor
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
