import AppKit
import KeelUI
import SwiftUI

/// Covers the browser content with one SwiftUI surface at a time. The host itself
/// stays alive so switching screens never creates another window or WebView.
@MainActor
final class KeelNativeScreenHost: NSView {
    enum Screen: Equatable {
        case home
        case history
        case downloads
        case settings
    }

    private(set) var screen: Screen?
    private let hostingView: NSHostingView<AnyView>
    /// Filled by HomeView while Home is on screen. Layout tests read it to
    /// prove the capsule holds still while work arrives and leaves.
    let homeCapsuleAnchor = KeelHomeCapsuleAnchor()

    override init(frame frameRect: NSRect) {
        hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityLabel("Keel native screen")
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeelNativeScreenHost must be created in code")
    }

    /// - Parameter addressField: The palette's own field, wrapped for SwiftUI,
    ///   so Home's capsule is the real editor rather than a picture of one.
    func showHome(
        model: KeelHomeModel,
        actions: KeelHomeActions,
        addressField: AnyView? = nil,
        scene: KeelHomeSceneDisplay = .como
    ) {
        update(
            screen: .home,
            rootView: HomeView(
                model: model,
                actions: actions,
                addressField: addressField,
                capsuleAnchor: homeCapsuleAnchor,
                scene: scene
            )
        )
    }

    /// Where Home's capsule sits, in this view's top-down coordinates, for
    /// layout tests. SwiftUI reports `.global` in the window's space, so the
    /// view's own offset from the window top is removed.
    var homeCapsuleFrame: CGRect? {
        guard screen == .home, !isHidden,
              let anchor = homeCapsuleAnchor.frame,
              let contentView = window?.contentView
        else { return nil }
        let topLeftInWindow = convert(NSPoint(x: 0, y: isFlipped ? 0 : bounds.height), to: nil)
        let topOffset = contentView.bounds.height - topLeftInWindow.y
        return anchor.offsetBy(dx: -topLeftInWindow.x, dy: -topOffset)
    }

    func showHistory(model: KeelHistoryModel, actions: KeelHistoryActions) {
        update(screen: .history, rootView: HistoryView(model: model, actions: actions))
    }

    func showDownloads(model: KeelDownloadModel, actions: KeelDownloadActions) {
        update(screen: .downloads, rootView: DownloadsView(model: model, actions: actions))
    }

    func showSettings(model: KeelSettingsModel, actions: KeelSettingsActions) {
        update(screen: .settings, rootView: SettingsView(model: model, actions: actions))
    }

    func hide() {
        screen = nil
        isHidden = true
        hostingView.rootView = AnyView(EmptyView())
        homeCapsuleAnchor.update(nil)
    }

    /// Return a child hit target when SwiftUI has one. Blank space still returns the
    /// host, which prevents pointer events from reaching a browser view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        return super.hitTest(point) ?? self
    }

    var hostedViewForTesting: NSView { hostingView }

    private func update<V: View>(screen: Screen, rootView: V) {
        let wasHidden = isHidden
        self.screen = screen
        hostingView.rootView = AnyView(rootView)
        isHidden = false
        needsLayout = true

        // M1: a native screen fades in over the page. Switching between two
        // native screens stays instant; only the page-to-screen boundary is a
        // spatial change worth teaching. Hiding stays synchronous so the page
        // is interactive the moment it is back.
        if wasHidden {
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = KeelDesign.Motion.screenFade
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        } else {
            alphaValue = 1
        }
    }
}

/// The Store owns queue deletion expiry. AppKit only schedules the one event needed
/// to remove the visible Undo affordance. Replacing a deadline cancels its predecessor.
@MainActor
final class KeelQueueDeletionUndoExpiryController {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let sleep: Sleep
    private var task: Task<Void, Never>?
    private(set) var deadline: Date?
    var onExpired: ((Date) -> Void)?

    init(sleep: @escaping Sleep = { duration in
        try await Task.sleep(for: duration)
    }) {
        self.sleep = sleep
    }

    deinit {
        task?.cancel()
    }

    func update(deadline newDeadline: Date?) {
        guard deadline != newDeadline else { return }
        task?.cancel()
        task = nil
        deadline = newDeadline
        guard let newDeadline else { return }

        let delay = max(0, newDeadline.timeIntervalSinceNow)
        let sleep = self.sleep
        task = Task { @MainActor [weak self] in
            do {
                try await sleep(.seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.deadline == newDeadline else { return }
            self.onExpired?(newDeadline)
        }
    }

    func cancel() {
        update(deadline: nil)
    }
}
