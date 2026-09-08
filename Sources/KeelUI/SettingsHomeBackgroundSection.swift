import SwiftUI
import UniformTypeIdentifiers

/// The scene library, as Settings shows it: a mode picker and a grid of
/// photographs. Split out of `SettingsView` because the tile, its badges and
/// the drop target together are more view than the rest of that file's
/// sections put together.
struct SettingsHomeBackgroundSection: View {
    let model: KeelSettingsModel
    let actions: KeelSettingsActions
    @Binding var mode: KeelHomeSceneMode
    /// Removal goes back up to `SettingsView`, which owns the one confirmation
    /// dialog every destructive act on this screen shares.
    let onRequestRemoval: (KeelHomeSceneID, String) -> Void

    @State private var hoveredID: KeelHomeSceneID?
    @State private var isDropTargeted = false

    /// Wide enough that a 16:9 tile shows what the photograph is, narrow
    /// enough that the readable column fits four across.
    private static let tileWidth: CGFloat = 120
    private static let tileHeight: CGFloat = tileWidth * 9 / 16

    var body: some View {
        Picker("Show", selection: $mode) {
            ForEach(KeelHomeSceneMode.allCases) { option in
                Text(option.label).tag(option)
            }
        }

        grid
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Self.tileWidth), spacing: KeelDesign.Space.regular, alignment: .leading)],
            alignment: .leading,
            spacing: KeelDesign.Space.regular
        ) {
            ForEach(model.homeScenes) { tile in
                sceneTile(tile)
            }
            addTile
        }
        .padding(.vertical, KeelDesign.Space.tight)
        .overlay(dropHighlight)
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
            receive(providers)
        }
    }

    @ViewBuilder
    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: KeelDesign.Radius.card)
            .strokeBorder(KeelDesign.Surface.accent, lineWidth: 1)
            .opacity(isDropTargeted ? 1 : 0)
            .allowsHitTesting(false)
    }

    // MARK: Tiles

    private func sceneTile(_ tile: KeelHomeSceneTile) -> some View {
        VStack(alignment: .leading, spacing: KeelDesign.Space.tight) {
            Button {
                if mode == .onePhoto {
                    actions.perform(.selectHomeScene(tile.id))
                }
            } label: {
                thumbnail(tile)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel(for: tile))

            Text(tile.name)
                .font(KeelDesign.Text.detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.tileWidth, alignment: .leading)
        }
        .opacity(isInPlay(tile) ? 1 : 0.45)
        .onHover { hovering in
            hoveredID = hovering ? tile.id : (hoveredID == tile.id ? nil : hoveredID)
        }
    }

    private func thumbnail(_ tile: KeelHomeSceneTile) -> some View {
        RoundedRectangle(cornerRadius: KeelDesign.Radius.card)
            .fill(KeelDesign.Surface.rowSelected)
            .frame(width: Self.tileWidth, height: Self.tileHeight)
            .overlay {
                if let thumbnail = tile.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: Self.tileWidth, height: Self.tileHeight)
                        .clipShape(RoundedRectangle(cornerRadius: KeelDesign.Radius.card))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: KeelDesign.Radius.card)
                    .strokeBorder(
                        isSelected(tile) ? KeelDesign.Surface.accent : KeelDesign.Surface.hairline,
                        lineWidth: isSelected(tile) ? 2 : 1
                    )
            }
            .overlay {
                // A paper ring outside the accent, so the selection still
                // reads when the photograph itself is loden green.
                if isSelected(tile) {
                    RoundedRectangle(cornerRadius: KeelDesign.Radius.card + 2)
                        .strokeBorder(KeelDesign.Surface.raised, lineWidth: 2)
                        .padding(-2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelected(tile) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        // Palette rendering, so the badge reads on a dark
                        // photograph as well as a pale one.
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(KeelDesign.Surface.onAccent, KeelDesign.Surface.accent)
                        .background(Circle().fill(KeelDesign.Surface.raised).padding(-1.5))
                        .padding(KeelDesign.Space.tight)
                }
            }
            .overlay(alignment: .topTrailing) { removeButton(tile) }
            .contentShape(RoundedRectangle(cornerRadius: KeelDesign.Radius.card))
    }

    /// The ✕ keeps its 20pt whether or not it is drawn, so a tile does not
    /// change size under the pointer.
    @ViewBuilder
    private func removeButton(_ tile: KeelHomeSceneTile) -> some View {
        Color.clear
            .frame(width: 20, height: 20)
            .overlay {
                if !tile.isBundled, hoveredID == tile.id {
                    Button {
                        onRequestRemoval(tile.id, tile.name)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(KeelDesign.Surface.scrimText, KeelDesign.Surface.ink.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(tile.name)")
                }
            }
            .padding(KeelDesign.Space.hair)
    }

    private var addTile: some View {
        VStack(alignment: .leading, spacing: KeelDesign.Space.tight) {
            Button {
                actions.perform(.addHomeScenes)
            } label: {
                RoundedRectangle(cornerRadius: KeelDesign.Radius.card)
                    .strokeBorder(
                        KeelDesign.Surface.hairline,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                    .frame(width: Self.tileWidth, height: Self.tileHeight)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(KeelDesign.Surface.inkSecondary)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: KeelDesign.Radius.card))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add photos")

            Text("Add photos…")
                .font(KeelDesign.Text.detail)
                .foregroundStyle(.secondary)
                .frame(width: Self.tileWidth, alignment: .leading)
        }
    }

    // MARK: State

    private func isSelected(_ tile: KeelHomeSceneTile) -> Bool {
        mode == .onePhoto && model.selectedHomeSceneID == tile.id
    }

    /// Which tiles the mode will actually show. In `rotateMine` with nothing
    /// imported, rotation falls back to everything, and the grid says so
    /// rather than dimming the whole library.
    private func isInPlay(_ tile: KeelHomeSceneTile) -> Bool {
        switch mode {
        case .onePhoto:
            true
        case .rotateAll:
            true
        case .rotateMine:
            model.hasUserHomeScenes ? !tile.isBundled : true
        }
    }

    private func accessibilityLabel(for tile: KeelHomeSceneTile) -> String {
        if mode == .onePhoto {
            return isSelected(tile) ? "\(tile.name), selected" : tile.name
        }
        return isInPlay(tile) ? "\(tile.name), in rotation" : tile.name
    }

    // MARK: Drop

    private func receive(_ providers: [NSItemProvider]) -> Bool {
        let candidates = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !candidates.isEmpty else { return false }

        let collected = KeelDroppedURLs()
        let group = DispatchGroup()
        for provider in candidates {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { collected.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = collected.take()
            guard !urls.isEmpty else { return }
            actions.perform(.importHomeScenes(urls))
        }
        return true
    }
}

/// `loadObject` calls back on an arbitrary queue, so the URLs land here under
/// a lock before the main queue reads them once.
private final class KeelDroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func take() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}
