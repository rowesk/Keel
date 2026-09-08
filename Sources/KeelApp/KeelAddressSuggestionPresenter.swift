import AppKit
import KeelCoordinator
import KeelStore
import KeelWeb

/// Owns the asynchronous parts of palette suggestions. The palette only renders rows
/// and reports keys or clicks, so a late Store or favicon result cannot alter its input.
@MainActor
final class KeelAddressSuggestionPresenter {
    typealias SuggestionLookup = @MainActor @Sendable (String) async throws -> [HistorySuggestion]

    var onSuggestions: (([KeelAddressPaletteSuggestion], Int, KeelAddressPaletteDefaultSelection) -> Void)?
    var onFavicon: ((String, NSImage, Int, TimeInterval) -> Void)?
    var onSuggestionAccepted: ((KeelCoordinatorEvent) -> Void)?

    private let lookup: SuggestionLookup
    private let faviconLoader: KeelFaviconLoader?
    private let stableListDelay: Duration
    private var queryTask: Task<Void, Never>?
    private var activeGeneration: Int?

    convenience init(store: KeelStore, faviconLoader: KeelFaviconLoader) {
        self.init(
            lookup: { input in
                try await store.addressSuggestions(for: input, limit: 6).suggestions
            },
            faviconLoader: faviconLoader
        )
    }

    init(
        lookup: @escaping SuggestionLookup,
        faviconLoader: KeelFaviconLoader? = nil,
        stableListDelay: Duration = .milliseconds(180)
    ) {
        self.lookup = lookup
        self.faviconLoader = faviconLoader
        self.stableListDelay = stableListDelay
    }

    deinit {
        queryTask?.cancel()
    }

    func queryDidChange(_ query: String, generation: Int) {
        queryTask?.cancel()
        if let activeGeneration {
            faviconLoader?.cancel(generation: activeGeneration)
        }
        activeGeneration = generation

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onSuggestions?([], generation, .open)
            return
        }

        let lookup = self.lookup
        queryTask = Task { @MainActor [weak self] in
            let historySuggestions: [HistorySuggestion]
            do {
                historySuggestions = try await lookup(query)
            } catch is CancellationError {
                return
            } catch {
                historySuggestions = []
            }

            guard let self,
                  !Task.isCancelled,
                  self.activeGeneration == generation
            else {
                return
            }

            let rows = historySuggestions.map(Self.paletteSuggestion)
            self.onSuggestions?(rows, generation, self.defaultSelection(for: historySuggestions, query: query))

            guard !rows.isEmpty, self.faviconLoader != nil else {
                return
            }

            do {
                try await Task.sleep(for: self.stableListDelay)
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard !Task.isCancelled,
                  self.activeGeneration == generation,
                  let faviconLoader = self.faviconLoader
            else {
                return
            }
            let requests = rows.compactMap { row in
                URL(string: row.address).map { KeelFaviconRequest(id: row.id, pageURL: $0) }
            }
            faviconLoader.load(for: requests, generation: generation) { [weak self] results in
                guard let self, self.activeGeneration == generation else {
                    return
                }
                for result in results {
                    self.onFavicon?(result.id, result.image, generation, KeelFaviconResult.crossfadeDuration)
                }
            }
        }
    }

    func accept(
        _ suggestion: KeelAddressPaletteSuggestion,
        input: String,
        disposition: KeelHistorySuggestionDisposition
    ) {
        onSuggestionAccepted?(
            .selectHistorySuggestion(
                historyURLID: suggestion.historyURLID,
                typedInput: input,
                disposition: disposition
            )
        )
    }

    func cancelPendingWork() {
        queryTask?.cancel()
        if let activeGeneration {
            faviconLoader?.cancel(generation: activeGeneration)
        }
        activeGeneration = nil
    }

    func waitForIdleForTesting() async {
        await queryTask?.value
    }

    private static func paletteSuggestion(_ suggestion: HistorySuggestion) -> KeelAddressPaletteSuggestion {
        KeelAddressPaletteSuggestion(
            id: "history-\(suggestion.historyURLID)",
            historyURLID: suggestion.historyURLID,
            title: suggestion.title ?? suggestion.displayURL,
            address: suggestion.url.absoluteString
        )
    }

    /// Typing never pre-selects a row. Return on a bare query opens it: a
    /// phrase searches, an address navigates. A History row is chosen with
    /// the arrow keys or the pointer, never on the typist's behalf, so a
    /// half-typed word cannot land on whatever History ranked first.
    private func defaultSelection(
        for suggestions: [HistorySuggestion],
        query: String
    ) -> KeelAddressPaletteDefaultSelection {
        .open
    }
}
