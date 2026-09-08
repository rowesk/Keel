import AppKit
import KeelUI

@MainActor
struct KeelAddressPaletteSuggestion: Identifiable, Equatable {
    let id: String
    let historyURLID: Int64
    let title: String
    let address: String

    init(id: String, historyURLID: Int64, title: String, address: String) {
        self.id = id
        self.historyURLID = historyURLID
        self.title = title
        self.address = address
    }

    var rowTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? displayAddress : trimmed
    }

    /// The address as a place: no scheme, no `www.`, no lonely trailing slash.
    var displayAddress: String {
        guard let components = URLComponents(string: address), let host = components.host else {
            return address
        }
        var shown = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let port = components.port {
            shown += ":\(port)"
        }
        let path = components.percentEncodedPath
        if !path.isEmpty, path != "/" {
            shown += path
        }
        if let query = components.percentEncodedQuery {
            shown += "?\(query)"
        }
        return shown
    }

    /// Collapses `http`/`https`, `www.`, and a trailing slash so `x.com` and
    /// `https://x.com/` stop appearing as two separate rows.
    var deduplicationKey: String {
        guard var components = URLComponents(string: address) else {
            return address.lowercased()
        }
        components.scheme = nil
        components.fragment = nil
        if let host = components.host, host.hasPrefix("www.") {
            components.host = String(host.dropFirst(4))
        }
        var key = (components.string ?? address).lowercased()
        while key.hasPrefix("/") { key.removeFirst() }
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }
}

@MainActor
enum KeelAddressPaletteSubmission {
    case open(query: String)
    case enqueue(query: String)
    case openSuggestion(KeelAddressPaletteSuggestion, input: String)
    case enqueueSuggestion(KeelAddressPaletteSuggestion, input: String)
}

@MainActor
enum KeelAddressPaletteDefaultSelection {
    case open
    case firstSuggestion
}

/// Whether a submission will open now or join the queue. Keel decides this from
/// coordinator state; the palette only has to say so before the user commits.
@MainActor
enum KeelAddressPaletteMode: Equatable {
    /// Nothing waiting. Return opens the destination.
    case opensNow
    /// Work is already queued, so Return adds to the back of the queue.
    case queuesBehind(count: Int)

    /// Return always opens (a typed phrase searches; an address navigates),
    /// whatever is waiting. The queue is one modifier away, never the default
    /// outcome of pressing Return.
    var primaryTitle: String { "Open" }

    var primarySymbol: String { "arrow.turn.down.left" }

    var secondaryTitle: String? { "Add to queue" }
}

@MainActor
final class KeelAddressPaletteController: NSObject, NSTextFieldDelegate {
    var onQueryChanged: ((String, Int) -> Void)?
    var onSubmit: ((KeelAddressPaletteSubmission) -> Void)?
    var onDismiss: (() -> Void)?

    private enum Selection: Hashable {
        case suggestion(String)
        case open
        case enqueue
    }

    private let backdrop = KeelPaletteBackdropView()
    private let shadowContainer = KeelPanelShadowView()
    /// Opaque, not a visual effect view. `.popover` material blends with the page
    /// behind it, so the palette turned grey over any light grey site.
    private let paletteView = NSView()
    private let queryField = KeelPaletteQueryField()
    private let fieldRow = NSView()
    private let divider = NSBox()
    private let contentStack = NSStackView()
    /// Shown in the embedded resting state only, where the field stands in for
    /// Home's capsule and teaches its own shortcut once.
    private let shortcutHint = NSTextField(labelWithString: "⌘L")
    private var floatingFieldWidth: NSLayoutConstraint?
    private var floatingRowsWidth: NSLayoutConstraint?
    private let queryIcon = NSImageView()
    private let rows = NSStackView()
    /// The panel outlives each presentation, so its layout has to be undone
    /// before the next one. Left active, a docked top from one window size
    /// fought the docked top for the next and AppKit kept the stale one.
    private var presentationConstraints: [NSLayoutConstraint] = []
    private var suggestions: [KeelAddressPaletteSuggestion] = []
    private var selected: Selection = .open
    private var hasReceivedSuggestions = false
    private var orderedSelections: [Selection] = [.open, .enqueue]
    private var suggestionRows: [String: KeelAddressPaletteSuggestionRow] = [:]
    private var actionRows: [Selection: KeelAddressPaletteActionRow] = [:]
    private(set) var queryGeneration = 0
    private var defaultSelection: KeelAddressPaletteDefaultSelection = .open
    private var mode: KeelAddressPaletteMode = .opensNow

    override init() {
        super.init()
        configurePalette()
    }

    var isPresented: Bool {
        backdrop.superview != nil || isEmbeddedActive
    }

    // MARK: Embedded on Home

    /// True while Home hosts the field row as its capsule. The floating
    /// presentation is not used on Home; the field is already on screen.
    private(set) var isEmbedded = false
    /// True while the embedded field is editing and its rows are showing.
    private(set) var isEmbeddedActive = false
    /// Fires when the embedded field activates, deactivates, or its rows
    /// change height, so the SwiftUI host can lay the dropdown out.
    var onEmbeddedChange: (() -> Void)?
    /// Fires when the user clicks into the embedded field, so the app can
    /// route it through the same path as Cmd+L.
    var onEmbeddedFieldFocused: (() -> Void)?

    /// Height the dropdown needs for the current rows, including its padding.
    var embeddedRowsHeight: CGFloat {
        let count = CGFloat(rows.arrangedSubviews.count)
        return count * PaletteRowMetrics.height + max(0, count - 1) + 10
    }

    /// Moves the field row into a Home-owned container. The container should be
    /// 52pt tall and transparent; Home draws the capsule around it.
    func embed(fieldIn container: NSView) {
        if fieldRow.superview === container { return }
        isEmbedded = true
        contentStack.removeArrangedSubview(fieldRow)
        fieldRow.removeFromSuperview()
        container.addSubview(fieldRow)
        NSLayoutConstraint.activate([
            fieldRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fieldRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fieldRow.topAnchor.constraint(equalTo: container.topAnchor),
            fieldRow.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        queryField.font = .systemFont(ofSize: 15, weight: .regular)
        shortcutHint.isHidden = isEmbeddedActive
    }

    /// Moves the suggestion and action rows into Home's dropdown container.
    func embed(rowsIn container: NSView) {
        if rows.superview === container { return }
        contentStack.removeArrangedSubview(rows)
        rows.removeFromSuperview()
        container.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 5),
            rows.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -5),
            rows.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
        ])
        // Labels defer to this width (see the row classes), so nothing inside
        // can push the dropdown wider than the capsule.
    }

    /// Returns the rows to the floating panel. Home calls this when the
    /// dropdown leaves the layout.
    func unembedRows(from container: NSView) {
        guard rows.superview === container else { return }
        rows.removeFromSuperview()
        contentStack.insertArrangedSubview(rows, at: 2)
        floatingRowsWidth?.isActive = true
    }

    /// Returns everything to the floating panel. Home calls this when it goes
    /// off screen. Leaves no dangling active state behind.
    func unembedField(from container: NSView) {
        guard fieldRow.superview === container else { return }
        deactivateEmbedded(notify: false)
        if let rowsContainer = rows.superview, rowsContainer !== contentStack {
            unembedRows(from: rowsContainer)
        }
        fieldRow.removeFromSuperview()
        contentStack.insertArrangedSubview(fieldRow, at: 0)
        floatingFieldWidth?.isActive = true
        queryField.font = .systemFont(ofSize: 17, weight: .regular)
        shortcutHint.isHidden = true
        isEmbedded = false
    }

    /// The embedded equivalent of `present`: focus the field, show the rows.
    func activateEmbedded(initialQuery: String, mode: KeelAddressPaletteMode) {
        guard isEmbedded else { return }
        self.mode = mode
        let wasActive = isEmbeddedActive
        isEmbeddedActive = true
        shortcutHint.isHidden = true
        applyMode()
        updateQuery(initialQuery, selectAll: true, defaultSelection: .open)
        if queryField.currentEditor() == nil {
            fieldRow.window?.makeFirstResponder(queryField)
        }
        queryField.currentEditor()?.selectAll(nil)
        if !wasActive {
            onEmbeddedChange?()
        }
    }

    private func deactivateEmbedded(notify: Bool) {
        guard isEmbeddedActive else { return }
        isEmbeddedActive = false
        invalidateSuggestions()
        shortcutHint.isHidden = false
        if queryField.currentEditor() != nil {
            fieldRow.window?.makeFirstResponder(nil)
        }
        // Resting shows the placeholder, never a half-typed leftover.
        queryField.stringValue = ""
        onEmbeddedChange?()
        if notify {
            onDismiss?()
        }
    }

    private func embeddedRowsDidChange() {
        if isEmbeddedActive {
            onEmbeddedChange?()
        }
    }

    var queryHasEditorForTesting: Bool { queryField.currentEditor() != nil }

    var currentQuery: String {
        queryField.stringValue
    }

    var selectedSuggestionIDForTesting: String? {
        guard case let .suggestion(id) = selected else { return nil }
        return id
    }

    var selectedActionForTesting: String {
        switch selected {
        case .suggestion: "suggestion"
        case .open: "open"
        case .enqueue: "enqueue"
        }
    }

    var visibleSuggestionIDsForTesting: [String] {
        suggestions.map(\.id)
    }

    /// The panel's frame in its backdrop, so layout tests can assert where it
    /// sits without reaching into private views.
    var panelFrameForTesting: NSRect {
        shadowContainer.frame
    }

    var backdropFrameForTesting: NSRect {
        backdrop.frame
    }

    // MARK: Presentation

    /// Just under the priority AppKit uses to keep a resizable window at the
    /// size the user dragged it to.
    static let windowSizeStays = NSLayoutConstraint.Priority(499)

    /// The height of a palette with a couple of suggestions in it. Only decides
    /// where the panel sits, never how tall it is allowed to be.
    static let restingHeight: CGFloat = 200

    func present(
        over hostView: NSView,
        initialQuery: String,
        defaultSelection: KeelAddressPaletteDefaultSelection = .open,
        mode: KeelAddressPaletteMode = .opensNow,
        contentGuide: NSLayoutGuide? = nil
    ) {
        self.defaultSelection = defaultSelection
        self.mode = mode
        guard !isPresented else {
            applyMode()
            updateQuery(initialQuery, selectAll: true, defaultSelection: defaultSelection)
            return
        }

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.onClickOutside = { [weak self] in self?.dismiss() }
        hostView.addSubview(backdrop)
        NSLayoutConstraint.deactivate(presentationConstraints)
        presentationConstraints.removeAll()

        let top = contentGuide?.topAnchor ?? hostView.topAnchor
        let leading = contentGuide?.leadingAnchor ?? hostView.leadingAnchor
        let trailing = contentGuide?.trailingAnchor ?? hostView.trailingAnchor
        let bottom = contentGuide?.bottomAnchor ?? hostView.bottomAnchor
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: top),
            backdrop.leadingAnchor.constraint(equalTo: leading),
            backdrop.trailingAnchor.constraint(equalTo: trailing),
            backdrop.bottomAnchor.constraint(equalTo: bottom),
        ])

        // Sized against the window, not a fixed 640, so a wide window gets a
        // palette that looks deliberate rather than a small box adrift.
        //
        // Everything that reads the window's own size stays below
        // `windowSizeStays`. AppKit holds a resizable window at its current
        // size with a priority-500 constraint, so anything stronger than that
        // resizes the window to fit. At `.defaultHigh` the 720pt cap meant
        // "backdrop no wider than 1385", and every Cmd+L on a wider window
        // snapped it narrower.
        let preferredWidth = shadowContainer.widthAnchor.constraint(
            equalTo: backdrop.widthAnchor,
            multiplier: 0.52
        )
        preferredWidth.priority = Self.windowSizeStays
        let fitsBelowTheTop = shadowContainer.topAnchor.constraint(
            greaterThanOrEqualTo: backdrop.topAnchor,
            constant: 24
        )
        fitsBelowTheTop.priority = Self.windowSizeStays
        let fitsAboveTheBottom = shadowContainer.bottomAnchor.constraint(
            lessThanOrEqualTo: backdrop.bottomAnchor,
            constant: -24
        )
        fitsAboveTheBottom.priority = Self.windowSizeStays
        // Centred on the page area rather than hung 72pt from the top, so it
        // reads as a thing in front of the page instead of a sheet dropping out
        // of the toolbar. Weaker than the two clamps, which take over on a short
        // window rather than letting the panel run off either edge.
        //
        // The top is what gets anchored, not the panel's own centre. Centring
        // the panel moves it up half a row every time a suggestion appears, so
        // the field slides out from under the cursor mid-word. This puts a
        // palette of `restingHeight` in the middle and holds the field still
        // while the list grows downwards.
        let centred = shadowContainer.topAnchor.constraint(
            equalTo: backdrop.centerYAnchor,
            // Negative moves it up: AppKit's anchors read top-down whatever the
            // view's flippedness.
            constant: -Self.restingHeight / 2
        )
        centred.priority = NSLayoutConstraint.Priority(Self.windowSizeStays.rawValue - 1)
        presentationConstraints = [
            shadowContainer.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            centred,
            fitsBelowTheTop,
            preferredWidth,
            shadowContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),
            shadowContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            fitsAboveTheBottom,
        ]
        NSLayoutConstraint.activate(presentationConstraints)

        applyMode()
        updateQuery(initialQuery, selectAll: true, defaultSelection: defaultSelection)
        hostView.window?.makeFirstResponder(queryField)
        queryField.currentEditor()?.selectAll(nil)
        backdrop.alphaValue = 1
    }

    func dismiss(notify: Bool = true) {
        if isEmbeddedActive {
            deactivateEmbedded(notify: notify)
            return
        }
        guard isPresented else { return }
        invalidateSuggestions()
        // Remove synchronously so an old animation cannot remove a reopened panel.
        backdrop.removeFromSuperview()
        if notify {
            onDismiss?()
        }
    }

    // MARK: Content

    func setMode(_ mode: KeelAddressPaletteMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        applyMode()
    }

    private func applyMode() {
        queryField.placeholderString = "Search or enter address"
        rebuildActionRows()
    }

    func setSuggestions(
        _ incoming: [KeelAddressPaletteSuggestion],
        forQueryGeneration queryGeneration: Int,
        defaultSelection: KeelAddressPaletteDefaultSelection? = nil
    ) {
        guard queryGeneration == self.queryGeneration else { return }

        if let defaultSelection {
            self.defaultSelection = defaultSelection
        }

        // The Store dedupes by row id, which leaves `x.com` and `https://x.com/`
        // as two visibly identical rows. Collapsing is the palette's job and it
        // was never implemented.
        let selectedSnapshot: KeelAddressPaletteSuggestion?
        if case let .suggestion(id) = selected {
            selectedSnapshot = suggestions.first { $0.id == id }
        } else {
            selectedSnapshot = nil
        }
        var seenKeys: Set<String> = []
        var seenIDs: Set<String> = []
        var deduplicated: [KeelAddressPaletteSuggestion] = []
        for suggestion in incoming where seenIDs.insert(suggestion.id).inserted && seenKeys.insert(suggestion.deduplicationKey).inserted {
            deduplicated.append(suggestion)
            if deduplicated.count == 6 { break }
        }
        // Keep the exact visible destination the user chose until they type or
        // choose another row. Ranking changes must not replace that destination.
        if let snapshot = selectedSnapshot {
            if let index = deduplicated.firstIndex(where: { $0.id == snapshot.id }) {
                deduplicated[index] = snapshot
            } else {
                deduplicated.removeAll { $0.deduplicationKey == snapshot.deduplicationKey }
                if deduplicated.count == 6 { deduplicated.removeLast() }
                deduplicated.insert(snapshot, at: 0)
            }
        } else if !hasReceivedSuggestions, selected == .open,
                  self.defaultSelection == .firstSuggestion {
            selected = deduplicated.first.map { .suggestion($0.id) } ?? .open
        }
        suggestions = deduplicated
        hasReceivedSuggestions = true
        syncSuggestionRows()
    }

    func replaceSuggestionIcon(
        id: String,
        image: NSImage,
        forQueryGeneration queryGeneration: Int,
        duration: TimeInterval
    ) {
        guard queryGeneration == self.queryGeneration else { return }
        suggestionRows[id]?.setIcon(image, animated: duration > 0, duration: duration)
    }

    func updateQuery(
        _ query: String,
        selectAll: Bool = false,
        defaultSelection: KeelAddressPaletteDefaultSelection = .open
    ) {
        queryField.stringValue = query
        self.defaultSelection = defaultSelection
        selected = .open
        advanceQueryGeneration()
        syncSuggestionRows()
        if selectAll {
            queryField.currentEditor()?.selectAll(nil)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard isEmbeddedActive else { return }
        // Return is consumed before this fires, so this is the click-away
        // case. Let the responder change settle before deciding.
        let generation = queryGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.queryGeneration == generation,
                  self.isEmbeddedActive, self.queryField.currentEditor() == nil else { return }
            self.deactivateEmbedded(notify: true)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        defaultSelection = .open
        selected = .open
        advanceQueryGeneration()
        updateSelectionAppearance()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        performKeyboardCommand(
            commandSelector.description,
            queueModifier: !NSEvent.modifierFlags.intersection([.option, .command]).isEmpty
        )
    }

    func performKeyboardCommandForTesting(_ selector: String, optionKey: Bool = false, commandKey: Bool = false) -> Bool {
        performKeyboardCommand(selector, queueModifier: optionKey || commandKey)
    }

    /// Return opens; Return with ⌘ (or ⌥) queues the same thing instead.
    private func performKeyboardCommand(_ selector: String, queueModifier: Bool) -> Bool {
        switch selector {
        case "moveDown:", "insertTab:":
            moveSelection(by: 1)
            return true
        case "moveUp:", "insertBacktab:":
            moveSelection(by: -1)
            return true
        case "insertNewline:", "insertLineBreak:":
            if queueModifier {
                enqueue(selected)
            } else {
                submit(selected)
            }
            return true
        case "cancelOperation:":
            dismiss()
            return true
        default:
            return false
        }
    }

    // MARK: Construction

    private func configurePalette() {
        backdrop.addSubview(shadowContainer)
        shadowContainer.translatesAutoresizingMaskIntoConstraints = false
        shadowContainer.cornerRadius = 14

        // The material lives inside a plain view that owns the shadow. A shadow
        // set directly on an NSVisualEffectView takes its silhouette from the
        // square backdrop layer, which is where the hard corners came from.
        paletteView.wantsLayer = true
        paletteView.layer?.cornerRadius = 14
        paletteView.layer?.masksToBounds = true
        paletteView.layer?.borderWidth = 1
        paletteView.translatesAutoresizingMaskIntoConstraints = false
        applyPaletteColors()
        shadowContainer.addSubview(paletteView)
        NSLayoutConstraint.activate([
            paletteView.leadingAnchor.constraint(equalTo: shadowContainer.leadingAnchor),
            paletteView.trailingAnchor.constraint(equalTo: shadowContainer.trailingAnchor),
            paletteView.topAnchor.constraint(equalTo: shadowContainer.topAnchor),
            paletteView.bottomAnchor.constraint(equalTo: shadowContainer.bottomAnchor),
        ])

        // An NSSearchField draws its own magnifier inside its text rect once the
        // bezel is removed, so typed text ran straight over the glyph. Keel lays
        // the icon out itself instead.
        queryIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        queryIcon.contentTintColor = .tertiaryLabelColor
        queryIcon.translatesAutoresizingMaskIntoConstraints = false

        queryField.placeholderString = "Search or enter address"
        queryField.delegate = self
        queryField.font = .systemFont(ofSize: 17, weight: .regular)
        queryField.isBezeled = false
        queryField.isBordered = false
        queryField.drawsBackground = false
        queryField.focusRingType = .none
        queryField.lineBreakMode = .byTruncatingTail
        queryField.cell?.usesSingleLineMode = true
        queryField.cell?.wraps = false
        queryField.cell?.isScrollable = true
        queryField.translatesAutoresizingMaskIntoConstraints = false

        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 1
        rows.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        rows.translatesAutoresizingMaskIntoConstraints = false

        fieldRow.translatesAutoresizingMaskIntoConstraints = false
        fieldRow.addSubview(queryIcon)
        fieldRow.addSubview(queryField)
        shortcutHint.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        shortcutHint.textColor = KeelDesign.NSSurface.inkTertiary
        shortcutHint.isHidden = true
        shortcutHint.translatesAutoresizingMaskIntoConstraints = false
        fieldRow.addSubview(shortcutHint)
        queryField.onBecomeFirstResponder = { [weak self] in
            guard let self, self.isEmbedded, !self.isEmbeddedActive else { return }
            self.onEmbeddedFieldFocused?()
        }
        // ⌘↩ never reaches the field editor as a command; it travels as a key
        // equivalent, so the field catches it before the menu bar can.
        queryField.onCommandReturn = { [weak self] in
            guard let self else { return false }
            self.enqueue(self.selected)
            return true
        }
        NSLayoutConstraint.activate([
            queryIcon.leadingAnchor.constraint(equalTo: fieldRow.leadingAnchor, constant: 16),
            queryIcon.centerYAnchor.constraint(equalTo: fieldRow.centerYAnchor),
            queryIcon.widthAnchor.constraint(equalToConstant: 16),
            queryIcon.heightAnchor.constraint(equalToConstant: 16),
            queryField.leadingAnchor.constraint(equalTo: queryIcon.trailingAnchor, constant: 10),
            queryField.trailingAnchor.constraint(equalTo: shortcutHint.leadingAnchor, constant: -8),
            shortcutHint.trailingAnchor.constraint(equalTo: fieldRow.trailingAnchor, constant: -14),
            shortcutHint.centerYAnchor.constraint(equalTo: fieldRow.centerYAnchor),
            queryField.topAnchor.constraint(equalTo: fieldRow.topAnchor, constant: 14),
            queryField.bottomAnchor.constraint(equalTo: fieldRow.bottomAnchor, constant: -14),
        ])

        let bottomInset = NSView()
        bottomInset.translatesAutoresizingMaskIntoConstraints = false
        bottomInset.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let content = contentStack
        for view in [fieldRow, divider, rows, bottomInset] {
            content.addArrangedSubview(view)
        }
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        paletteView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: paletteView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: paletteView.trailingAnchor),
            content.topAnchor.constraint(equalTo: paletteView.topAnchor),
            content.bottomAnchor.constraint(equalTo: paletteView.bottomAnchor),
            divider.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        // Kept so they can be re-activated after the rows come back from Home.
        let fieldWidth = fieldRow.widthAnchor.constraint(equalTo: content.widthAnchor)
        let rowsWidth = rows.widthAnchor.constraint(equalTo: content.widthAnchor)
        NSLayoutConstraint.activate([fieldWidth, rowsWidth])
        floatingFieldWidth = fieldWidth
        floatingRowsWidth = rowsWidth

        rebuildActionRows()
    }

    // MARK: Rows

    /// Reuses existing rows instead of tearing the list down. Rebuilding on every
    /// keystroke made the panel pump open and shut and threw away loaded favicons.
    private func applyPaletteColors() {
        paletteView.effectiveAppearance.performAsCurrentDrawingAppearance {
            paletteView.layer?.backgroundColor = KeelDesign.NSSurface.raised.cgColor
            paletteView.layer?.borderColor = KeelDesign.NSSurface.hairline.cgColor
        }
    }

    private func syncSuggestionRows() {
        let wantedIDs = suggestions.map(\.id)

        for (id, row) in suggestionRows where !wantedIDs.contains(id) {
            rows.removeArrangedSubview(row)
            row.removeFromSuperview()
            suggestionRows[id] = nil
        }

        for (index, suggestion) in suggestions.enumerated() {
            let row: KeelAddressPaletteSuggestionRow
            if let existing = suggestionRows[suggestion.id] {
                existing.update(with: suggestion)
                row = existing
            } else {
                row = KeelAddressPaletteSuggestionRow(suggestion: suggestion)
                row.target = self
                row.action = #selector(selectSuggestionRow(_:))
                row.onHover = { [weak self] id in self?.hoverSelect(.suggestion(id)) }
                suggestionRows[suggestion.id] = row
                rows.insertArrangedSubview(row, at: index)
                row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
                continue
            }
            if rows.arrangedSubviews.firstIndex(of: row) != index {
                rows.removeArrangedSubview(row)
                rows.insertArrangedSubview(row, at: index)
            }
        }

        positionActionRows()
        updateOrderedSelections()
        updateSelectionAppearance()
        embeddedRowsDidChange()
    }

    private func rebuildActionRows() {
        for (_, row) in actionRows {
            rows.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        actionRows.removeAll(keepingCapacity: true)

        let primary = KeelAddressPaletteActionRow(
            title: mode.primaryTitle,
            symbol: mode.primarySymbol,
            trailingHint: "↩",
            accessibilityLabel: mode.primaryTitle
        )
        primary.target = self
        primary.action = #selector(selectActionRow(_:))
        primary.tag = -1
        primary.onHover = { [weak self] in self?.hoverSelect(.open) }
        actionRows[.open] = primary

        if let secondaryTitle = mode.secondaryTitle {
            let secondary = KeelAddressPaletteActionRow(
                title: secondaryTitle,
                symbol: "text.line.last.and.arrowtriangle.forward",
                trailingHint: "⌘↩",
                accessibilityLabel: secondaryTitle
            )
            secondary.target = self
            secondary.action = #selector(selectActionRow(_:))
            secondary.tag = -2
            secondary.onHover = { [weak self] in self?.hoverSelect(.enqueue) }
            actionRows[.enqueue] = secondary
        }

        positionActionRows()
        updateOrderedSelections()
        updateSelectionAppearance()
        embeddedRowsDidChange()
    }

    private func positionActionRows() {
        for selection in [Selection.open, .enqueue] {
            guard let row = actionRows[selection] else { continue }
            if row.superview == nil {
                rows.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            } else {
                rows.removeArrangedSubview(row)
                rows.addArrangedSubview(row)
            }
        }
    }

    private func updateOrderedSelections() {
        var order: [Selection] = suggestions.map { .suggestion($0.id) }
        order.append(.open)
        if actionRows[.enqueue] != nil {
            order.append(.enqueue)
        }
        orderedSelections = order
        if !orderedSelections.contains(selected) {
            selected = .open
        }
    }

    private func hoverSelect(_ selection: Selection) {
        guard selected != selection else { return }
        selected = selection
        updateSelectionAppearance()
    }

    private func moveSelection(by offset: Int) {
        guard !orderedSelections.isEmpty,
              let index = orderedSelections.firstIndex(of: selected)
        else { return }
        let destination = (index + offset + orderedSelections.count) % orderedSelections.count
        selected = orderedSelections[destination]
        updateSelectionAppearance()
    }

    private func updateSelectionAppearance() {
        for (id, row) in suggestionRows {
            row.setSelected(selected == .suggestion(id))
        }
        for (selection, row) in actionRows {
            row.setSelected(selected == selection)
        }
    }

    @objc
    private func selectSuggestionRow(_ sender: KeelAddressPaletteSuggestionRow) {
        selected = .suggestion(sender.suggestionID)
        updateSelectionAppearance()
        submit(selected)
    }

    @objc
    private func selectActionRow(_ sender: NSButton) {
        selected = sender.tag == -1 ? .open : .enqueue
        updateSelectionAppearance()
        submit(selected)
    }

    private func submit(_ selection: Selection) {
        switch selection {
        case let .suggestion(id):
            guard let suggestion = suggestions.first(where: { $0.id == id }) else { return }
            onSubmit?(.openSuggestion(suggestion, input: queryField.stringValue))
        case .open:
            onSubmit?(.open(query: queryField.stringValue))
        case .enqueue:
            onSubmit?(.enqueue(query: queryField.stringValue))
        }
    }

    private func enqueue(_ selection: Selection) {
        switch selection {
        case let .suggestion(id):
            guard let suggestion = suggestions.first(where: { $0.id == id }) else { return }
            onSubmit?(.enqueueSuggestion(suggestion, input: queryField.stringValue))
        case .open, .enqueue:
            onSubmit?(.enqueue(query: queryField.stringValue))
        }
    }

    private func invalidateSuggestions() {
        queryGeneration &+= 1
        suggestions = []
        selected = .open
        hasReceivedSuggestions = false
        syncSuggestionRows()
    }

    private func advanceQueryGeneration() {
        queryGeneration &+= 1
        hasReceivedSuggestions = false
        for row in suggestionRows.values { row.cancelIconAnimation() }
        // The previous list stays on screen until replacements arrive. Clearing
        // it here is what made the panel collapse and reopen on every keystroke.
        onQueryChanged?(queryField.stringValue, queryGeneration)
    }
}

// MARK: - Query field

/// Reports when it takes focus, so a click into Home's capsule opens the
/// palette through the same path as Cmd+L. Deferred a turn so the field
/// editor exists by the time anyone asks it to select all.
@MainActor
private final class KeelPaletteQueryField: NSTextField {
    var onBecomeFirstResponder: (() -> Void)?
    var onCommandReturn: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, event.modifierFlags.contains(.command), currentEditor() != nil,
           let onCommandReturn, onCommandReturn() {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            DispatchQueue.main.async { [weak self] in
                self?.onBecomeFirstResponder?()
            }
        }
        return accepted
    }
}

// MARK: - Backdrop

/// Catches clicks outside the panel so clicking away dismisses the palette.
/// Deliberately invisible: a scrim over the page reads as the whole site going
/// grey. The panel's own shadow is what puts it in front.
@MainActor
final class KeelPaletteBackdropView: NSView {
    var onClickOutside: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeelPaletteBackdropView must be created in code")
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        for subview in subviews where subview.frame.contains(location) {
            super.mouseDown(with: event)
            return
        }
        onClickOutside?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? self
    }
}

/// Owns a two-layer shadow with an explicit path, so the silhouette follows the
/// rounded rect. One heavy shadow with no path is what produced the square edge.
@MainActor
final class KeelPanelShadowView: NSView {
    var cornerRadius: CGFloat = 14 {
        didSet { needsLayout = true }
    }

    private let keyShadowLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        // Tight contact shadow plus a soft near lift. The previous 34pt key
        // shadow spread most of a panel-width in every direction, which reads as
        // a smudge rather than as elevation.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.10
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        keyShadowLayer.shadowColor = NSColor.black.cgColor
        keyShadowLayer.shadowOpacity = 0.16
        keyShadowLayer.shadowRadius = 16
        keyShadowLayer.shadowOffset = CGSize(width: 0, height: -5)
        layer?.insertSublayer(keyShadowLayer, at: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeelPanelShadowView must be created in code")
    }

    override func layout() {
        super.layout()
        let path = CGPath(
            roundedRect: bounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        layer?.shadowPath = path
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        keyShadowLayer.frame = bounds
        keyShadowLayer.shadowPath = path
        CATransaction.commit()
    }
}

// MARK: - Rows

/// One row of the palette. Suggestions and actions share a height, an icon box
/// and a left inset so the list reads as one column.
@MainActor
private enum PaletteRowMetrics {
    static let height: CGFloat = 38
    static let iconBox: CGFloat = 16
    static let leadingInset: CGFloat = 14
    static let iconToText: CGFloat = 10
    static let cornerRadius: CGFloat = 7
    static let horizontalInset: CGFloat = 6
}

@MainActor
private class KeelAddressPaletteRow: NSButton {
    private var trackingArea: NSTrackingArea?
    let highlight = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .inline
        isBordered = false
        title = ""
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = PaletteRowMetrics.cornerRadius
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PaletteRowMetrics.horizontalInset),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PaletteRowMetrics.horizontalInset),
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: PaletteRowMetrics.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// One code path paints selection. The old controller painted it twice with
    /// two different colour intentions, which is why selected rows looked wrong.
    func applySelection(_ isSelected: Bool) {
        highlight.layer?.backgroundColor = isSelected
            ? KeelDesign.NSSurface.selection.cgColor
            : NSColor.clear.cgColor
    }
}

@MainActor
private final class KeelAddressPaletteSuggestionRow: KeelAddressPaletteRow {
    private(set) var suggestionID: String

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private var hasFavicon = false
    private var iconRevision = 0

    var onHover: ((String) -> Void)?

    init(suggestion: KeelAddressPaletteSuggestion) {
        suggestionID = suggestion.id
        super.init(frame: .zero)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // Both labels give way before the panel's width does (the palette
        // sizes itself at priority 499). Left at the defaults, a long title
        // widened the whole palette and the panel flexed on every keystroke.
        // The address yields first, then the title truncates.
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.init(260), for: .horizontal)
        titleField.translatesAutoresizingMaskIntoConstraints = false

        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        subtitleField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleField)
        addSubview(subtitleField)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PaletteRowMetrics.leadingInset),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: PaletteRowMetrics.iconBox),
            iconView.heightAnchor.constraint(equalToConstant: PaletteRowMetrics.iconBox),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: PaletteRowMetrics.iconToText),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -PaletteRowMetrics.leadingInset),

            subtitleField.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 8),
            subtitleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -PaletteRowMetrics.leadingInset),
        ])

        update(with: suggestion)
    }

    func update(with suggestion: KeelAddressPaletteSuggestion) {
        suggestionID = suggestion.id
        if !hasFavicon {
            let host = suggestion.displayAddress.split(separator: "/", maxSplits: 1).first.map(String.init)
                ?? suggestion.displayAddress
            iconView.image = KeelDesign.monogramImage(for: host, size: PaletteRowMetrics.iconBox)
        }
        titleField.stringValue = suggestion.rowTitle
        // A row whose title is already the address does not repeat it underneath.
        subtitleField.stringValue = suggestion.rowTitle == suggestion.displayAddress ? "" : suggestion.displayAddress
        setAccessibilityLabel("Open \(suggestion.rowTitle), \(suggestion.displayAddress)")
    }

    /// Replaces the placeholder in place. The old version stacked a new image
    /// view on top for every result and never removed the previous ones.
    func setIcon(_ image: NSImage, animated: Bool, duration: TimeInterval) {
        iconRevision &+= 1
        let revision = iconRevision
        hasFavicon = true
        image.size = NSSize(width: PaletteRowMetrics.iconBox, height: PaletteRowMetrics.iconBox)
        guard animated else {
            iconView.image = image
            iconView.contentTintColor = nil
            return
        }
        let target = iconView
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration / 2
            target.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                guard self.iconRevision == revision else { return }
                target.image = image
                target.contentTintColor = nil
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = duration / 2
                    target.animator().alphaValue = 1
                }
            }
        }
    }

    func cancelIconAnimation() {
        iconRevision &+= 1
        iconView.layer?.removeAllAnimations()
        iconView.alphaValue = 1
    }

    func setSelected(_ isSelected: Bool) {
        applySelection(isSelected)
        titleField.textColor = .labelColor
        subtitleField.textColor = .secondaryLabelColor
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(suggestionID)
    }
}

@MainActor
private final class KeelAddressPaletteActionRow: KeelAddressPaletteRow {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let hintField = NSTextField(labelWithString: "")

    var onHover: (() -> Void)?

    init(title: String, symbol: String, trailingHint: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        setAccessibilityLabel(accessibilityLabel)

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = title
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        hintField.stringValue = trailingHint
        hintField.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        hintField.textColor = .tertiaryLabelColor
        hintField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(label)
        addSubview(hintField)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PaletteRowMetrics.leadingInset),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: PaletteRowMetrics.iconBox),
            iconView.heightAnchor.constraint(equalToConstant: PaletteRowMetrics.iconBox),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: PaletteRowMetrics.iconToText),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: hintField.leadingAnchor, constant: -8),

            hintField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PaletteRowMetrics.leadingInset),
            hintField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func setSelected(_ isSelected: Bool) {
        applySelection(isSelected)
        label.textColor = .labelColor
        iconView.contentTintColor = isSelected ? KeelDesign.NSSurface.accent : .secondaryLabelColor
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?()
    }
}
