import AppKit
import KeelUI
import UniformTypeIdentifiers

@MainActor
enum KeelDownloadShelfState: Equatable {
    case waiting
    case receiving(progress: Double)
    case completed
    case cancelled
    case failed(message: String)

    var statusText: String {
        switch self {
        case .waiting: "Starting…"
        case let .receiving(progress): "\(Int(progress * 100))%"
        case .completed: "Downloaded"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .waiting, .receiving: false
        case .completed, .cancelled, .failed: true
        }
    }
}

@MainActor
struct KeelDownloadShelfItem: Identifiable, Equatable {
    let id: UUID
    let filename: String
    let state: KeelDownloadShelfState
    /// Rate and time remaining while the transfer runs. The card appends it to the
    /// status line rather than growing a row for it.
    let detail: String?

    init(id: UUID, filename: String, state: KeelDownloadShelfState, detail: String? = nil) {
        self.id = id
        self.filename = filename
        self.state = state
        self.detail = detail
    }

    var statusLine: String {
        guard let detail, !detail.isEmpty else { return state.statusText }
        return "\(state.statusText) · \(detail)"
    }
}

/// Decides when a finished card has been on screen long enough. It owns no timer and
/// no views, so the delay is provable without waiting for it.
struct KeelDownloadShelfAutoDismiss {
    /// Long enough to read the filename and reach for Open, short enough that the
    /// shelf empties itself between downloads. The countdown restarts in full once
    /// the pointer leaves, so a card the user was reading never vanishes under them.
    static let defaultDelay: TimeInterval = 5

    let delay: TimeInterval
    private var deadlines: [UUID: Date] = [:]
    private var isHovering = false

    init(delay: TimeInterval = defaultDelay) {
        self.delay = delay
    }

    mutating func setHovering(_ isHovering: Bool, at date: Date) {
        guard isHovering != self.isHovering else { return }
        self.isHovering = isHovering
        guard !isHovering else { return }
        for id in deadlines.keys {
            deadlines[id] = date.addingTimeInterval(delay)
        }
    }

    /// Arms a countdown for every card that finished successfully. A cancelled or
    /// failed card carries information the user has not seen, so it stays.
    mutating func track(items: [KeelDownloadShelfItem], at date: Date) {
        let present = Set(items.map(\.id))
        deadlines = deadlines.filter { present.contains($0.key) }
        for item in items {
            if item.state == .completed {
                if deadlines[item.id] == nil {
                    deadlines[item.id] = date.addingTimeInterval(delay)
                }
            } else {
                deadlines[item.id] = nil
            }
        }
    }

    func expired(at date: Date) -> [UUID] {
        guard !isHovering else { return [] }
        return deadlines
            .filter { $0.value <= date }
            .keys
            .sorted { $0.uuidString < $1.uuidString }
    }

    var nextDeadline: Date? {
        isHovering ? nil : deadlines.values.min()
    }

    mutating func forget(id: UUID) {
        deadlines[id] = nil
    }
}

@MainActor
final class KeelDownloadShelfController: NSObject {
    var onOpen: ((UUID) -> Void)?
    var onRevealInFinder: ((UUID) -> Void)?
    var onCancel: ((UUID) -> Void)?
    var onDismiss: ((UUID) -> Void)?

    private let shelf = KeelDownloadShelfHoverView()
    private var items: [KeelDownloadShelfItem] = []
    private var cards: [UUID: KeelDownloadCardView] = [:]
    private let now: () -> Date
    private var autoDismiss: KeelDownloadShelfAutoDismiss
    private var autoDismissTask: Task<Void, Never>?
    private var isHovering = false
    private var isKeyboardExpanded = false
    private(set) var isExpanded = false

    var visibleItemIDs: [UUID] {
        isExpanded ? items.map(\.id) : items.prefix(1).map(\.id)
    }

    init(
        now: @escaping () -> Date = Date.init,
        autoDismissDelay: TimeInterval = KeelDownloadShelfAutoDismiss.defaultDelay
    ) {
        self.now = now
        autoDismiss = KeelDownloadShelfAutoDismiss(delay: autoDismissDelay)
        super.init()
        shelf.orientation = .vertical
        shelf.alignment = .leading
        shelf.spacing = 6
        shelf.translatesAutoresizingMaskIntoConstraints = false
        shelf.onHoverChanged = { [weak self] isHovering in
            self?.setHovering(isHovering)
        }
    }

    func attach(to hostView: NSView, contentGuide: NSLayoutGuide? = nil) {
        guard shelf.superview == nil else { return }

        hostView.addSubview(shelf)
        let leading = contentGuide?.leadingAnchor ?? hostView.leadingAnchor
        let bottom = contentGuide?.bottomAnchor ?? hostView.bottomAnchor
        NSLayoutConstraint.activate([
            shelf.leadingAnchor.constraint(equalTo: leading, constant: 16),
            shelf.bottomAnchor.constraint(equalTo: bottom, constant: -16),
            shelf.widthAnchor.constraint(equalToConstant: 320),
        ])
    }

    /// Updates the cards that changed instead of tearing the shelf down. This ran
    /// on every WebKit progress callback and rebuilt every visual effect view,
    /// which flickered and reset hover and focus many times a second.
    func setItems(_ items: [KeelDownloadShelfItem]) {
        self.items = items
        isExpanded = (isHovering || isKeyboardExpanded) && items.count > 1
        syncShelf()
        autoDismiss.track(items: items, at: now())
        rearmAutoDismiss()
    }

    func setExpanded(_ isExpanded: Bool) {
        setHovering(false)
        isKeyboardExpanded = isExpanded
        updateExpansion()
    }

    /// The pointer being over the shelf drives both expansion and the auto-dismiss
    /// hold, so the two can never disagree about where the pointer is.
    func setHovering(_ isHovering: Bool) {
        self.isHovering = isHovering
        autoDismiss.setHovering(isHovering, at: now())
        updateExpansion()
        rearmAutoDismiss()
    }

    /// Drops every card whose delay has run out and asks the host to forget the live
    /// transfer. The durable download record the Downloads screen reads is untouched.
    func performAutoDismiss(at date: Date) {
        let expired = Set(autoDismiss.expired(at: date))
        guard !expired.isEmpty else {
            rearmAutoDismiss()
            return
        }
        for id in expired { autoDismiss.forget(id: id) }
        setItems(items.filter { !expired.contains($0.id) })
        for id in expired.sorted(by: { $0.uuidString < $1.uuidString }) {
            onDismiss?(id)
        }
    }

    var autoDismissDeadline: Date? {
        autoDismiss.nextDeadline
    }

    private func rearmAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        guard let deadline = autoDismiss.nextDeadline else { return }
        let delay = max(0, deadline.timeIntervalSince(now()))
        autoDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.autoDismissTask = nil
            self.performAutoDismiss(at: self.now())
        }
    }

    private func updateExpansion() {
        let nextIsExpanded = (isHovering || isKeyboardExpanded) && items.count > 1
        guard isExpanded != nextIsExpanded else { return }
        isExpanded = nextIsExpanded
        syncShelf()
    }

    private func syncShelf() {
        let visibleItems = isExpanded ? items : Array(items.prefix(1))
        let visibleIDs = Set(visibleItems.map(\.id))

        for (id, card) in cards where !visibleIDs.contains(id) {
            shelf.removeArrangedSubview(card)
            card.removeFromSuperview()
            cards[id] = nil
        }

        for (index, item) in visibleItems.enumerated() {
            let showsExpansion = index == 0 && items.count > 1
            let expansionTitle = isExpanded
                ? "Collapse"
                : "\(items.count) downloads"

            if let card = cards[item.id] {
                card.update(
                    item: item,
                    expansion: showsExpansion ? (title: expansionTitle, isExpanded: isExpanded) : nil
                )
                if shelf.arrangedSubviews.firstIndex(of: card) != index {
                    shelf.removeArrangedSubview(card)
                    shelf.insertArrangedSubview(card, at: index)
                }
            } else {
                let card = KeelDownloadCardView(itemID: item.id)
                card.onOpen = { [weak self] id in self?.onOpen?(id) }
                card.onReveal = { [weak self] id in self?.onRevealInFinder?(id) }
                card.onCancel = { [weak self] id in self?.onCancel?(id) }
                card.onDismiss = { [weak self] id in self?.onDismiss?(id) }
                card.onToggleExpansion = { [weak self] in self?.toggleExpansion() }
                card.update(
                    item: item,
                    expansion: showsExpansion ? (title: expansionTitle, isExpanded: isExpanded) : nil
                )
                cards[item.id] = card
                shelf.insertArrangedSubview(card, at: index)
                card.widthAnchor.constraint(equalTo: shelf.widthAnchor).isActive = true
                if cards.count == 1 {
                    animateShelfIn(card)
                }
            }
        }
    }

    /// M5. Opacity and a small rise; the stack's own layout does the rest.
    private func animateShelfIn(_ card: NSView) {
        guard shelf.window != nil else { return }
        card.wantsLayer = true
        card.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = KeelDesign.Motion.shelfIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            card.animator().alphaValue = 1
        }
        if let layer = card.layer {
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -12
            rise.toValue = 0
            rise.duration = KeelDesign.Motion.shelfIn
            rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(rise, forKey: "keel.shelf.rise")
        }
    }

    private func toggleExpansion() {
        isKeyboardExpanded.toggle()
        if !isKeyboardExpanded {
            setHovering(false)
        }
        updateExpansion()
    }
}

/// One shelf card. Rebuilt once, then updated in place.
@MainActor
private final class KeelDownloadCardView: NSVisualEffectView {
    let itemID: UUID

    var onOpen: ((UUID) -> Void)?
    var onReveal: ((UUID) -> Void)?
    var onCancel: ((UUID) -> Void)?
    var onDismiss: ((UUID) -> Void)?
    var onToggleExpansion: (() -> Void)?

    private let iconView = NSImageView()
    private let filenameField = NSTextField(labelWithString: "")
    private let statusField = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let expansionButton = KeelToolbarButton()
    private let dismissButton = KeelToolbarButton()
    private let openButton = NSButton()
    private let revealButton = NSButton()
    private let cancelButton = NSButton()
    private let actionRow = NSStackView()
    private var currentFilename: String?

    init(itemID: UUID) {
        self.itemID = itemID
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeelDownloadCardView must be created in code")
    }

    func update(item: KeelDownloadShelfItem, expansion: (title: String, isExpanded: Bool)?) {
        if currentFilename != item.filename {
            currentFilename = item.filename
            filenameField.stringValue = item.filename
            iconView.image = Self.documentImage(for: item.filename)
        }

        statusField.stringValue = item.statusLine
        statusField.textColor = Self.statusColor(for: item.state)

        switch item.state {
        case let .receiving(progress):
            progressIndicator.isHidden = false
            progressIndicator.doubleValue = min(max(progress, 0), 1)
            progressIndicator.isIndeterminate = false
        case .waiting:
            progressIndicator.isHidden = false
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
        case .completed, .cancelled, .failed:
            progressIndicator.isIndeterminate = false
            progressIndicator.isHidden = true
        }

        let isRunning = !item.state.isTerminal
        cancelButton.isHidden = !isRunning
        openButton.isHidden = item.state != .completed
        revealButton.isHidden = item.state != .completed
        actionRow.isHidden = openButton.isHidden && cancelButton.isHidden

        if let expansion {
            expansionButton.isHidden = false
            expansionButton.image = NSImage(
                systemSymbolName: expansion.isExpanded ? "chevron.down" : "chevron.up",
                accessibilityDescription: expansion.title
            )?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            expansionButton.toolTip = expansion.title
            expansionButton.setAccessibilityLabel(expansion.title)
        } else {
            expansionButton.isHidden = true
        }

        setAccessibilityLabel("\(item.filename), \(item.statusLine)")
    }

    private func build() {
        material = .underWindowBackground
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.backgroundColor = KeelDesign.NSSurface.raised.cgColor
        layer?.borderColor = KeelDesign.NSSurface.hairline.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        filenameField.font = .systemFont(ofSize: 12, weight: .medium)
        filenameField.lineBreakMode = .byTruncatingMiddle
        filenameField.maximumNumberOfLines = 1
        // Monospaced digits keep the percentage and rate from resizing the card.
        statusField.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        statusField.lineBreakMode = .byTruncatingTail
        statusField.maximumNumberOfLines = 1

        let labels = NSStackView(views: [filenameField, statusField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        configure(expansionButton, symbol: "chevron.up", title: "Show all downloads", action: #selector(toggleExpansionPressed))
        configure(dismissButton, symbol: "xmark", title: "Dismiss", action: #selector(dismissPressed))

        let header = NSStackView(views: [iconView, labels, NSView(), expansionButton, dismissButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.setCustomSpacing(9, after: iconView)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.arrangedSubviews[2].setContentHuggingPriority(.defaultLow, for: .horizontal)

        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.controlSize = .small
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        configure(textButton: openButton, title: "Open", symbol: "arrow.up.forward.app", action: #selector(openPressed))
        configure(textButton: revealButton, title: "Show in Finder", symbol: "folder", action: #selector(revealPressed))
        configure(textButton: cancelButton, title: "Cancel", symbol: "xmark.circle", action: #selector(cancelPressed))

        actionRow.setViews([openButton, revealButton, cancelButton], in: .leading)
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [header, progressIndicator, actionRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            progressIndicator.widthAnchor.constraint(equalTo: content.widthAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    private func configure(_ button: KeelToolbarButton, symbol: String, title: String, action: Selector) {
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        button.imagePosition = .imageOnly
        button.toolTip = title
        button.target = self
        button.action = action
        button.setAccessibilityLabel(title)
    }

    private func configure(textButton button: NSButton, title: String, symbol: String, action: Selector) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        button.imagePosition = .imageLeading
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = .controlAccentColor
        button.target = self
        button.action = action
        button.setAccessibilityLabel(title)
    }

    @objc private func openPressed() { onOpen?(itemID) }
    @objc private func revealPressed() { onReveal?(itemID) }
    @objc private func cancelPressed() { onCancel?(itemID) }
    @objc private func dismissPressed() { onDismiss?(itemID) }
    @objc private func toggleExpansionPressed() { onToggleExpansion?() }

    /// Copies the shared workspace icon before resizing it. Setting `size` on the
    /// returned instance mutates the image every other caller gets.
    private static func documentImage(for filename: String) -> NSImage {
        let fileType = URL(filePath: filename).pathExtension
        let contentType = UTType(filenameExtension: fileType) ?? .data
        guard let copy = NSWorkspace.shared.icon(for: contentType).copy() as? NSImage else {
            return NSWorkspace.shared.icon(for: contentType)
        }
        copy.size = NSSize(width: 22, height: 22)
        return copy
    }

    private static func statusColor(for state: KeelDownloadShelfState) -> NSColor {
        switch state {
        case .completed: KeelDesign.NSSurface.inkSecondary
        case .failed: KeelDesign.NSSurface.danger
        case .cancelled, .waiting, .receiving: KeelDesign.NSSurface.inkSecondary
        }
    }
}

@MainActor
private final class KeelDownloadShelfHoverView: NSStackView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}
