import AppKit
import KeelUI

/// What page am I on, is it secure, is it still loading. A browser has to answer
/// those three without the user opening anything, and Keel's toolbar previously
/// answered none of them.
///
/// It reads as a field and behaves as a button, because editing happens in the
/// address palette where suggestions live.
@MainActor
final class KeelAddressBarView: NSControl {
    private let background = NSView()
    private let securityIcon = NSImageView()
    private let faviconView = NSImageView()
    private let hostLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let placeholderLabel = NSTextField(labelWithString: "Search or enter address")
    private let shortcutLabel = NSTextField(labelWithString: "⌘L")
    private let progressBar = NSView()

    private var progressWidth: NSLayoutConstraint?
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var isEmpty = true

    var onActivate: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeelAddressBarView must be created in code")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 26)
    }

    // MARK: Content

    /// Shows the destination. `title` is the page title when WebKit has one.
    func show(url: URL?, title: String?, isSecure: Bool) {
        guard let url, let host = url.host, !host.isEmpty else {
            showEmpty()
            return
        }

        isEmpty = false
        placeholderLabel.isHidden = true
        hostLabel.isHidden = false
        pathLabel.isHidden = false
        securityIcon.isHidden = false
        faviconView.isHidden = faviconView.image == nil

        hostLabel.stringValue = Self.displayHost(host)

        // The host is what a person checks. The rest of the address stays legible
        // but recedes, so a long tracking-parameter tail cannot bury the origin.
        let remainder = Self.remainder(of: url)
        pathLabel.stringValue = remainder
        pathLabel.isHidden = remainder.isEmpty

        securityIcon.image = NSImage(
            systemSymbolName: isSecure ? "lock.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: isSecure ? "Secure connection" : "Connection is not secure"
        )
        securityIcon.contentTintColor = isSecure ? .tertiaryLabelColor : .systemOrange

        let accessibleTitle = title?.isEmpty == false ? "\(title ?? ""), " : ""
        setAccessibilityLabel("Address. \(accessibleTitle)\(host). Activate to edit.")
        toolTip = title?.isEmpty == false ? "\(title ?? "")\n\(url.absoluteString)" : url.absoluteString
    }

    func showEmpty() {
        isEmpty = true
        placeholderLabel.isHidden = false
        hostLabel.isHidden = true
        pathLabel.isHidden = true
        securityIcon.isHidden = true
        faviconView.isHidden = true
        setFavicon(nil)
        setAccessibilityLabel("Search or enter an address")
        toolTip = "Search or enter address  ⌘L"
    }

    func setFavicon(_ image: NSImage?) {
        faviconView.image = image
        faviconView.isHidden = image == nil || isEmpty
    }

    /// `nil` hides the bar. WebKit's estimated progress drives this.
    func setLoadingProgress(_ progress: Double?) {
        guard let progress, progress < 1 else {
            progressBar.isHidden = true
            progressWidth?.constant = 0
            return
        }
        progressBar.isHidden = false
        let clamped = min(max(progress, 0.02), 1)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            progressWidth?.animator().constant = bounds.width * clamped
        }
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateBackground()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    // MARK: Construction

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        background.wantsLayer = true
        background.layer?.cornerRadius = 7
        background.layer?.borderWidth = 1
        background.layer?.masksToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = KeelDesign.NSSurface.accent.withAlphaComponent(0.22).cgColor
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.isHidden = true
        background.addSubview(progressBar)

        configure(securityIcon, pointSize: 9)
        faviconView.imageScaling = .scaleProportionallyUpOrDown
        faviconView.translatesAutoresizingMaskIntoConstraints = false
        faviconView.isHidden = true

        hostLabel.font = .systemFont(ofSize: 12, weight: .medium)
        hostLabel.textColor = KeelDesign.NSSurface.ink
        hostLabel.lineBreakMode = .byTruncatingTail
        hostLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        hostLabel.setContentHuggingPriority(.required, for: .horizontal)

        pathLabel.font = .systemFont(ofSize: 12, weight: .regular)
        pathLabel.textColor = KeelDesign.NSSurface.inkSecondary
        pathLabel.lineBreakMode = .byTruncatingTail
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        placeholderLabel.font = .systemFont(ofSize: 12)
        placeholderLabel.textColor = KeelDesign.NSSurface.inkSecondary

        shortcutLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        shortcutLabel.textColor = KeelDesign.NSSurface.inkTertiary
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [
            securityIcon, faviconView, hostLabel, pathLabel, placeholderLabel,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        background.addSubview(shortcutLabel)
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false

        let progressWidth = progressBar.widthAnchor.constraint(equalToConstant: 0)
        self.progressWidth = progressWidth

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            progressBar.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            progressBar.topAnchor.constraint(equalTo: background.topAnchor),
            progressBar.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            progressWidth,

            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -6),

            shortcutLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            shortcutLabel.centerYAnchor.constraint(equalTo: background.centerYAnchor),

            securityIcon.widthAnchor.constraint(equalToConstant: 10),
            faviconView.widthAnchor.constraint(equalToConstant: 14),
            faviconView.heightAnchor.constraint(equalToConstant: 14),
        ])

        showEmpty()
        updateBackground()
    }

    private func configure(_ imageView: NSImageView, pointSize: CGFloat) {
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func updateBackground() {
        let ink = KeelDesign.NSSurface.ink
        background.layer?.backgroundColor = ink.withAlphaComponent(isHovering ? 0.1 : 0.06).cgColor
        background.layer?.borderColor = ink.withAlphaComponent(isHovering ? 0.18 : 0.1).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            updateBackground()
            progressBar.layer?.backgroundColor = KeelDesign.NSSurface.accent.withAlphaComponent(0.22).cgColor
        }
    }

    // MARK: Formatting

    static func displayHost(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Path, query and fragment as one string. Empty for a bare origin, so a
    /// homepage does not render a lonely slash.
    static func remainder(of url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        components.scheme = nil
        components.host = nil
        components.user = nil
        components.password = nil
        components.port = nil
        let value = components.string ?? ""
        return value == "/" ? "" : value
    }
}
