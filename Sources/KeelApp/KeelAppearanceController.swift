import AppKit
import KeelStore

/// Applies the stored appearance preference. The choice itself lives in `KeelSettings`,
/// so it survives relaunch and this controller never owns durable state.
@MainActor
final class KeelAppearanceController {
    private(set) var preference: AppearanceMode

    init(preference: AppearanceMode = .system) {
        self.preference = preference
    }

    func apply(_ preference: AppearanceMode, to window: NSWindow) {
        self.preference = preference
        window.appearance = appearance(for: preference)
    }

    func apply(to view: NSView) {
        view.appearance = appearance(for: preference)
    }

    private func appearance(for preference: AppearanceMode) -> NSAppearance? {
        switch preference {
        case .system:
            nil
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        }
    }
}
