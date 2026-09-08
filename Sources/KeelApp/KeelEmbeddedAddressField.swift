import AppKit
import KeelUI
import SwiftUI

/// What Home needs to know about the embedded palette: whether it is editing,
/// and how tall its dropdown is. The controller drives it; SwiftUI reads it.
@MainActor
final class KeelEmbeddedPaletteState: ObservableObject {
    @Published var isActive = false
    @Published var rowsHeight: CGFloat = 0
}

/// Home's capsule, for real. The address palette's own field row is laid out
/// here at capsule height, wearing the capsule chrome, and its suggestion
/// rows continue on the same paper directly beneath, overlaying whatever Home
/// has stacked underneath. Nothing is positioned by copying coordinates; the
/// field is in the layout, so it follows every resize and scroll for free.
struct KeelEmbeddedAddressField: View {
    @ObservedObject var state: KeelEmbeddedPaletteState
    let palette: KeelAddressPaletteController

    /// The hairline between the field and its rows.
    private static let dividerHeight: CGFloat = 1

    var body: some View {
        KeelPaletteFieldSlot(palette: palette)
            .frame(height: KeelDesign.capsuleHeight)
            .modifier(KeelCapsuleChrome(
                isActive: state.isActive,
                dropdownHeight: Self.dividerHeight + state.rowsHeight
            ))
            .overlay(alignment: .top) {
                if state.isActive {
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(KeelDesign.Surface.hairline)
                            .frame(height: Self.dividerHeight)
                        KeelPaletteRowsSlot(palette: palette)
                            .frame(height: state.rowsHeight)
                    }
                    .offset(y: KeelDesign.capsuleHeight)
                    // Opens on frame one; only the exit fades (M4).
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
                }
            }
            .animation(.easeOut(duration: KeelDesign.Motion.paletteExit), value: state.isActive)
            .accessibilityLabel("Search or enter an address")
    }
}

/// Hosts the palette's field row. Transparent: SwiftUI paints the capsule.
private struct KeelPaletteFieldSlot: NSViewRepresentable {
    let palette: KeelAddressPaletteController

    final class Coordinator {
        let palette: KeelAddressPaletteController
        init(palette: KeelAddressPaletteController) { self.palette = palette }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(palette: palette)
    }

    func makeNSView(context: Context) -> NSView {
        let container = KeelPaletteSlotView()
        palette.embed(fieldIn: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        KeelPaletteSlotView.size(for: proposal)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        MainActor.assumeIsolated {
            coordinator.palette.unembedField(from: nsView)
        }
    }
}

/// Hosts the suggestion and action rows while the field is editing.
private struct KeelPaletteRowsSlot: NSViewRepresentable {
    let palette: KeelAddressPaletteController

    final class Coordinator {
        let palette: KeelAddressPaletteController
        init(palette: KeelAddressPaletteController) { self.palette = palette }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(palette: palette)
    }

    func makeNSView(context: Context) -> NSView {
        let container = KeelPaletteSlotView()
        palette.embed(rowsIn: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        KeelPaletteSlotView.size(for: proposal)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        MainActor.assumeIsolated {
            coordinator.palette.unembedRows(from: nsView)
        }
    }
}

/// A plain, non-opaque container whose size SwiftUI decides. It never reports
/// a size of its own: left to AppKit, a long suggestion title would widen the
/// slot, and the dropdown with it, on every keystroke.
private final class KeelPaletteSlotView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    static func size(for proposal: ProposedViewSize) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
