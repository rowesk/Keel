import SwiftUI

/// A hairline between rows, inset past the row's leading icon so the list reads
/// as a column rather than a stack of full-width bands.
struct KeelRowSeparator: View {
    let leadingInset: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: leadingInset)
            Rectangle()
                .fill(KeelDesign.Surface.hairline)
                .frame(height: 1)
        }
        .frame(height: 1)
        .accessibilityHidden(true)
    }
}
