import Foundation

/// Where Home's capsule sits, in the content area's top-down coordinates.
/// The address palette docks onto this frame so opening it reads as the
/// capsule becoming editable, not a second field appearing above the first.
@MainActor
public final class KeelHomeCapsuleAnchor {
    public private(set) var frame: CGRect?

    public init() {}

    public func update(_ frame: CGRect?) {
        guard self.frame != frame else { return }
        self.frame = frame
    }
}
