import SwiftUI

/// Home is the reward for an empty queue: the Como scene, the wordmark, one
/// field. Work rests on the bottom edge as one line of type that opens into
/// a sheet; the field itself never moves, whatever arrives or leaves.
public struct HomeView: View {
    private let model: KeelHomeModel
    private let actions: KeelHomeActions
    private let addressField: AnyView?
    private let capsuleAnchor: KeelHomeCapsuleAnchor?
    private let scene: KeelHomeSceneDisplay
    private let queueInitiallyExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - addressField: The live address field to place where the capsule
    ///     goes. The app supplies the palette's own field; previews and
    ///     snapshots leave it nil and get a look-alike button.
    ///   - capsuleAnchor: Receives the capsule's frame for layout tests.
    ///   - scene: The photograph behind Home and the luminance its scrim is
    ///     sized from. Defaults to Como.
    public init(
        model: KeelHomeModel = KeelHomeModel(),
        actions: KeelHomeActions = KeelHomeActions(),
        addressField: AnyView? = nil,
        capsuleAnchor: KeelHomeCapsuleAnchor? = nil,
        scene: KeelHomeSceneDisplay = .como,
        queueInitiallyExpanded: Bool = false
    ) {
        self.model = model
        self.actions = actions
        self.addressField = addressField
        self.capsuleAnchor = capsuleAnchor
        self.scene = scene
        self.queueInitiallyExpanded = queueInitiallyExpanded
    }

    private var hasWork: Bool {
        model.resume != nil || model.undo != nil || model.hasVisibleQueue || model.queueDeletionUndo != nil
    }

    /// The capsule's top edge as a fraction of the content height. Fixed, so
    /// nothing above or below it can push it around. Low enough that the
    /// wordmark has the upper third to itself and the deck has the lower.
    public static let capsuleTopFraction: CGFloat = 0.47
    /// Where the wordmark's centre sits, as a fraction of the content height.
    public static let wordmarkCentreFraction: CGFloat = 0.20
    private static let headerHeight: CGFloat = 44
    private static let statusLineHeight: CGFloat = 18
    private static let deckGap: CGFloat = 20

    public var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let capsuleTop = height * Self.capsuleTopFraction
            let wordmarkCentre = height * Self.wordmarkCentreFraction
            let deckTop = capsuleTop + KeelDesign.capsuleHeight + KeelDesign.Space.regular
                + Self.statusLineHeight + Self.deckGap
            let deckMaxHeight = max(120, height - deckTop)

            ZStack(alignment: .top) {
                // The scene runs under the hidden title bar; without this the
                // safe area shows as a black band once the chrome is hidden.
                HomeSceneView(scene: scene)
                    .ignoresSafeArea()

                HomeHeaderView(actions: actions)
                    .frame(height: Self.headerHeight)
                    .frame(maxWidth: .infinity)

                // The wordmark is placed on its own, so neither the header nor
                // the capsule can nudge it.
                Text("Keel")
                    .font(KeelDesign.wordmarkFont(size: max(54, min(84, geometry.size.width * 0.055))))
                    .foregroundStyle(KeelDesign.Surface.scrimText)
                    .shadow(color: .black.opacity(0.28), radius: 14, y: 1)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(0, wordmarkCentre * 2))

                VStack(spacing: 0) {
                    Color.clear.frame(height: capsuleTop)

                    VStack(spacing: KeelDesign.Space.regular) {
                        capsule
                            // Reports where the capsule sits for layout tests.
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .global)
                            } action: { frame in
                                capsuleAnchor?.update(frame)
                            }
                            // The dropdown hangs over whatever is below.
                            .zIndex(1)

                        Text(statusLine)
                            .font(KeelDesign.Text.body)
                            .foregroundStyle(KeelDesign.Surface.scrimText)
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color(red: 0.10, green: 0.12, blue: 0.08).opacity(0.78), in: Capsule())
                            .frame(height: Self.statusLineHeight)
                            .accessibilityLabel(statusLine)
                    }
                    .frame(maxWidth: 560)
                    .padding(.horizontal, KeelDesign.Space.loose)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .zIndex(1)

                // The ledger rests on the bottom edge and its sheet rises
                // toward the status line, never past it. It is laid out apart
                // from the capsule so neither can move the other.
                if hasWork {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        HomeQueueView(model: model, actions: actions, maxHeight: deckMaxHeight, initiallyExpanded: queueInitiallyExpanded)
                            .frame(maxWidth: 560)
                            .padding(.horizontal, KeelDesign.Space.loose)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: reduceMotion ? 0.15 : KeelDesign.Motion.queueEnter), value: hasWork)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keel Home")
    }

    @ViewBuilder
    private var capsule: some View {
        if let addressField {
            addressField
        } else {
            HomeAddressButton(actions: actions, queueIsHolding: model.queueIsHolding)
        }
    }

    /// One sentence, never a badge. States what the scene cannot show.
    private var statusLine: String {
        if model.resume != nil {
            let count = model.queue.count
            if count == 0 {
                return "One page is unfinished."
            }
            return "One page is unfinished · \(count == 1 ? "one more waits" : "\(count) more wait") behind it."
        }
        if let next = model.queue.first {
            let count = model.queue.count
            if count == 1 {
                return "One page waiting · \(next.primaryText) is next."
            }
            return "\(Self.spelled(count)) pages waiting · \(next.primaryText) is next."
        }
        return "Nothing is waiting."
    }

    private static func spelled(_ count: Int) -> String {
        let words = ["Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"]
        guard count >= 2, count <= 9 else { return "\(count)" }
        return words[count - 2]
    }
}

/// The scene itself. Static, always: motion here is the fastest way to turn
/// the view into a screensaver. Two gradients keep type legible at the top
/// and bottom without greying the water.
struct HomeSceneView: View {
    var scene: KeelHomeSceneDisplay = .como

    var body: some View {
        GeometryReader { geometry in
            let scrim = KeelHomeSceneGradient.opacities(
                topLuminance: scene.topLuminance,
                bottomLuminance: scene.bottomLuminance
            )
            let topOpacity = KeelHomeSceneGradient.displayedTopOpacity(
                image: scene.image ?? KeelDesign.homeScene,
                viewport: geometry.size,
                fallbackLuminance: scene.topLuminance
            )
            ZStack {
                if let image = scene.image ?? KeelDesign.homeScene {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    // The photograph should always be in the bundle. If it is
                    // not, hold the dark ground rather than flashing white.
                    KeelDesign.Surface.dynamic(light: 0x5B6352, dark: 0x1C2018)
                }

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(topOpacity), location: 0),
                        .init(color: .black.opacity(topOpacity), location: 0.26),
                        .init(color: .clear, location: 0.43),
                        .init(color: .clear, location: 0.55),
                        .init(color: .black.opacity(scrim.bottom), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview("Home, queue holding") {
    HomeView(
        model: KeelHomeModel(
            resume: KeelResumeItem(
                displayURL: "https://docs.example.test/project/spec",
                hostname: "docs.example.test",
                title: "Project specification",
                savedAt: Date.now.addingTimeInterval(-420)
            ),
            undo: KeelUndoItem(
                displayURL: "https://mail.example.test/inbox",
                hostname: "mail.example.test",
                title: "Inbox",
                deadline: Date.now.addingTimeInterval(480)
            ),
            queue: KeelHomeModel.fixture(count: 12).queue,
            queueDeletionUndo: KeelQueueDeletionUndoItem(deletedCount: 2, deadline: Date.now.addingTimeInterval(50))
        )
    )
    .frame(width: 1120, height: 760)
}

#Preview("Home, empty") {
    HomeView(model: KeelHomeModel())
        .frame(width: 1120, height: 720)
}
