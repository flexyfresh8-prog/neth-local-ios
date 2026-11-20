import Foundation

enum ReplyBlock: Equatable {
    case prose(String)
    case code(language: String, text: String)
}

struct ReplyFormat {
    let answer: String
    let reasoning: String?
    let reasoningComplete: Bool
    let blocks: [ReplyBlock]

    init(_ output: String) {
        let text = output.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("<think>") {
            let thought = text.dropFirst(7)
            if let end = thought.range(of: "</think>") {
                reasoning = thought[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                answer = thought[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                reasoningComplete = true
            } else {
                reasoning = thought.trimmingCharacters(in: .whitespacesAndNewlines)
                answer = ""
                reasoningComplete = false
            }
        } else {
            reasoning = nil
            answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
            reasoningComplete = true
        }
        blocks = Self.parse(answer)
    }

    private static func parse(_ answer: String) -> [ReplyBlock] {
        var result: [ReplyBlock] = []
        var lines: [Substring] = []
        var fence: (marker: Character, length: Int, language: String)?
        for line in answer.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix { $0 == " " }.count
            let candidate = line.dropFirst(indent)
            let marker = candidate.first
            let count = candidate.prefix { $0 == marker }.count
            let rest = candidate.dropFirst(count).trimmingCharacters(in: .whitespaces)
            if let active = fence {
                if indent <= 3, marker == active.marker, count >= active.length, rest.isEmpty {
                    result.append(.code(language: active.language, text: lines.joined(separator: "\n")))
                    lines.removeAll(keepingCapacity: true)
                    fence = nil
                } else {
                    lines.append(line)
                }
            } else if indent <= 3, let marker, marker == "`" || marker == "~", count >= 3 {
                let prose = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !prose.isEmpty { result.append(.prose(prose)) }
                lines.removeAll(keepingCapacity: true)
                let language = rest.split(whereSeparator: \.isWhitespace).first ?? "Code"
                fence = (marker, count, String(language.prefix(28)))
            } else {
                lines.append(line)
            }
        }
        if let fence {
            result.append(.code(language: fence.language, text: lines.joined(separator: "\n")))
        } else {
            let remaining = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty { result.append(.prose(remaining)) }
        }
        return result
    }
}
