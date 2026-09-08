import AppKit
import Foundation
import KeelUI

/// What went wrong, in words, with a way out.
///
/// A failed navigation used to leave a blank web view and nothing else: no
/// message, no code, no retry. Keel draws this itself rather than loading an
/// error document, so a failure never enters the page's back-forward list.
@MainActor
public final class KeelPageErrorView: NSView {
    public var onRetry: (() -> Void)?
    public var onCloseAndContinue: (() -> Void)?
    public var onGoHome: (() -> Void)?
    public var onCloseDetour: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton()
    private let closeAndContinueButton = NSButton()
    private let goHomeButton = NSButton()
    private let closeDetourButton = NSButton()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeelPageErrorView must be created in code")
    }

    public func present(failure: KeelPageFailure, exits: KeelPageErrorExits = .activePage) {
        retryButton.isHidden = !exits.contains(.retry)
        closeAndContinueButton.isHidden = !exits.contains(.closeAndContinue)
        goHomeButton.isHidden = !exits.contains(.goHome)
        closeDetourButton.isHidden = !exits.contains(.closeDetour)

        iconView.image = NSImage(
            systemSymbolName: failure.symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 34, weight: .light))
        iconView.contentTintColor = failure.isSecurityFailure ? KeelDesign.NSSurface.danger : KeelDesign.NSSurface.inkTertiary

        titleLabel.stringValue = failure.title
        messageLabel.stringValue = failure.message
        detailLabel.stringValue = failure.detail
        detailLabel.isHidden = failure.detail.isEmpty

        setAccessibilityLabel("\(failure.title). \(failure.message)")
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = KeelDesign.NSSurface.canvas.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // The serif is Riva's print voice for titles; the body stays sans.
        let serif = NSFont.systemFont(ofSize: 19, weight: .medium).fontDescriptor.withDesign(.serif)
        titleLabel.font = serif.flatMap { NSFont(descriptor: $0, size: 19) } ?? .systemFont(ofSize: 19, weight: .medium)
        titleLabel.textColor = KeelDesign.NSSurface.ink
        titleLabel.alignment = .center
        // A long hostname has to wrap. It was being clipped mid-word.
        titleLabel.preferredMaxLayoutWidth = 380
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = KeelDesign.NSSurface.inkSecondary
        messageLabel.alignment = .center
        messageLabel.preferredMaxLayoutWidth = 380

        detailLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        detailLabel.textColor = KeelDesign.NSSurface.inkTertiary
        detailLabel.alignment = .center

        retryButton.title = "Try Again"
        retryButton.bezelStyle = .rounded
        retryButton.bezelColor = KeelDesign.NSSurface.accentFill
        retryButton.keyEquivalent = "\r"
        retryButton.target = self
        retryButton.action = #selector(retryPressed)

        // ADR 0013 keeps the failed page in the active-page position until the
        // user closes it, so closing has to be offered here and not only in a menu.
        closeAndContinueButton.title = "Close and Continue"
        closeAndContinueButton.bezelStyle = .rounded
        closeAndContinueButton.target = self
        closeAndContinueButton.action = #selector(closeAndContinuePressed)

        goHomeButton.title = "Go to Keel Home"
        goHomeButton.bezelStyle = .rounded
        goHomeButton.target = self
        goHomeButton.action = #selector(goHomePressed)

        // A detour closes back to the page that opened it. It cannot advance the
        // queue or leave for Keel Home, so it gets a plain Close instead.
        closeDetourButton.title = "Close"
        closeDetourButton.bezelStyle = .rounded
        closeDetourButton.target = self
        closeDetourButton.action = #selector(closeDetourPressed)

        closeDetourButton.isHidden = true

        let buttons = NSStackView(views: [retryButton, closeAndContinueButton, goHomeButton, closeDetourButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [iconView, titleLabel, messageLabel, detailLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: iconView)
        stack.setCustomSpacing(6, after: titleLabel)
        stack.setCustomSpacing(18, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -24),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            iconView.widthAnchor.constraint(equalToConstant: 44),
            iconView.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @objc private func retryPressed() { onRetry?() }
    @objc private func closeAndContinuePressed() { onCloseAndContinue?() }
    @objc private func goHomePressed() { onGoHome?() }
    @objc private func closeDetourPressed() { onCloseDetour?() }

    func visibleExitTitlesForTesting() -> [String] {
        [retryButton, closeAndContinueButton, goHomeButton, closeDetourButton]
            .filter { !$0.isHidden }
            .map(\.title)
    }
}

/// The ways out a failure offers. They differ by what failed: the active page can
/// advance the queue or leave for Keel Home, a detour can only go back to the page
/// underneath it.
public struct KeelPageErrorExits: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let retry = Self(rawValue: 1 << 0)
    public static let closeAndContinue = Self(rawValue: 1 << 1)
    public static let goHome = Self(rawValue: 1 << 2)
    public static let closeDetour = Self(rawValue: 1 << 3)

    public static let activePage: Self = [.retry, .closeAndContinue, .goHome]
    public static let transactionalDetour: Self = [.retry, .closeDetour]
}

/// A navigation failure translated out of `NSURLError` codes into something a
/// person can act on.
public struct KeelPageFailure: Equatable, Sendable {
    public let host: String
    public let code: Int
    public let underlyingDescription: String

    public init(host: String, code: Int, underlyingDescription: String) {
        self.host = host
        self.code = code
        self.underlyingDescription = underlyingDescription
    }

    public var isSecurityFailure: Bool {
        [
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid,
            NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired,
            NSURLErrorSecureConnectionFailed,
        ].contains(code)
    }

    public var symbolName: String {
        if isSecurityFailure { return "lock.trianglebadge.exclamationmark" }
        switch code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "wifi.slash"
        case NSURLErrorTimedOut:
            return "clock.badge.exclamationmark"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "questionmark.circle"
        default:
            return "exclamationmark.triangle"
        }
    }

    public var title: String {
        if isSecurityFailure { return "This connection is not private" }
        switch code {
        case NSURLErrorNotConnectedToInternet:
            return "You are offline"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Cannot find \(displayHost)"
        case NSURLErrorTimedOut:
            return "\(displayHost) took too long"
        case NSURLErrorCannotConnectToHost:
            return "Cannot reach \(displayHost)"
        case NSURLErrorNetworkConnectionLost:
            return "The connection dropped"
        case Self.webContentProcessTerminated:
            return "This page stopped responding"
        default:
            return "Keel could not load \(displayHost)"
        }
    }

    public var message: String {
        if isSecurityFailure {
            return "\(displayHost) presented a certificate Keel could not verify, so Keel stopped before sending anything."
        }
        switch code {
        case NSURLErrorNotConnectedToInternet:
            return "Check your network connection, then try again."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Check the address for a typo. If it is right, the site's DNS may be down."
        case NSURLErrorTimedOut:
            return "The server accepted the connection but never finished replying."
        case NSURLErrorCannotConnectToHost:
            return "The server refused the connection. It may be down or blocking this network."
        case NSURLErrorNetworkConnectionLost:
            return "The network went away partway through loading."
        case Self.webContentProcessTerminated:
            return "The page's web content process ended. Reloading usually recovers it."
        default:
            return underlyingDescription
        }
    }

    public var detail: String {
        code == Self.webContentProcessTerminated ? "" : "Error \(code)"
    }

    /// Not an `NSURLError`. Keel uses it for a terminated web content process so
    /// a crash and a network failure get different words.
    public static let webContentProcessTerminated = -9001

    private var displayHost: String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
