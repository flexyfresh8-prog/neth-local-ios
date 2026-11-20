import Foundation

enum QuattroOutcome {
    case answer
    case handled
}

@MainActor
final class QuattroAgent {
    typealias Stream = (ModelRequest, (String) async throws -> Void) async throws -> ReplyFinish
    typealias Checkpoint = (ChatMessage, Bool) async throws -> Void

    let tools: QuattroTools

    init(tools: QuattroTools) { self.tools = tools }

    func run(reply: inout ChatMessage, task: ChatMessage, conversation: String, historyFiles: [WorkspaceFile],
             settings: RunSettings, report: (String, Int, Int) -> Void,
             stream: Stream, checkpoint: Checkpoint) async throws -> QuattroOutcome {
        let text = task.text
        let context = ToolContext(conversation: conversation, before: task.id, web: settings.web,
                                  files: historyFiles)
        let command = try ToolCall.parseCommand(text)
        if let call = command ?? (settings.makeFiles ? nil : tools.catalog.directConversion(text)) {
            try await execute(call, context: context, reply: &reply, report: report, step: 1, total: 1)
            reply.metadata?.finish = .complete
            return .handled
        }
        if let project = reply.metadata?.project {
            let brief = try QuattroPlan.projectRequest(text, explicit: true)?.prompt ?? text
            try await build(project: project, request: brief, reply: &reply, effort: settings.effort,
                            conversation: conversation, report: report, stream: stream, checkpoint: checkpoint)
            return .handled
        }
        if let request = try QuattroPlan.projectRequest(text, explicit: settings.makeFiles) {
            if settings.web && reply.evidence == nil {
                let query = String(text.prefix(280))
                try await callSearch(query, context: context, reply: &reply, report: report)
            }
            let planned: String?
            if request.namedPaths.isEmpty, let named = request.bundleName, !historyFiles.isEmpty,
               Set(ToolCatalog.words(request.prompt)).isDisjoint(with: ["website", "game", "app", "script", "html", "csv", "pdf"]) {
                let call = ToolCall(tool: "file.zip", arguments: ["name": .text(named)])
                try await execute(call, context: context, reply: &reply, report: report, step: 1, total: 1)
                reply.metadata?.finish = .complete
                return .handled
            } else if request.namedPaths.isEmpty {
                report("Planning files", 0, max(1, settings.effort.projectFiles))
                planned = try await structured(prompt: QuattroPlan.manifestPrompt(request, files: settings.effort.projectFiles),
                                               grammar: QuattroPlan.projectGrammar, limit: 480, stream: stream)
            } else { planned = nil }
            let maximum = max(settings.effort.projectFiles, min(12, request.namedPaths.count))
            let project = QuattroPlan.project(request, output: planned, maximum: maximum)
            if request.namedPaths.count > maximum {
                reply.notice = "This run can create the first \(maximum) requested files."
            }
            reply.metadata?.project = project
            try await checkpoint(reply, true)
            try await build(project: project, request: request.prompt, reply: &reply, effort: settings.effort,
                            conversation: conversation, report: report, stream: stream, checkpoint: checkpoint)
            return .handled
        }
        if settings.web && reply.evidence == nil {
            try await callSearch(String(text.prefix(280)), context: context, reply: &reply, report: report)
        }
        let options = tools.catalog.shortlist(text, web: false, limit: 4)
        guard !options.isEmpty else { return .answer }
        var completed: Set<ToolCallKey> = []
        for step in 1...settings.effort.toolSteps {
            try Task.checkCancellation()
            report("Selecting a tool", step - 1, settings.effort.toolSteps)
            let prompt = QuattroPlan.toolPrompt(text, options: options, observations: reply.metadata?.trace ?? [])
            let output = try await structured(prompt: prompt, grammar: QuattroPlan.toolGrammar(options), limit: 205, stream: stream)
            guard let output, let call = try? JSONDecoder().decode(ToolCall.self, from: Data(output.utf8)),
                  options.contains(where: { $0.id == call.tool }), completed.insert(ToolCallKey(call)).inserted
            else { break }
            try await execute(call, context: context, reply: &reply, report: report, step: step,
                              total: settings.effort.toolSteps, direct: false)
            try await checkpoint(reply, true)
        }
        return .answer
    }

    private func structured(prompt: String, grammar: String, limit: Int, stream: Stream) async throws -> String? {
        var result = ""
        do {
            let request = ModelRequest(history: [ChatMessage(role: .user, text: prompt)], grammar: grammar, limit: limit)
            let reason = try await stream(request) { result += $0 }
            try Task.checkCancellation()
            return reason == .complete ? result.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        } catch is CancellationError {
            throw CancellationError()
        } catch { return nil }
    }

    private func callSearch(_ query: String, context: ToolContext, reply: inout ChatMessage,
                            report: (String, Int, Int) -> Void) async throws {
        try await execute(ToolCall(tool: "web.search", arguments: ["query": .text(query)]), context: context,
                          reply: &reply, report: report, step: 1, total: 1, direct: false)
    }

    private func execute(_ call: ToolCall, context: ToolContext, reply: inout ChatMessage,
                         report: (String, Int, Int) -> Void, step: Int, total: Int, direct: Bool = true) async throws {
        let title = tools.catalog[call.tool]?.title ?? call.tool
        report(title, step, total)
        do {
            let output = try await tools.execute(call, in: context)
            if let evidence = output.evidence { reply.evidence = evidence }
            if let file = output.file { reply.metadata?.attach(file) }
            reply.metadata?.trace.append(ToolTrace(tool: call.tool, title: title, detail: String(output.text.prefix(1200))))
            if direct { reply.text = output.text }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let issue = error.localizedDescription
            reply.metadata?.trace.append(ToolTrace(tool: call.tool, title: title, detail: issue, failed: true))
            if direct { reply.notice = issue }
            if call.tool == "web.search" { reply.notice = issue }
        }
    }

    private func build(project initial: ProjectWork, request: String, reply: inout ChatMessage,
                       effort: EffortPreset, conversation: String, report: (String, Int, Int) -> Void,
                       stream: Stream, checkpoint: Checkpoint) async throws {
        var project = initial
        while project.cursor < project.files.count {
            let file = project.files[project.cursor]
            report("Writing \(file.path)", project.cursor + 1, project.files.count)
            var linked: [String] = []
            let peers = (reply.metadata?.files ?? []).filter { !$0.name.hasSuffix(".zip") && $0.name != file.path }.suffix(3)
            for existing in peers {
                if let preview = try? await tools.workspace.read(existing.id, conversation: conversation, limit: 340) {
                    linked.append("\(existing.name): \(preview.replacingOccurrences(of: "<|", with: "‹|"))")
                }
            }
            let prompt = QuattroPlan.filePrompt(file, project: project, request: request, linked: linked)
            var reason: ReplyFinish = .outputLimit
            var issue: String?
            let limit = max(1152, effort.outputTokens)
            for _ in 0..<effort.filePasses {
                if Task.isCancelled { reason = .stopped; break }
                let previous = project.draft
                var segment = ""
                var savedAt = Date()
                let writing = ModelRequest(history: [ChatMessage(role: .user, text: prompt)], evidence: reply.evidence,
                                           instructions: previous.isEmpty ? "" : "Continue this file from the exact last character. Output only the remaining file contents.",
                                           prefix: previous, limit: limit)
                do {
                    reason = try await stream(writing) {
                        segment += $0
                        let now = Date()
                        if now.timeIntervalSince(savedAt) >= 3 {
                            var saved = project
                            saved.draft = previous + segment
                            var snapshot = reply
                            snapshot.metadata?.project = saved
                            try await checkpoint(snapshot, true)
                            savedAt = now
                        }
                    }
                } catch is CancellationError {
                    reason = .stopped
                } catch {
                    reason = .error
                    issue = error.localizedDescription
                }
                let addition = ReplyContinuation.removeOverlap(previous: previous, added: segment)
                project.draft += addition
                if Task.isCancelled { reason = .stopped }
                if addition.isEmpty || reason == .stopped || reason == .error { break }
                if reason == .complete {
                    if QuattroPlan.looksComplete(project.draft, path: file.path) { break }
                    reason = .outputLimit
                }
                reply.metadata?.project = project
                try await checkpoint(reply, true)
            }
            if !project.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let partial = reason != .complete
                let result = try await tools.workspace.save(QuattroPlan.fileContent(project.draft, path: file.path),
                                                            name: file.path, conversation: conversation,
                                                            folder: project.folder, partial: partial)
                reply.metadata?.attach(result)
                if !partial {
                    reply.metadata?.trace.append(ToolTrace(tool: "file.write", title: "Created \(file.path)",
                                                           detail: ByteCountFormatter.string(fromByteCount: Int64(result.bytes), countStyle: .file)))
                    project.cursor += 1
                    project.draft = ""
                }
            } else if reason == .complete {
                reason = .outputLimit
            }
            reply.metadata?.project = project
            reply.text = project.cursor == 0 ? "Working on **\(file.path)**." : "Created \(project.cursor) of \(project.files.count) files."
            if let issue { reply.notice = issue }
            try await checkpoint(reply, true)
            if reason != .complete {
                reply.metadata?.finish = reason
                return
            }
        }
        if project.files.count > 1 || project.bundle != nil {
            report("Packaging files", project.files.count, project.files.count)
            let files = reply.metadata?.files ?? []
            let archive = try await tools.workspace.archive(files.filter { !$0.name.lowercased().hasSuffix(".zip") },
                                                            name: project.bundle ?? "\(project.name).zip", conversation: conversation,
                                                            folder: project.folder)
            reply.metadata?.attach(archive)
            reply.metadata?.trace.append(ToolTrace(tool: "file.zip", title: "Packaged \(archive.name)",
                                                   detail: "\(project.files.count) files"))
        }
        reply.text = project.files.count == 1 ? "Created **\(project.files[0].path)**." : "Created \(project.files.count) files. Use the ZIP to export the project together."
        reply.metadata?.finish = .complete
    }

    private struct ToolCallKey: Hashable {
        let value: Data
        init(_ call: ToolCall) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            value = (try? encoder.encode(call)) ?? Data(call.tool.utf8)
        }
    }
}
