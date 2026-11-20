import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct LocalError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct WebSource: Codable, Equatable, Sendable {
    let title: String
    let url: URL
    let snippet: String
}

struct WebEvidence: Codable, Equatable, Sendable {
    let provider: String
    let sources: [WebSource]
}

actor WebSearch {
    private struct Cached {
        let result: WebEvidence
        let saved: Date
    }

    private enum Provider: CaseIterable {
        case duckDuckGo, bing

        var name: String { self == .duckDuckGo ? "DuckDuckGo" : "Bing" }
        var endpoint: String {
            self == .duckDuckGo ? "https://lite.duckduckgo.com/lite/" : "https://www.bing.com/search"
        }

        func parse(_ data: Data) -> [WebSource] {
            switch self {
            case .duckDuckGo: SearchResults.duckDuckGo(data)
            case .bing: SearchResults.bing(data)
            }
        }
    }

    private let session: URLSession
    private var cache: [String: Cached] = [:]

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 7
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    func find(_ text: String) async throws -> WebEvidence {
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let query = String(normalized.prefix(320))
        guard !query.isEmpty else { throw LocalError(message: "Enter something to search for.") }
        let key = query.lowercased()
        let now = Date()
        if let cached = cache[key], now.timeIntervalSince(cached.saved) < 300 { return cached.result }

        for provider in Provider.allCases {
            try Task.checkCancellation()
            var components = URLComponents(string: provider.endpoint)!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            if provider == .bing { components.queryItems?.append(URLQueryItem(name: "format", value: "rss")) }
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = components.url else { continue }
            var request = URLRequest(url: url)
            request.setValue("NethLocal/2.0", forHTTPHeaderField: "User-Agent")
            request.setValue(provider == .bing ? "application/rss+xml, text/xml" : "text/html", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count <= 512_000 else { continue }
            let sources = provider.parse(data)
            guard !sources.isEmpty else { continue }
            try Task.checkCancellation()
            let result = WebEvidence(provider: provider.name, sources: sources)
            cache = cache.filter { now.timeIntervalSince($0.value.saved) < 300 }
            if cache.count >= 24, let oldest = cache.min(by: { $0.value.saved < $1.value.saved })?.key {
                cache.removeValue(forKey: oldest)
            }
            cache[key] = Cached(result: result, saved: now)
            return result
        }
        try Task.checkCancellation()
        throw LocalError(message: "Web search returned no usable results. Answering locally.")
    }
}

enum SearchResults {
    private static let anchors = try! NSRegularExpression(
        pattern: #"<a\b([^>]*\bclass\s*=\s*["'][^"']*\bresult-link\b[^"']*["'][^>]*)>(.*?)</a\s*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let href = try! NSRegularExpression(pattern: #"\bhref\s*=\s*(?:"([^"]+)"|'([^']+)')"#,
                                                       options: [.caseInsensitive])
    private static let snippets = try! NSRegularExpression(
        pattern: #"<td\b[^>]*\bclass\s*=\s*["'][^"']*\bresult-snippet\b[^"']*["'][^>]*>(.*?)</td\s*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let numericEntity = try! NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]{1,6}|[0-9]{1,7});"#)

    static func duckDuckGo(_ data: Data) -> [WebSource] {
        let html = String(decoding: data, as: UTF8.self)
        let input = html as NSString
        let results = anchors.matches(in: html, range: NSRange(location: 0, length: input.length))
        var used: Set<URL> = []
        var sources: [WebSource] = []
        for (index, anchor) in results.enumerated() {
            let attributes = input.substring(with: anchor.range(at: 1)) as NSString
            guard let link = href.firstMatch(in: attributes as String,
                                             range: NSRange(location: 0, length: attributes.length)) else { continue }
            let linkRange = link.range(at: 1).location == NSNotFound ? link.range(at: 2) : link.range(at: 1)
            guard let url = publicURL(entities(attributes.substring(with: linkRange))), used.insert(url).inserted else {
                continue
            }
            let start = NSMaxRange(anchor.range)
            let end = index + 1 < results.count ? results[index + 1].range.location : input.length
            let snippet = snippets.firstMatch(in: html, range: NSRange(location: start, length: end - start))
            let title = clean(input.substring(with: anchor.range(at: 2)))
            guard !title.isEmpty else { continue }
            sources.append(WebSource(title: String(title.prefix(170)), url: url,
                                     snippet: snippet.map { String(clean(input.substring(with: $0.range(at: 1))).prefix(420)) } ?? ""))
            if sources.count == 5 { break }
        }
        return sources
    }

    static func bing(_ data: Data) -> [WebSource] {
        if data.range(of: Data("<!DOCTYPE".utf8)) != nil { return [] }
        let feed = RSSResults()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = feed
        return parser.parse() ? Array(feed.sources.prefix(5)) : []
    }

    fileprivate static func publicURL(_ value: String) -> URL? {
        let absolute = value.hasPrefix("//") ? "https:\(value)" : value
        guard var url = URL(string: absolute) else { return nil }
        if let host = url.host?.lowercased(), host == "duckduckgo.com" || host.hasSuffix(".duckduckgo.com"),
           let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "uddg" })?.value,
           let redirected = URL(string: target) {
            url = redirected
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    fileprivate static func clean(_ value: String) -> String {
        let stripped = value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return entities(stripped).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func entities(_ value: String) -> String {
        let named = ["&quot;": "\"", "&apos;": "'", "&nbsp;": " ", "&lt;": "<", "&gt;": ">",
                     "&ndash;": "–", "&mdash;": "—", "&hellip;": "…", "&rsquo;": "’"]
        var decoded = value
        for (entity, character) in named { decoded = decoded.replacingOccurrences(of: entity, with: character) }
        decoded = decoded.replacingOccurrences(of: "&amp;", with: "&")
        let input = decoded as NSString
        let output = NSMutableString(string: decoded)
        for item in numericEntity.matches(in: decoded, range: NSRange(location: 0, length: input.length)).reversed() {
            let code = input.substring(with: item.range(at: 1))
            let hex = code.hasPrefix("x")
            if let number = UInt32(hex ? String(code.dropFirst()) : code, radix: hex ? 16 : 10),
               let scalar = Unicode.Scalar(number) {
                output.replaceCharacters(in: item.range, with: String(scalar))
            }
        }
        return output as String
    }
}

private final class RSSResults: NSObject, XMLParserDelegate {
    private var item: [String: String]?
    private var field: String?
    private var seen: Set<URL> = []
    private(set) var sources: [WebSource] = []

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if element == "item" { item = [:] }
        if item != nil, ["title", "link", "description"].contains(element) { field = element }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let field { item?[field, default: ""] += string }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        self.parser(parser, foundCharacters: String(decoding: data, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == field { field = nil }
        guard element == "item", let item else { return }
        self.item = nil
        let title = SearchResults.clean(item["title"] ?? "")
        let link = (item["link"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let url = SearchResults.publicURL(link), seen.insert(url).inserted else { return }
        sources.append(WebSource(title: String(title.prefix(170)), url: url,
                                 snippet: String(SearchResults.clean(item["description"] ?? "").prefix(420))))
    }
}
