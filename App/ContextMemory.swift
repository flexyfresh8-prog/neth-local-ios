import Foundation

enum CachePrecision: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic, q4, q8, full

    var id: Self { self }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .q4: "Q4 · lower memory"
        case .q8: "Q8 · balanced"
        case .full: "F16 · full precision"
        }
    }

    var native: Int32 {
        switch self {
        case .automatic: 0
        case .q4: 1
        case .q8: 2
        case .full: 3
        }
    }

    func bytesPerToken(at context: Int) -> Int64 {
        switch self {
        case .q4: 9_216
        case .q8: 17_408
        case .full: 32_768
        case .automatic: context >= 32_768 ? 9_216 : context >= 4096 ? 17_408 : 32_768
        }
    }
}

struct ContextDigest: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        let role: ChatMessage.Role
        let text: String
    }

    var through: Int64 = 0
    var turns = 0
    var items: [Item] = []

    mutating func append(id: Int64, role: ChatMessage.Role, text: String) {
        through = id
        let content = role == .assistant ? ReplyContinuation.visible(text) : text
        let normalized = content.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return }
        turns += 1
        let cap = role == .user ? 170 : 120
        let excerpt: String
        if normalized.count <= cap {
            excerpt = normalized
        } else {
            let last = String(normalized.suffix(cap / 3))
            excerpt = "\(normalized.prefix(cap - last.count - 3)) … \(last)"
        }
        let item = Item(role: role, text: excerpt)
        if items.last != item { items.append(item) }
        // Keep the opening context and the most recent compacted turns.
        if items.count > 18 { items.removeSubrange(2..<(items.count - 16)) }
    }

    func excerpt(limit: Int) -> String {
        guard limit >= 90 else { return "" }
        var selected: [String] = []
        var remaining = limit
        for item in items.reversed() {
            let line = "\(item.role.rawValue): \(item.text)"
            if line.count + 1 > remaining {
                if selected.isEmpty { selected.append(String(line.prefix(remaining))) }
                break
            }
            selected.append(line)
            remaining -= line.count + 1
        }
        return selected.reversed().joined(separator: "\n")
    }
}
