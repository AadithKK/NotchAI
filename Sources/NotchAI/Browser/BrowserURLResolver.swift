import Foundation

/// Turns whatever the user typed into the address field into something `WKWebView` can load.
///
/// The rules are deliberately pure and synchronous so they can be unit tested without a web view:
/// explicit web URLs pass through, host-like text becomes `https://…`, everything else is searched
/// with the engine picked in Settings.
enum BrowserURLResolver {
    /// Schemes that belong to other apps or to the system; the mini browser never loads these.
    private static let handOffSchemes: Set<String> = [
        "mailto", "tel", "sms", "facetime", "javascript", "data", "ftp", "about"
    ]

    static func resolve(_ rawText: String, searchEngine: BrowserSearchEngine) -> URL? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.caseInsensitiveCompare("about:blank") == .orderedSame {
            return URL(string: "about:blank")
        }

        let lowercased = text.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") || lowercased.hasPrefix("file://") {
            guard let url = URL(string: text), url.scheme != nil else { return nil }
            return url
        }

        if let scheme = schemePrefix(of: text), handOffSchemes.contains(scheme) {
            return nil
        }

        if let hostURL = hostLikeURL(from: text) {
            return hostURL
        }

        return searchURL(for: text, searchEngine: searchEngine)
    }

    // MARK: - Host detection

    /// Recognises `example.com`, `example.com/path?q=1`, `localhost:8080`, `127.0.0.1:8000`
    /// and IPv6 literals such as `[::1]:8080`.
    private static func hostLikeURL(from text: String) -> URL? {
        guard !text.contains(where: { $0.isWhitespace }) else { return nil }

        if text.hasPrefix("[") {
            return URL(string: "https://\(text)")
        }

        let hostPort = text
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? text

        let host: String
        if let colon = hostPort.firstIndex(of: ":") {
            let candidate = String(hostPort[..<colon])
            let port = hostPort[hostPort.index(after: colon)...]
            guard !candidate.isEmpty, !port.isEmpty, port.allSatisfy(\.isNumber) else { return nil }
            host = candidate
        } else {
            host = hostPort
        }

        let lowercasedHost = host.lowercased()
        let looksLikeHost = lowercasedHost == "localhost"
            || lowercasedHost.hasSuffix(".localhost")
            || host.contains(".")
        guard looksLikeHost else { return nil }

        return URL(string: "https://\(text)")
    }

    // MARK: - Search

    private static func searchURL(for text: String, searchEngine: BrowserSearchEngine) -> URL? {
        guard var components = URLComponents(string: searchEngine.queryTemplate) else { return nil }

        // Keep the engine's template intact (including its `?q=`), filling in the existing
        // empty query item instead of appending a second one.
        if var items = components.queryItems, let placeholder = items.firstIndex(where: { ($0.value ?? "").isEmpty }) {
            items[placeholder].value = text
            components.queryItems = items
        } else {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "q", value: text)]
        }

        return components.url
    }

    // MARK: - Scheme detection

    /// Returns the RFC 3986 scheme prefix when the text starts with one, e.g. `mailto` in
    /// `mailto:a@b.com`. Host/port forms such as `localhost:8080` are handled before this.
    private static func schemePrefix(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let candidate = text[..<colon]
        guard let first = candidate.first, first.isLetter else { return nil }
        guard candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else {
            return nil
        }
        return candidate.lowercased()
    }
}
