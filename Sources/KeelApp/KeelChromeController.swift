import AppKit

@MainActor
enum KeelChromeCommand: String, CaseIterable, Hashable {
    case back
    case forward
    case reload
    case reloadFromOrigin
    case showAddressPalette
    /// Cmd+T. The one-page model has no new tab, but the gesture still means
    /// "give me somewhere to type", so it opens the palette.
    case newAddress
    case copyCurrentURL
    case showHome
    /// Cmd+W closes the active page, and hides the window when there is none.
    /// It used to be a dead key on Home.
    case closePage
    case requeueAndClosePage
    case restoreCloseUndo
    case addCurrentURLToQueue
    /// Consumes the oldest queued destination. Nothing sent this before, so a
    /// non-empty queue could never be drained from Home.
    case startQueue
    case findInPage
    case findNext
    case findPrevious
    case printPage
    case zoomIn
    case zoomOut
    case resetZoom
    case showSoleWindow
    case toggleChrome

    var title: String {
        switch self {
        case .back: "Back"
        case .forward: "Forward"
        case .reload: "Reload Page"
        case .reloadFromOrigin: "Reload Ignoring Cache"
        case .showAddressPalette: "Open Address…"
        case .newAddress: "New Address…"
        case .copyCurrentURL: "Copy Address"
        case .showHome: "Home"
        case .closePage: "Close Page"
        case .requeueAndClosePage: "Requeue and Close Page"
        case .restoreCloseUndo: "Reopen Closed Page"
        case .addCurrentURLToQueue: "Add Address to Queue"
        case .startQueue: "Start Queue"
        case .findInPage: "Find…"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .printPage: "Print…"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .resetZoom: "Actual Size"
        case .showSoleWindow: "Show Keel"
        case .toggleChrome: "Hide Browser Chrome"
        }
    }

    var keyEquivalent: String {
        switch self {
        case .back: "["
        case .forward: "]"
        case .reload, .reloadFromOrigin: "r"
        case .showAddressPalette: "l"
        case .newAddress: "t"
        case .copyCurrentURL: "c"
        case .showHome: "h"
        case .closePage, .requeueAndClosePage: "w"
        case .restoreCloseUndo: "t"
        case .addCurrentURLToQueue: "d"
        case .startQueue: "\r"
        case .findInPage: "f"
        case .findNext, .findPrevious: "g"
        case .printPage: "p"
        case .zoomIn: "+"
        case .zoomOut: "-"
        case .resetZoom: "0"
        case .showSoleWindow: "n"
        case .toggleChrome: "t"
        }
    }

    var modifierMask: NSEvent.ModifierFlags {
        switch self {
        case .copyCurrentURL, .showHome, .zoomIn, .reloadFromOrigin,
             .restoreCloseUndo, .findPrevious:
            [.command, .shift]
        case .requeueAndClosePage, .toggleChrome:
            [.command, .option]
        default:
            .command
        }
    }
}

@MainActor
final class KeelChromeController: NSObject, NSToolbarDelegate {
    private enum ItemIdentifier {
        static let navigation = NSToolbarItem.Identifier("com.chrisrowe.keel.navigation")
        static let addressBar = NSToolbarItem.Identifier("com.chrisrowe.keel.address")
        static let queue = NSToolbarItem.Identifier("com.chrisrowe.keel.queue")
        static let home = NSToolbarItem.Identifier("com.chrisrowe.keel.home")
        static let closePage = NSToolbarItem.Identifier("com.chrisrowe.keel.close-page")
    }

    var onCommand: ((KeelChromeCommand) -> Void)?

    private lazy var toolbar = makeToolbar()
    private let addressBar = KeelAddressBarView()
    private let queueButton = KeelQueueBadgeButton()
    private var queueToolbarItem: NSToolbarItem?
    private var buttons: [KeelChromeCommand: NSButton] = [:]
    private var menuItems: [KeelChromeCommand: NSMenuItem] = [:]
    private var policyAvailability: [KeelChromeCommand: Bool] = [:]
    private var canGoBack = false
    private var canGoForward = false
    private var hasActivePage = false
    private var canStartQueue = false
    private var isShowingHome = true
    private var chromeVisible = true

    var addressBarForTesting: KeelAddressBarView { addressBar }

    func install(in window: NSWindow) {
        addressBar.onActivate = { [weak self] in
            self?.perform(.showAddressPalette)
        }
        queueButton.onActivate = { [weak self] in
            self?.perform(.showHome)
        }
        window.toolbar = toolbar
        setVisible(chromeVisible, in: window)
    }

    /// Hiding chrome removes the toolbar and the traffic lights and hands the
    /// full frame to the page. Showing it restores the standard title bar
    /// material, so toolbar glyphs never composite onto page pixels.
    func setVisible(_ isVisible: Bool, in window: NSWindow?) {
        chromeVisible = isVisible
        guard let window else { return }

        window.toolbar?.isVisible = isVisible
        window.titlebarAppearsTransparent = !isVisible
        window.titlebarSeparatorStyle = isVisible ? .line : .none
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = !isVisible
        }
        menuItems[.toggleChrome]?.title = isVisible ? "Hide Browser Chrome" : "Show Browser Chrome"
    }

    // MARK: State

    func updateNavigationAvailability(canGoBack: Bool, canGoForward: Bool) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        updateCommandEnabledStates()
    }

    func updatePageAvailability(hasActivePage: Bool) {
        self.hasActivePage = hasActivePage
        updateCommandEnabledStates()
    }

    func updateSurface(isShowingHome: Bool, queueCount: Int, canStartQueue: Bool) {
        self.isShowingHome = isShowingHome
        self.canStartQueue = canStartQueue
        queueButton.setCount(queueCount)
        // Hiding the view alone is not enough: NSToolbar keeps laying the item
        // out, which left an empty pill in the bar. The item has to go too.
        queueToolbarItem?.isHidden = queueCount == 0
        updateHomeButtonAppearance()
        updateCommandEnabledStates()
    }

    func updateAddress(url: URL?, title: String?, isSecure: Bool) {
        if url == nil {
            addressBar.showEmpty()
        } else {
            addressBar.show(url: url, title: title, isSecure: isSecure)
        }
    }

    func updateAddressFavicon(_ image: NSImage?) {
        addressBar.setFavicon(image)
    }

    func updateLoadingProgress(_ progress: Double?) {
        addressBar.setLoadingProgress(progress)
    }

    func applyCommandPolicy(_ isEnabled: (KeelChromeCommand) -> Bool) {
        policyAvailability = Dictionary(
            uniqueKeysWithValues: KeelChromeCommand.allCases.map { ($0, isEnabled($0)) }
        )
        updateCommandEnabledStates()
    }

    func menuItem(for command: KeelChromeCommand) -> NSMenuItem {
        let item = NSMenuItem(
            title: command.title,
            action: #selector(performCommand(_:)),
            keyEquivalent: command.keyEquivalent
        )
        item.keyEquivalentModifierMask = command.modifierMask
        item.target = self
        item.representedObject = command
        menuItems[command] = item
        return item
    }

    func perform(_ command: KeelChromeCommand) {
        onCommand?(command)
    }

    // MARK: Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        defaultToolbarIdentifiers
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        defaultToolbarIdentifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ItemIdentifier.navigation:
            navigationGroupItem()
        case ItemIdentifier.addressBar:
            addressBarItem()
        case ItemIdentifier.queue:
            queueItem()
        case ItemIdentifier.home:
            toolbarItem(for: .showHome, symbol: "house")
        case ItemIdentifier.closePage:
            toolbarItem(for: .closePage, symbol: "xmark")
        default:
            nil
        }
    }

    private var defaultToolbarIdentifiers: [NSToolbarItem.Identifier] {
        [
            ItemIdentifier.navigation,
            .flexibleSpace,
            ItemIdentifier.addressBar,
            .flexibleSpace,
            ItemIdentifier.queue,
            ItemIdentifier.home,
            ItemIdentifier.closePage,
        ]
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "com.chrisrowe.keel.browser")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        return toolbar
    }

    private func navigationGroupItem() -> NSToolbarItem {
        let back = toolbarButton(for: .back, symbol: "chevron.backward")
        let forward = toolbarButton(for: .forward, symbol: "chevron.forward")
        let reload = toolbarButton(for: .reload, symbol: "arrow.clockwise")
        let stack = NSStackView(views: [back, forward, reload])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let item = NSToolbarItem(itemIdentifier: ItemIdentifier.navigation)
        item.label = "Navigation"
        item.paletteLabel = "Navigation"
        item.view = stack
        return item
    }

    private func addressBarItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemIdentifier.addressBar)
        item.label = "Address"
        item.paletteLabel = "Address"
        item.view = addressBar

        // Wide enough to read a real URL, bounded so it never swallows the bar.
        let preferred = addressBar.widthAnchor.constraint(equalToConstant: 520)
        preferred.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferred,
            addressBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            addressBar.widthAnchor.constraint(lessThanOrEqualToConstant: 680),
            addressBar.heightAnchor.constraint(equalToConstant: 26),
        ])
        return item
    }

    private func queueItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemIdentifier.queue)
        item.label = "Queue"
        item.paletteLabel = "Queue"
        item.view = queueButton
        item.isHidden = queueButton.isHidden
        queueToolbarItem = item
        return item
    }

    private func toolbarItem(for command: KeelChromeCommand, symbol: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier(for: command))
        item.label = command.title
        item.paletteLabel = command.title
        item.toolTip = command.title
        item.view = toolbarButton(for: command, symbol: symbol)
        return item
    }

    private func toolbarButton(for command: KeelChromeCommand, symbol: String) -> NSButton {
        let button = KeelToolbarButton()
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: command.title
        )?.withSymbolConfiguration(.init(pointSize: 12.5, weight: .medium))
        button.imagePosition = .imageOnly
        button.toolTip = shortcutHint(for: command)
        button.target = self
        button.action = #selector(performToolbarCommand(_:))
        button.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
        button.setAccessibilityLabel(command.title)
        buttons[command] = button
        button.isEnabled = isCommandEnabled(command)
        return button
    }

    private func shortcutHint(for command: KeelChromeCommand) -> String {
        var glyphs = ""
        if command.modifierMask.contains(.control) { glyphs += "⌃" }
        if command.modifierMask.contains(.option) { glyphs += "⌥" }
        if command.modifierMask.contains(.shift) { glyphs += "⇧" }
        if command.modifierMask.contains(.command) { glyphs += "⌘" }
        let key = command.keyEquivalent == "\r" ? "↩" : command.keyEquivalent.uppercased()
        return "\(command.title)  \(glyphs)\(key)"
    }

    @objc
    private func performCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? KeelChromeCommand else { return }
        perform(command)
    }

    @objc
    private func performToolbarCommand(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let command = KeelChromeCommand(rawValue: raw)
        else { return }
        perform(command)
    }

    // MARK: Enablement

    private func updateCommandEnabledStates() {
        for command in KeelChromeCommand.allCases {
            let isEnabled = isCommandEnabled(command)
            buttons[command]?.isEnabled = isEnabled
            menuItems[command]?.isEnabled = isEnabled
        }
        menuItems[.closePage]?.title = hasActivePage ? "Close Page" : "Close Window"
        menuItems[.showHome]?.title = isShowingHome && hasActivePage ? "Back to Page" : "Home"
    }

    private func updateHomeButtonAppearance() {
        // The button used to keep the house glyph while it took you away from
        // Home, so it lied about where it would go.
        let showsReturnToPage = isShowingHome && hasActivePage
        let symbol = showsReturnToPage ? "arrow.uturn.forward" : "house"
        let title = showsReturnToPage ? "Back to Page" : "Home"
        buttons[.showHome]?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title
        )?.withSymbolConfiguration(.init(pointSize: 12.5, weight: .medium))
        buttons[.showHome]?.toolTip = "\(title)  ⇧⌘H"
        buttons[.showHome]?.setAccessibilityLabel(title)
        buttons[.closePage]?.toolTip = hasActivePage ? "Close Page  ⌘W" : "Close Window  ⌘W"
    }

    private func isCommandEnabled(_ command: KeelChromeCommand) -> Bool {
        let intrinsicAvailability: Bool = switch command {
        case .back: canGoBack
        case .forward: canGoForward
        case .reload, .reloadFromOrigin, .copyCurrentURL, .addCurrentURLToQueue,
             .findInPage, .findNext, .findPrevious, .printPage,
             .zoomIn, .zoomOut, .resetZoom, .requeueAndClosePage:
            hasActivePage
        case .startQueue: canStartQueue
        default: true
        }
        return intrinsicAvailability && (policyAvailability[command] ?? true)
    }

    private func identifier(for command: KeelChromeCommand) -> NSToolbarItem.Identifier {
        switch command {
        case .showHome: ItemIdentifier.home
        case .closePage: ItemIdentifier.closePage
        default: preconditionFailure("\(command) does not have a toolbar item")
        }
    }
}

/// A borderless toolbar glyph that shows a hover and pressed state. The previous
/// buttons had neither, so an enabled Back and a disabled Back looked the same.
@MainActor
final class KeelToolbarButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .texturedRounded
        wantsLayer = true
        layer?.cornerRadius = 5
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.button)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeelToolbarButton must be created in code")
    }

    override var isEnabled: Bool {
        didSet {
            contentTintColor = isEnabled ? .labelColor : .tertiaryLabelColor
            if !isEnabled { isHovering = false }
            updateBackground()
        }
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
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
        guard isEnabled else { return }
        isHovering = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateBackground()
    }

    private func updateBackground() {
        layer?.backgroundColor = isHovering
            ? NSColor.quaternaryLabelColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
    }
}

/// Shows how many destinations are waiting. The queue count is the number that
/// matters most in Keel and it was previously visible only on Home.
@MainActor
final class KeelQueueBadgeButton: NSControl {
    private let icon = NSImageView()
    private let countLabel = NSTextField(labelWithString: "0")
    private let background = NSView()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var count = 0

    var onActivate: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeelQueueBadgeButton must be created in code")
    }

    func setCount(_ count: Int) {
        self.count = max(0, count)
        countLabel.stringValue = "\(self.count)"
        // Nothing waiting is not worth a control. It reappears the moment it is.
        isHidden = self.count == 0
        toolTip = self.count == 1 ? "1 destination waiting  ⇧⌘H" : "\(self.count) destinations waiting  ⇧⌘H"
        setAccessibilityLabel(self.count == 1 ? "1 destination in queue" : "\(self.count) destinations in queue")
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
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

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        background.wantsLayer = true
        background.layer?.cornerRadius = 5
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        icon.image = NSImage(
            systemSymbolName: "list.bullet",
            accessibilityDescription: "Queue"
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        icon.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, countLabel])
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -7),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])

        setCount(0)
        updateBackground()
    }

    private func updateBackground() {
        background.layer?.backgroundColor = isHovering
            ? NSColor.quaternaryLabelColor.withAlphaComponent(0.28).cgColor
            : NSColor.quaternaryLabelColor.withAlphaComponent(0.15).cgColor
    }
}
