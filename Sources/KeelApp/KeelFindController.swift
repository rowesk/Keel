import AppKit
import KeelUI

@MainActor
final class KeelFindController: NSObject, NSSearchFieldDelegate {
    var onQueryChanged: ((String, Bool) -> Void)?
    var onDismiss: (() -> Void)?

    private let shadowContainer = KeelPanelShadowView()
    private let panel = NSVisualEffectView()
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let previousButton = KeelToolbarButton()
    private let nextButton = KeelToolbarButton()
    private let closeButton = KeelToolbarButton()

    override init() {
        super.init()
        configurePanel()
    }

    var isPresented: Bool {
        shadowContainer.superview != nil
    }

    var currentQuery: String {
        searchField.stringValue
    }

    func present(over hostView: NSView, contentGuide: NSLayoutGuide? = nil) {
        guard !isPresented else {
            hostView.window?.makeFirstResponder(searchField)
            searchField.currentEditor()?.selectAll(nil)
            return
        }

        shadowContainer.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(shadowContainer)
        // Anchored to the content area, not the raw window top, so Cmd+F no
        // longer drops the field on top of the toolbar buttons.
        let top = contentGuide?.topAnchor ?? hostView.topAnchor
        let trailing = contentGuide?.trailingAnchor ?? hostView.trailingAnchor
        NSLayoutConstraint.activate([
            shadowContainer.trailingAnchor.constraint(equalTo: trailing, constant: -16),
            shadowContainer.topAnchor.constraint(equalTo: top, constant: 12),
            shadowContainer.widthAnchor.constraint(equalToConstant: 320),
        ])
        hostView.window?.makeFirstResponder(searchField)
    }

    func dismiss(notify: Bool = true) {
        guard isPresented else { return }
        shadowContainer.removeFromSuperview()
        setStatus(nil)
        if notify {
            onDismiss?()
        }
    }

    /// Reports whether the last search matched. WebKit's find API does not give
    /// a total, so Keel says what it can rather than nothing at all.
    func setMatchFound(_ found: Bool?) {
        guard let found else {
            setStatus(nil)
            return
        }
        setStatus(found ? nil : "No matches")
    }

    private func setStatus(_ text: String?) {
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = text == nil
        statusLabel.textColor = .secondaryLabelColor
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !searchField.stringValue.isEmpty else {
            setStatus(nil)
            return
        }
        onQueryChanged?(searchField.stringValue, false)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector.description {
        case "insertNewline:", "insertLineBreak:":
            onQueryChanged?(searchField.stringValue, NSEvent.modifierFlags.contains(.shift))
            return true
        case "cancelOperation:":
            dismiss()
            return true
        default:
            return false
        }
    }

    func findNext() {
        onQueryChanged?(searchField.stringValue, false)
    }

    func findPrevious() {
        onQueryChanged?(searchField.stringValue, true)
    }

    @objc
    private func findPreviousPressed(_ sender: NSButton) {
        findPrevious()
    }

    @objc
    private func findNextPressed(_ sender: NSButton) {
        findNext()
    }

    @objc
    private func closePressed(_ sender: NSButton) {
        dismiss()
    }

    private func configurePanel() {
        shadowContainer.cornerRadius = 13
        shadowContainer.addSubview(panel)

        panel.material = .underWindowBackground
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 13
        panel.layer?.backgroundColor = KeelDesign.NSSurface.raised.cgColor
        panel.layer?.masksToBounds = true
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = KeelDesign.NSSurface.hairline.cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: shadowContainer.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: shadowContainer.trailingAnchor),
            panel.topAnchor.constraint(equalTo: shadowContainer.topAnchor),
            panel.bottomAnchor.constraint(equalTo: shadowContainer.bottomAnchor),
        ])

        searchField.placeholderString = "Find in page"
        searchField.delegate = self
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 12)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        configure(previousButton, title: "Previous match  ⇧⌘G", symbol: "chevron.up", action: #selector(findPreviousPressed(_:)))
        configure(nextButton, title: "Next match  ⌘G", symbol: "chevron.down", action: #selector(findNextPressed(_:)))
        configure(closeButton, title: "Close find  esc", symbol: "xmark", action: #selector(closePressed(_:)))

        let content = NSStackView(views: [searchField, statusLabel, previousButton, nextButton, closeButton])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 2
        content.setCustomSpacing(6, after: searchField)
        content.setCustomSpacing(6, after: statusLabel)
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -6),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -6),
        ])
    }

    private func configure(_ button: KeelToolbarButton, title: String, symbol: String, action: Selector) {
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        button.imagePosition = .imageOnly
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.target = self
        button.action = action
    }
}
