import AppKit

/// The window's content view, and the one place that knows where Keel's content
/// actually starts.
///
/// The window uses `.fullSizeContentView` so hiding chrome gives an edge-to-edge
/// page. That also means this view's origin is the top of the *window*, not the
/// top of the area below the toolbar. Everything Keel draws hangs off
/// `contentGuide` instead of the view's own edges, so visible chrome pushes
/// content down and hidden chrome lets it fill the frame.
@MainActor
final class KeelShellView: NSView {
    /// Pin every child to this, never to the shell's own edges.
    let contentGuide = NSLayoutGuide()

    private var guideTopToWindow: NSLayoutConstraint?
    private var guideTopToSelf: NSLayoutConstraint?

    var isChromeVisible = true {
        didSet {
            guard isChromeVisible != oldValue else { return }
            applyTopConstraint()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addLayoutGuide(contentGuide)
        NSLayoutConstraint.activate([
            contentGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        guideTopToSelf = contentGuide.topAnchor.constraint(equalTo: topAnchor)
        guideTopToSelf?.isActive = true
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeelShellView must be created in code")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuildWindowConstraint()
    }

    /// AppKit keeps `contentLayoutGuide` correct across toolbar changes, full
    /// screen and title bar height changes, so Keel never measures a title bar.
    private func rebuildWindowConstraint() {
        guideTopToWindow?.isActive = false
        guideTopToWindow = nil

        if let windowGuide = window?.contentLayoutGuide as? NSLayoutGuide {
            guideTopToWindow = contentGuide.topAnchor.constraint(equalTo: windowGuide.topAnchor)
        }
        applyTopConstraint()
    }

    private func applyTopConstraint() {
        guard let guideTopToWindow else {
            guideTopToSelf?.isActive = true
            return
        }
        guideTopToSelf?.isActive = !isChromeVisible
        guideTopToWindow.isActive = isChromeVisible
    }

    /// Pins a subview to the content area. Use for anything that must not sit
    /// underneath the toolbar.
    func pinToContentArea(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentGuide.bottomAnchor),
        ])
    }
}
