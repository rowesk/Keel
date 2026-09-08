import AppKit
import KeelUI
import KeelWeb

/// Favicons for Keel's own screens: the queue, History, Undo and Resume.
///
/// The palette has its own loader because that one is generation-scoped and
/// cancels its previous batch. Home and History want the opposite: a small
/// cache that accumulates and never cancels, so a row keeps its icon while the
/// user scrolls. Every row that is not a favicon looked identical before this.
@MainActor
final class KeelNativeScreenFaviconCache {
    private let loader: KeelFaviconLoader
    private let onUpdated: () -> Void
    private var iconsByOrigin: [String: KeelIconImage] = [:]
    private var requestedOrigins: Set<String> = []
    private var pendingOrigins: [String: URL] = [:]
    private var flushTask: Task<Void, Never>?
    private var generation = 0

    init(
        loader: KeelFaviconLoader = KeelFaviconLoader(),
        onUpdated: @escaping () -> Void
    ) {
        self.loader = loader
        self.onUpdated = onUpdated
    }

    deinit {
        flushTask?.cancel()
    }

    /// Returns a cached icon, and schedules a fetch the first time an origin is
    /// asked for. Returns nil until the icon lands, so rows render immediately.
    func icon(for url: URL?) -> KeelIconImage? {
        guard let url, let key = Self.originKey(for: url) else { return nil }
        if let cached = iconsByOrigin[key] { return cached }
        guard !requestedOrigins.contains(key) else { return nil }
        pendingOrigins[key] = url
        scheduleFlush()
        return nil
    }

    func icon(forAddress address: String?) -> KeelIconImage? {
        guard let address, let url = URL(string: address) else { return nil }
        return icon(for: url)
    }

    /// Batches origins discovered during one render pass into a single load, so
    /// building a 40-row History list does not start 40 separate fetches.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flush()
        }
    }

    private func flush() {
        let batch = pendingOrigins
        pendingOrigins.removeAll(keepingCapacity: true)
        guard !batch.isEmpty else { return }
        for key in batch.keys {
            requestedOrigins.insert(key)
        }

        generation &+= 1
        let requests = batch.map { KeelFaviconRequest(id: $0.key, pageURL: $0.value) }
        loader.load(for: requests, generation: generation) { [weak self] results in
            guard let self, !results.isEmpty else { return }
            for result in results {
                let sized = result.image.copy() as? NSImage ?? result.image
                sized.size = NSSize(width: 32, height: 32)
                self.iconsByOrigin[result.id] = KeelIconImage(sized)
            }
            self.onUpdated()
        }
    }

    /// One icon per scheme, host and port. Two pages on the same site share it.
    private static func originKey(for url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let scheme = url.scheme?.lowercased() ?? "https"
        guard scheme == "http" || scheme == "https" else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}
