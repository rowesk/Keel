import AppKit

@MainActor
final class KeelWindowController: NSWindowController, NSWindowDelegate {
    let chromeController: KeelChromeController
    let shellView: KeelShellView

    var onVisibilityChanged: ((Bool) -> Void)?
    private(set) var isChromeVisible = true
    private var hiddenChromeDragMonitor: Any?
    private let windowPresentation: any KeelWindowPresenting
    var permitsWindowPresentation: Bool

    init(
        shellView: KeelShellView,
        chromeController: KeelChromeController = KeelChromeController(),
        permitsWindowPresentation: Bool = true,
        windowPresentation: any KeelWindowPresenting = KeelAppKitWindowPresenter()
    ) {
        self.chromeController = chromeController
        self.shellView = shellView
        self.permitsWindowPresentation = permitsWindowPresentation
        self.windowPresentation = windowPresentation

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Keel"
        window.titleVisibility = .hidden
        // Opaque while chrome is visible so toolbar glyphs sit on title bar
        // material instead of compositing onto whatever the page painted.
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unifiedCompact
        // Automatic lets AppKit fade a soft shadow under the toolbar as if page
        // content were scrolling beneath it. Keel insets its content instead, so
        // nothing is under there and the shadow was just a smudge.
        window.titlebarSeparatorStyle = .line
        window.contentView = shellView
        window.minSize = NSSize(width: 720, height: 480)
        if permitsWindowPresentation && windowPresentation.savesWindowFrame {
            window.setFrameAutosaveName("com.chrisrowe.keel.main-window")
        }
        window.tabbingMode = .disallowed

        super.init(window: window)

        window.delegate = self
        chromeController.install(in: window)
        installHiddenChromeDragMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeelWindowController must be created in code")
    }

    func showSoleWindow() {
        guard permitsWindowPresentation else { return }
        guard let window else { return }
        // showWindow restores the frame saved under the autosave name, which
        // resized the window every time the palette opened. Only the hidden
        // case needs it; an already-visible window just comes forward.
        if !windowPresentation.isVisible(window) {
            windowPresentation.showHiddenWindow(self)
        }
        windowPresentation.bringToFront(window)
        onVisibilityChanged?(true)
    }

    func hideSoleWindow() {
        window?.orderOut(nil)
        onVisibilityChanged?(false)
    }

    var isWindowVisible: Bool {
        window?.isVisible ?? false
    }

    /// Reflects the page title so Mission Control, the Window menu and Cmd+Tab
    /// name the window by where it is, even though the title itself is hidden.
    func updateWindowTitle(_ pageTitle: String?) {
        guard let pageTitle, !pageTitle.trimmingCharacters(in: .whitespaces).isEmpty else {
            window?.title = "Keel"
            return
        }
        window?.title = pageTitle
    }

    func setChromeVisible(_ isVisible: Bool) {
        isChromeVisible = isVisible
        shellView.isChromeVisible = isVisible
        chromeController.setVisible(isVisible, in: window)
    }

    func removeHiddenChromeDragMonitor() {
        if let hiddenChromeDragMonitor {
            NSEvent.removeMonitor(hiddenChromeDragMonitor)
            self.hiddenChromeDragMonitor = nil
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideSoleWindow()
        return false
    }

    func windowDidBecomeVisible(_ notification: Notification) {
        onVisibilityChanged?(true)
    }

    func windowDidBecomeHidden(_ notification: Notification) {
        onVisibilityChanged?(false)
    }

    private func installHiddenChromeDragMonitor() {
        hiddenChromeDragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  !self.isChromeVisible,
                  event.window === self.window,
                  event.modifierFlags.contains(.control),
                  event.modifierFlags.contains(.command)
            else {
                return event
            }

            self.window?.performDrag(with: event)
            return nil
        }
    }
}

/// Keeps window ordering separate so layout tests never send it to AppKit.
@MainActor
protocol KeelWindowPresenting {
    var savesWindowFrame: Bool { get }
    func isVisible(_ window: NSWindow) -> Bool
    func showHiddenWindow(_ controller: NSWindowController)
    func bringToFront(_ window: NSWindow)
}

@MainActor
struct KeelAppKitWindowPresenter: KeelWindowPresenting {
    let savesWindowFrame = true
    func isVisible(_ window: NSWindow) -> Bool { window.isVisible }
    func showHiddenWindow(_ controller: NSWindowController) { controller.showWindow(nil) }
    func bringToFront(_ window: NSWindow) { window.makeKeyAndOrderFront(nil) }
}
