import Foundation
import KeelStore

enum KeelAddressResolution: Equatable {
    case navigation(URL)
    case search(URL)
}

enum KeelAddressResolver {
    static func resolve(_ input: String, searchProvider: SearchProvider) -> KeelAddressResolution? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let url = explicitURL(from: trimmed) {
            return .navigation(url)
        }
        if looksLikeHostname(trimmed), let url = URL(string: "https://\(trimmed)") {
            return .navigation(url)
        }
        return searchURL(for: trimmed, provider: searchProvider).map(KeelAddressResolution.search)
    }

    private static func explicitURL(from input: String) -> URL? {
        if let portDelimiter = input.firstIndex(of: ":"),
           (input[..<portDelimiter].lowercased() == "localhost" || input[..<portDelimiter].contains(".")),
           input[input.index(after: portDelimiter)...].first?.isNumber == true {
            return nil
        }
        guard let colonIndex = input.firstIndex(of: ":"),
              colonIndex != input.startIndex,
              input[..<colonIndex].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }),
              input[input.startIndex].isLetter,
              let components = URLComponents(string: input),
              let scheme = components.scheme,
              !scheme.isEmpty,
              let url = components.url
        else {
            return nil
        }
        return url
    }

    private static func looksLikeHostname(_ input: String) -> Bool {
        guard !input.contains(where: { $0.isWhitespace }) else {
            return false
        }
        return input == "localhost" || input.contains(".") || input.contains(":")
    }

    private static func searchURL(for input: String, provider: SearchProvider) -> URL? {
        switch provider {
        case .google:
            return searchURL(base: "https://www.google.com/search", query: input)
        case .duckDuckGo:
            return searchURL(base: "https://duckduckgo.com/", query: input)
        case .kagi:
            return searchURL(base: "https://kagi.com/search", query: input)
        case let .custom(template):
            // Only data positions are supported. Never interpolate an authority or
            // scheme. Unreserved encoding preserves query values and path segments,
            // including literal plus, percent, ampersand and fragment characters.
            guard SearchProvider.isValidCustomTemplate(template) else { return nil }
            let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            guard let encodedQuery = input.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
            return URL(string: template.replacing("{query}", with: encodedQuery))
        }
    }

    private static func searchURL(base: String, query: String) -> URL? {
        guard var components = URLComponents(string: base) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }
}
