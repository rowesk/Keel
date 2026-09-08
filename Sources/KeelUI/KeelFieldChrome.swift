import SwiftUI

/// The capsule on the lawn: warm paper, control radius, hairline, two-layer
/// shadow. Shared by Home's placeholder button and the embedded address
/// field, so the two are indistinguishable.
///
/// While the field is editing, the same sheet of paper grows downward by
/// `dropdownHeight` to hold the suggestion rows. One shape, not a capsule with
/// a second box hung under it: the join is a hairline, never a gap.
public struct KeelCapsuleChrome: ViewModifier {
    private let isActive: Bool
    private let dropdownHeight: CGFloat

    public init(isActive: Bool, dropdownHeight: CGFloat = 0) {
        self.isActive = isActive
        self.dropdownHeight = dropdownHeight
    }

    private var paperHeight: CGFloat {
        KeelDesign.capsuleHeight + (isActive ? dropdownHeight : 0)
    }

    public func body(content: Content) -> some View {
        content
            // The paper is a background, so it sits under the field's text
            // and can extend past the capsule's own 52pt without moving
            // anything laid out beneath the capsule.
            .background(alignment: .top) {
                RoundedRectangle(cornerRadius: KeelDesign.Radius.control)
                    .fill(KeelDesign.Surface.raised.opacity(isActive ? 0.97 : 0.94))
                    .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                    .shadow(color: .black.opacity(isActive ? 0.28 : 0.22), radius: isActive ? 26 : 22, y: isActive ? 12 : 9)
                    .overlay(
                        RoundedRectangle(cornerRadius: KeelDesign.Radius.control)
                            .strokeBorder(
                                KeelDesign.Surface.ink.opacity(isActive ? 0.18 : 0.08),
                                lineWidth: 1
                            )
                    )
                    .frame(height: paperHeight)
            }
    }
}

public extension KeelDesign {
    /// Home's capsule height. The embedded field and the placeholder button
    /// both use it; the dropdown continues the same paper directly beneath.
    static let capsuleHeight: CGFloat = 52
}
