import Foundation

enum EffortPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case quick, balanced, deep, maximum

    var id: Self { self }
    var title: String {
        switch self {
        case .quick: "Quick"
        case .balanced: "Balanced"
        case .deep: "Deep"
        case .maximum: "Max"
        }
    }

    var segments: Int {
        switch self {
        case .quick: 1
        case .balanced: 2
        case .deep: 3
        case .maximum: 4
        }
    }

    var description: String {
        switch self {
        case .quick: "Short replies and fast tool calls"
        case .balanced: "Automatic continuation for longer replies"
        case .deep: "More reasoning and more room for projects"
        case .maximum: "Longest replies and most tool steps"
        }
    }

    var turns: Int { [1, 3, 5, 8][segments - 1] }
    var outputTokens: Int { [1024, 2304, 3600, 4608][segments - 1] }
    var thinkingTokens: Int { [80, 224, 480, 880][segments - 1] }
    var toolSteps: Int { [1, 3, 5, 8][segments - 1] }
    var projectFiles: Int { [2, 4, 7, 10][segments - 1] }
    var filePasses: Int { [1, 3, 5, 8][segments - 1] }
    var deliberates: Bool { self == .deep || self == .maximum }
}

enum ReplyFinish: String, Codable, Sendable {
    case working, complete, outputLimit, contextLimit, stopped, error

    var atLimit: Bool { self == .contextLimit || self == .outputLimit }
    var label: String? {
        switch self {
        case .working: "Interrupted · Continue to resume"
        case .complete: nil
        case .outputLimit: "Reply paused at the output limit"
        case .contextLimit: "Reply paused at the context limit"
        case .stopped: "Stopped"
        case .error: "Interrupted"
        }
    }
}

struct WorkspaceFile: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let bytes: Int
    let partial: Bool
}

struct ToolTrace: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    let tool: String
    let title: String
    let detail: String
    var failed = false
}

struct PlannedFile: Codable, Equatable, Sendable {
    let path: String
    let purpose: String
}

struct ProjectWork: Codable, Equatable, Sendable {
    let folder: String
    let name: String
    let files: [PlannedFile]
    var bundle: String? = nil
    var cursor = 0
    var draft = ""
}

struct ReplyMetadata: Codable, Equatable, Sendable {
    var effort: EffortPreset
    var quattro: Bool
    var web = false
    var wantsFiles: Bool? = nil
    var finish: ReplyFinish = .working
    var trace: [ToolTrace] = []
    var files: [WorkspaceFile] = []
    var project: ProjectWork?

    mutating func attach(_ file: WorkspaceFile) {
        if let index = files.firstIndex(where: { $0.id == file.id }) {
            files[index] = file
        } else {
            files.append(file)
        }
    }
}

struct RunSettings: Sendable {
    let effort: EffortPreset
    let quattro: Bool
    let web: Bool
    let makeFiles: Bool
}

struct ModelRequest: Sendable {
    var history: [ChatMessage]
    var evidence: WebEvidence? = nil
    var recall: [TranscriptMatch] = []
    var digest: ContextDigest? = nil
    var instructions = ""
    var prefix = ""
    var grammar: String? = nil
    var reasoning = 0
    let limit: Int
}

enum ReplyContinuation {
    static func visible(_ raw: String) -> String {
        guard raw.hasPrefix("<think>") else { return raw }
        guard let close = raw.range(of: "</think>") else { return "" }
        return String(raw[close.upperBound...])
    }

    static func closeThought(_ raw: String) -> String {
        raw.hasPrefix("<think>") && !raw.contains("</think>") ? raw + "\n</think>\n\n" : raw
    }

    static func tail(of answer: String, context: Int) -> String {
        let limit = min(3200, max(100, context / 2))
        return String(answer.suffix(limit))
            .replacingOccurrences(of: "<|", with: "‹|")
            .replacingOccurrences(of: "<__media__", with: "‹__media__")
    }

    static func removeOverlap(previous: String, added: String) -> String {
        let tail = Array(previous.suffix(320))
        let head = Array(added.prefix(320))
        let longest = min(tail.count, head.count)
        if longest >= 24 {
            for count in stride(from: longest, through: 24, by: -1) {
                if tail.suffix(count).elementsEqual(head.prefix(count)) {
                    return String(added.dropFirst(count))
                }
            }
        }
        return added
    }
}
