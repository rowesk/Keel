import Foundation

internal struct CanonicalHistoryURL: Sendable {
    let canonicalURL: String
    let displayURL: String
    let origin: String
    let hostname: String
    let hostnameFolded: String
    let pathFolded: String
    let openURL: URL
}

internal enum HistoryURLCanonicalizer {
    static func canonicalize(_ url: URL) throws -> CanonicalHistoryURL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty
        else { throw HistoryStoreError.invalidURL }

        components.scheme = scheme
        components.host = host
        components.user = nil
        components.password = nil
        components.fragment = nil
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
        guard let openURL = components.url else { throw HistoryStoreError.invalidURL }

        let port = components.port.map { ":\($0)" } ?? ""
        let origin = "\(scheme)://\(host)\(port)"
        return CanonicalHistoryURL(
            canonicalURL: openURL.absoluteString,
            displayURL: openURL.absoluteString,
            origin: origin,
            hostname: host,
            hostnameFolded: fold(host),
            pathFolded: fold(components.percentEncodedPath.removingPercentEncoding ?? components.percentEncodedPath),
            openURL: openURL
        )
    }

    static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func searchTokens(_ value: String?) -> [String] {
        guard let value else { return [] }
        return Array(Set(fold(value).split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }))
    }

    static func inputTokens(_ value: String) -> [String] {
        searchTokens(value)
    }
}
