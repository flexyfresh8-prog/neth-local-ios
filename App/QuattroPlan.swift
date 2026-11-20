import Foundation

struct QuattroProjectRequest: Sendable {
    let prompt: String
    let namedPaths: [String]
    let bundleName: String?
}

enum QuattroPlan {
    private struct Manifest: Decodable {
        let name: String
        let files: [PlannedFile]
    }

    static func requestsWeb(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["search the web", "search web", "look up online", "look this up online", "browse the web"]
            .contains(where: text.hasPrefix)
    }

    static func projectRequest(_ input: String, explicit: Bool) throws -> QuattroProjectRequest? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/file ") {
            let rest = text.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
            let name: String
            let prompt: String
            if rest.hasPrefix("\""), let end = rest.dropFirst().firstIndex(of: "\"") {
                name = String(rest[rest.index(after: rest.startIndex)..<end])
                prompt = rest[rest.index(after: end)...].trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                let parts = rest.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                name = parts.first.map(String.init) ?? ""
                prompt = parts.count == 2 ? String(parts[1]) : ""
            }
            let path = try ChatWorkspace.supportedPath(name)
            guard !prompt.isEmpty else { throw LocalError(message: "Describe the file after its name.") }
            return QuattroProjectRequest(prompt: prompt, namedPaths: [path], bundleName: nil)
        }

        let words = Set(ToolCatalog.words(String(text.prefix(1800))))
        let creationWords: Set<String> = ["create", "make", "build", "generate", "write", "save", "export", "design", "package"]
        let targets: Set<String> = ["file", "files", "project", "app", "website", "page", "game", "script",
                                    "document", "pdf", "zip", "csv", "spreadsheet", "html"]
        let edits: Set<String> = ["edit", "rename", "delete", "list", "read"]
        guard explicit || (!words.isDisjoint(with: creationWords) && !words.isDisjoint(with: targets) && words.isDisjoint(with: edits))
        else { return nil }
        let paths = filePaths(in: String(text.prefix(1800)))
        let zip = paths.first { $0.lowercased().hasSuffix(".zip") }
        let named = paths.filter { !$0.lowercased().hasSuffix(".zip") }
        return QuattroProjectRequest(prompt: text, namedPaths: named, bundleName: zip)
    }

    static func toolPrompt(_ prompt: String, options: [ToolDefinition], observations: [ToolTrace]) -> String {
        let tools = options.map { "\($0.id) \($0.example) — \($0.summary)" }.joined(separator: "\n")
        let past = observations.suffix(3).map { "\($0.tool): \(String($0.detail.prefix(220)))" }.joined(separator: "\n")
        return """
            Pick one tool needed for the request. Put its real arguments in the JSON object. Use tool "answer" with {} if the results are sufficient or no tool fits.
            \(tools)

            User request: \(String(prompt.prefix(1700)))
            Prior tool results: \(past)
            """
    }

    static func toolGrammar(_ options: [ToolDefinition]) -> String {
        let ids = (["answer"] + options.map(\.id)).map { "\"\\\"\($0)\\\"\"" }.joined(separator: " | ")
        return """
            root ::= ws "{" ws "\\"tool\\"" ws ":" ws choice ws "," ws "\\"arguments\\"" ws ":" ws object ws "}" ws
            choice ::= \(ids)
            object ::= "{" ws (pair (ws "," ws pair)*)? ws "}"
            pair ::= string ws ":" ws (string | number | "true" | "false")
            number ::= "-"? ("0" | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [-+]? [0-9]+)?
            \(jsonPrimitives)
            """
    }

    static let projectGrammar = """
        root ::= ws "{" ws "\\"name\\"" ws ":" ws string ws "," ws "\\"files\\"" ws ":" ws "[" ws file (ws "," ws file)* ws "]" ws "}" ws
        file ::= "{" ws "\\"path\\"" ws ":" ws string ws "," ws "\\"purpose\\"" ws ":" ws string ws "}"
        \(jsonPrimitives)
        """

    static func manifestPrompt(_ request: QuattroProjectRequest, files: Int) -> String {
        """
            Plan the files for this task. Give a short project name and up to \(files) compatible text, code or PDF files. Use short relative paths and 1-sentence purposes. Use comments or prose as file content only when appropriate. Avoid binary dependencies. For a website or browser game, use HTML/CSS/JS with matching relative references.

            \(String(request.prompt.prefix(2100)))
            """
    }

    static func project(_ request: QuattroProjectRequest, output: String?, maximum: Int) -> ProjectWork {
        var name = request.bundleName.map { String($0.dropLast(4)) } ?? "Project"
        var files: [PlannedFile] = []
        if !request.namedPaths.isEmpty {
            name = request.bundleName.map { String($0.dropLast(4)) } ?? (request.namedPaths[0] as NSString).deletingPathExtension
            files = request.namedPaths.map { PlannedFile(path: $0, purpose: "Implement the requested content for \($0).") }
        } else if let output, let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(output.utf8)) {
            if request.bundleName == nil { name = manifest.name }
            var seen: Set<String> = []
            for file in manifest.files {
                if let path = try? ChatWorkspace.supportedPath(file.path), seen.insert(path.lowercased()).inserted {
                    files.append(PlannedFile(path: path, purpose: String(file.purpose.prefix(175))))
                }
            }
        }
        if files.isEmpty {
            let words = Set(ToolCatalog.words(String(request.prompt.prefix(1600))))
            if !words.isDisjoint(with: ["game", "website", "browser", "html", "webpage"]) {
                files = [PlannedFile(path: "index.html", purpose: "Page structure referencing styles.css and app.js."),
                         PlannedFile(path: "styles.css", purpose: "Layout and visual styling for the page."),
                         PlannedFile(path: "app.js", purpose: "Working application or game logic.")]
            } else {
                let ext = ["pdf", "csv", "json", "swift", "py", "md"].first(where: words.contains) ?? "md"
                files = [PlannedFile(path: "Draft.\(ext)", purpose: "Complete the user's requested file.")]
            }
        }
        let slug = String(ToolCatalog.words(name).joined(separator: "-").prefix(44))
        return ProjectWork(folder: UUID().uuidString, name: slug.isEmpty ? "project" : slug,
                           files: Array(files.prefix(maximum)))
    }

    static func filePrompt(_ file: PlannedFile, project: ProjectWork, request: String, linked: [String]) -> String {
        let brief = String(request.prefix(2700))
        let layout = project.files.map { "\($0.path) — \($0.purpose)" }.joined(separator: "\n")
        return """
            Write the complete contents of \(file.path). \(file.purpose)
            Return only this file's content, without a wrapping Markdown fence. Write working content with all required sections and no placeholder stubs. Use the paths in this manifest verbatim.

            Project request: \(brief)
            Files: \(layout)
            Interface notes from existing files:
            \(linked.joined(separator: "\n"))
            """
    }

    static func fileContent(_ text: String, path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ext != "md" {
            let blocks = ReplyFormat(trimmed).blocks
            if let code = blocks.compactMap({ block -> String? in
                if case .code(_, let value) = block { return value }
                return nil
            }).first {
                return code + "\n"
            }
        }
        return trimmed + "\n"
    }

    static func looksComplete(_ text: String, path: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        let content = fileContent(text, path: path)
        if ext == "json" {
            return (try? JSONSerialization.jsonObject(with: Data(content.utf8), options: [.fragmentsAllowed])) != nil
        }
        if ext == "csv" { return (try? CSV.parse(content).isEmpty) == false }
        if ext == "html" {
            let html = content.lowercased()
            return !html.contains("<html") || html.contains("</html>")
        }
        return !ReplyFormat(text).hasOpenFence
    }

    private static func filePaths(in input: String) -> [String] {
        let regex = try! NSRegularExpression(
            pattern: #"(?<![\p{L}\d./\\])[\p{L}\d_-]+(?:/[\p{L}\d_-]+)*\.[a-zA-Z0-9]{1,6}\b"#)
        let native = input as NSString
        var seen: Set<String> = []
        return regex.matches(in: input, range: NSRange(location: 0, length: native.length)).compactMap { match in
            let path = native.substring(with: match.range)
            guard seen.insert(path.lowercased()).inserted else { return nil }
            if path.lowercased().hasSuffix(".zip") { return try? ChatWorkspace.cleanPath(path) }
            return try? ChatWorkspace.supportedPath(path)
        }
    }

    private static let jsonPrimitives = #"""
    ws ::= [ \t\r\n]{0,4}
    string ::= "\"" ([^"\\\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4}))* "\""
    """#
}
