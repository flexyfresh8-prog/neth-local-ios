import SwiftUI

@MainActor
final class LocalChat: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var conversationID: String?
    @Published private(set) var running = false
    @Published private(set) var opening = false
    @Published private(set) var activity: String?
    @Published private(set) var effortStep = 0
    @Published private(set) var effortTotal = 0
    @Published private(set) var activeEffort: EffortPreset?
    @Published private(set) var activeReplyID: Int64?
    @Published private(set) var profile: RuntimeProfile?
    @Published private(set) var tokensPerSecond: Double?
    @Published private(set) var hasEarlier = false
    @Published private(set) var hasLater = false
    @Published private(set) var targetMessage: Int64?
    @Published var problem: String?

    private let archive = ChatArchive()
    private let engine = LocalEngine()
    private let searcher = WebSearch()
    private let workspace = ChatWorkspace()
    private lazy var agent = QuattroAgent(tools: QuattroTools(archive: archive, workspace: workspace, searcher: searcher))
    private let pageSize = 40
    private var activeStop: GenerationStop?
    private var run: Task<Void, Never>?
    private var initialized = false

    var title: String {
        conversations.first { $0.id == conversationID }?.title ?? "New chat"
    }

    func restore() async {
        guard !initialized else { return }
        initialized = true
        do {
            conversations = try await archive.conversations()
            if conversationID == nil, let id = conversations.first?.id { await open(id) }
        } catch { problem = error.localizedDescription }
    }

    func newChat() {
        guard !running, !opening else { return }
        conversationID = nil
        messages = []
        hasEarlier = false
        hasLater = false
        targetMessage = nil
        activity = nil
        tokensPerSecond = nil
    }

    func remove(_ conversation: Conversation) async {
        guard !running, !opening else { return }
        opening = true
        defer { opening = false }
        do {
            try await archive.delete(conversation.id)
            await workspace.remove(conversation: conversation.id)
            if conversationID == conversation.id {
                conversationID = nil
                messages = []
                hasEarlier = false
                hasLater = false
                targetMessage = nil
                activity = nil
                tokensPerSecond = nil
            }
            conversations = try await archive.conversations()
        } catch { problem = error.localizedDescription }
    }

    func open(_ id: String, at message: Int64? = nil) async {
        guard !running, !opening else { return }
        opening = true
        defer { opening = false }
        do {
            let page = try await archive.page(in: id, before: message.map { $0 + 1 }, limit: pageSize + 1)
            let later: Bool
            if let message { later = try await archive.hasNewer(in: id, than: message) }
            else { later = false }
            conversationID = id
            messages = Array(page.suffix(pageSize))
            hasEarlier = page.count > pageSize
            hasLater = later
            targetMessage = message
            activity = nil
            tokensPerSecond = nil
        } catch { problem = error.localizedDescription }
    }

    func loadEarlier() async -> Int64? {
        guard !running, !opening, let id = conversationID, let first = messages.first?.id else { return nil }
        opening = true
        defer { opening = false }
        do {
            let page = try await archive.page(in: id, before: first, limit: pageSize + 1)
            messages.insert(contentsOf: page.suffix(pageSize), at: 0)
            hasEarlier = page.count > pageSize
            return first
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }

    func search(_ query: String) async throws -> [TranscriptMatch] {
        try await archive.search(query)
    }

    func send(_ text: String, photo: URL?, runSettings: RunSettings, settings: EngineSettings?) {
        guard !running, !opening else { return }
        let id = conversationID ?? UUID().uuidString
        begin(runSettings.effort) { stop in
            defer {
                if let photo { try? FileManager.default.removeItem(at: photo) }
            }
            let task = try await self.archive.append(ChatMessage(role: .user, text: text, photo: photo), to: id)
            let reply = try await self.archive.append(ChatMessage(role: .assistant, text: "",
                metadata: ReplyMetadata(effort: runSettings.effort, quattro: runSettings.quattro || runSettings.makeFiles,
                                        web: runSettings.web, wantsFiles: runSettings.makeFiles)), to: id)
            if self.conversationID != id || self.hasLater || self.messages.count >= 100 {
                let page = try await self.archive.page(in: id, limit: self.pageSize + 1)
                self.messages = Array(page.suffix(self.pageSize))
                self.hasEarlier = page.count > self.pageSize
                self.hasLater = false
            } else {
                self.messages.append(contentsOf: [task, reply])
            }
            self.conversationID = id
            self.targetMessage = nil
            self.conversations = try await self.archive.conversations()
            try await self.produce(reply, in: id, settings: settings, runSettings: runSettings, stop: stop, resuming: false)
        }
    }

    func resume(_ message: ChatMessage, effort: EffortPreset, settings: EngineSettings?) {
        guard !running, !opening, let id = conversationID, message.role == .assistant else { return }
        let previous = message.metadata
        let runSettings = RunSettings(effort: effort, quattro: previous?.quattro ?? false,
                                      web: previous?.web ?? false, makeFiles: previous?.wantsFiles == true || previous?.project != nil)
        begin(effort) { stop in
            try await self.produce(message, in: id, settings: settings, runSettings: runSettings, stop: stop, resuming: true)
        }
    }

    func saveReply(_ message: ChatMessage, text: String, as name: String) async {
        guard !running, !opening, let id = conversationID else { return }
        guard !text.isEmpty else { return }
        opening = true
        defer { opening = false }
        do {
            let file = try await workspace.save(text.hasSuffix("\n") ? text : text + "\n", name: name, conversation: id)
            var updated = message
            if updated.metadata == nil {
                updated.metadata = ReplyMetadata(effort: .balanced, quattro: false, finish: .complete)
            }
            updated.metadata?.attach(file)
            try await checkpoint(updated, in: id)
        } catch { problem = error.localizedDescription }
    }

    private func begin(_ effort: EffortPreset, work: @escaping (GenerationStop) async throws -> Void) {
        let stop = GenerationStop()
        activeStop = stop
        activeEffort = effort
        running = true
        tokensPerSecond = nil
        setActivity("Preparing", step: 0, total: 0)
        run = Task {
            defer {
                running = false
                activeStop = nil
                activeEffort = nil
                activeReplyID = nil
                run = nil
                activity = nil
            }
            do { try await work(stop) }
            catch is CancellationError {}
            catch { problem = error.localizedDescription }
        }
    }

    private func produce(_ original: ChatMessage, in id: String, settings: EngineSettings?,
                         runSettings: RunSettings, stop: GenerationStop, resuming: Bool) async throws {
        var reply = original
        if reply.metadata == nil {
            reply.metadata = ReplyMetadata(effort: runSettings.effort, quattro: runSettings.quattro)
        }
        reply.metadata?.effort = runSettings.effort
        reply.metadata?.finish = .working
        activeReplyID = reply.id
        try await checkpoint(reply, in: id)
        do {
            try Task.checkCancellation()
            let historyPage = try await archive.page(in: id, before: reply.id, limit: 96)
            guard let task = historyPage.last, task.role == .user else {
                throw LocalError(message: "The original prompt for this reply could not be found.")
            }
            let history = Self.activeTurns(historyPage, context: settings?.context ?? 4096, searchWeb: runSettings.web)
            let cutoff = history.first?.id ?? task.id
            async let notes = archive.recall(task.text, in: id, before: cutoff)
            async let compacted = compactedHistory(in: id, before: cutoff, enabled: settings?.compactHistory == true)
            let toolMode = reply.metadata?.quattro == true
            let isProject = reply.metadata?.project != nil
            let hasReply = !ReplyContinuation.visible(reply.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if toolMode, !resuming || isProject || (!hasReply && reply.metadata?.trace.isEmpty == true) {
                let historyFiles = historyPage.flatMap { $0.metadata?.files ?? [] }
                let outcome = try await agent.run(reply: &reply, task: task, conversation: id, historyFiles: historyFiles,
                    settings: runSettings, report: { self.setActivity($0, step: $1, total: $2) },
                    stream: { request, receive in
                        guard let settings else { throw LocalError(message: "Download a model to use Quattro for this task.") }
                        return try await self.readStream(request, settings: settings, stop: stop, keepActivity: true, receive: receive)
                    }, checkpoint: { snapshot, flush in
                        self.present(snapshot)
                        if flush { try await self.archive.updateReply(snapshot, in: id) }
                    })
                if case .handled = outcome {
                    try await checkpoint(reply, in: id)
                    return
                }
            } else if runSettings.web && reply.evidence == nil && (!resuming || !hasReply) {
                setActivity("Searching the web", step: 1, total: 1)
                do { reply.evidence = try await searcher.find(task.text) }
                catch is CancellationError { throw CancellationError() }
                catch { reply.notice = error.localizedDescription }
                try await checkpoint(reply, in: id)
            }

            guard let settings else {
                if reply.evidence != nil {
                    reply.text = "Search results are ready. Download a model to summarize them."
                    reply.metadata?.finish = .complete
                    try await checkpoint(reply, in: id)
                    return
                }
                throw LocalError(message: "Download or import a model to generate a response.")
            }
            let recall = (try? await notes) ?? []
            let digest = await compacted
            try await writeReply(&reply, history: history, recall: recall, digest: digest, id: id,
                                 settings: settings, effort: runSettings.effort, stop: stop, resuming: resuming)
        } catch is CancellationError {
            reply.metadata?.finish = .stopped
        } catch {
            reply.notice = error.localizedDescription
            reply.metadata?.finish = .error
        }
        try await checkpoint(reply, in: id)
    }

    private func compactedHistory(in id: String, before cutoff: Int64, enabled: Bool) async -> ContextDigest? {
        guard enabled else { return nil }
        return try? await archive.compact(in: id, before: cutoff)
    }

    private func writeReply(_ reply: inout ChatMessage, history: [ChatMessage], recall: [TranscriptMatch],
                            digest: ContextDigest?, id: String, settings: EngineSettings,
                            effort: EffortPreset, stop: GenerationStop, resuming: Bool) async throws {
        var lastDisk = Date()
        var lastPaint = Date.distantPast
        let result = (reply.metadata?.trace ?? []).filter { !$0.failed && $0.tool != "web.search" }
        let observations = result.suffix(3).map { "\($0.title): \(Self.plainReference($0.detail))" }.joined(separator: "\n")
        for index in 0..<effort.turns {
            if Task.isCancelled { reply.metadata?.finish = .stopped; return }
            let previous = ReplyContinuation.visible(reply.text)
            let continuing = resuming || index > 0
            if continuing { reply.text = ReplyContinuation.closeThought(reply.text) }
            var instructions = observations.isEmpty ? "" : "Use these local tool results in your reply:\n\(observations)"
            if continuing {
                instructions += "\nContinue your previous answer from its exact stopping point. Do not repeat text already written. If a code block is open, finish that block."
            }
            setActivity(continuing ? "Continuing reply" : "Reading prompt", step: index + 1, total: effort.turns)
            let request = ModelRequest(history: history, evidence: reply.evidence, recall: recall, digest: digest,
                                       instructions: instructions, prefix: previous,
                                       reasoning: !continuing && (effort.deliberates || settings.thinking) ? effort.thinkingTokens : 0,
                                       limit: effort.outputTokens)
            let base = reply.text
            var segment = ""
            var segmentFinish: ReplyFinish
            do {
                segmentFinish = try await readStream(request, settings: settings, stop: stop, keepActivity: continuing) { chunk in
                    segment += chunk
                    let now = Date()
                    if now.timeIntervalSince(lastPaint) >= 0.07 {
                        reply.text = base + segment
                        self.present(reply)
                        lastPaint = now
                    }
                    if now.timeIntervalSince(lastDisk) >= 2.5 {
                        reply.text = base + segment
                        try await self.archive.updateReply(reply, in: id)
                        lastDisk = now
                    }
                }
            } catch {
                reply.text = base + ReplyContinuation.removeOverlap(previous: previous, added: segment)
                throw error
            }
            let addition = ReplyContinuation.removeOverlap(previous: previous, added: segment)
            reply.text = base + addition
            if Task.isCancelled { segmentFinish = .stopped }
            if segmentFinish == .complete && (ReplyFormat(reply.text).hasOpenFence || ReplyContinuation.visible(reply.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                segmentFinish = .outputLimit
            }
            reply.metadata?.finish = segmentFinish
            try await checkpoint(reply, in: id)
            if !segmentFinish.atLimit || (addition.isEmpty && continuing) { return }
            if index + 1 < effort.turns { reply.metadata?.finish = .working }
        }
    }

    private func readStream(_ request: ModelRequest, settings: EngineSettings, stop: GenerationStop,
                            keepActivity: Bool, receive: (String) async throws -> Void) async throws -> ReplyFinish {
        var finish: ReplyFinish = .stopped
        var received = false
        for try await event in engine.stream(request, settings: settings, stop: stop) {
            switch event {
            case .loading(let backend):
                profile = nil
                if !keepActivity { activity = "Loading model · \(backend)" }
            case .ready(let active):
                profile = active
            case .text(let part):
                if !received && !keepActivity { activity = part.hasPrefix("<think>") ? "Reasoning" : "Writing reply" }
                if activity == "Reasoning" && part.contains("</think>") { activity = "Writing reply" }
                received = true
                try await receive(part)
            case .finished(let reason, let count, let seconds):
                if count > 1 { tokensPerSecond = Double(count - 1) / seconds }
                finish = reason
            }
        }
        return finish
    }

    private func setActivity(_ title: String, step: Int, total: Int) {
        activity = title
        effortStep = step
        effortTotal = total
    }

    private func present(_ message: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
    }

    private func checkpoint(_ message: ChatMessage, in id: String) async throws {
        present(message)
        try await archive.updateReply(message, in: id)
    }

    private static func plainReference(_ text: String) -> String {
        String(text.prefix(420)).replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: "\0", with: "")
    }

    func stop() {
        activeStop?.request()
        run?.cancel()
    }

    func unload() {
        stop()
        engine.unload()
        profile = nil
    }

    private static func activeTurns(_ history: [ChatMessage], context: Int, searchWeb: Bool) -> [ChatMessage] {
        var remaining = max(320, Int(Double(context) * 3.7) - (searchWeb ? 1200 : 560))
        var first = max(0, history.count - 1)
        if let last = history.last { remaining -= last.text.utf8.count + 38 }
        while first > 0 {
            let previous = first - 1
            let start = history[previous].role == .assistant ? previous - 1 : previous
            guard start >= 0, history[start].role == .user else { break }
            let cost = history[start..<first].reduce(0) { $0 + $1.text.utf8.count + 38 }
            if cost > remaining { break }
            remaining -= cost
            first = start
        }
        return Array(history.dropFirst(first))
    }
}
