import SwiftUI

@MainActor
final class LocalChat: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var conversationID: String?
    @Published private(set) var running = false
    @Published private(set) var opening = false
    @Published private(set) var activity: String?
    @Published private(set) var profile: RuntimeProfile?
    @Published private(set) var tokensPerSecond: Double?
    @Published private(set) var hasEarlier = false
    @Published private(set) var hasLater = false
    @Published private(set) var targetMessage: Int64?
    @Published var problem: String?

    private let archive = ChatArchive()
    private let engine = LocalEngine()
    private let searcher = WebSearch()
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

    func send(_ text: String, photo: URL?, searchWeb: Bool, settings: EngineSettings) {
        guard !running, !opening else { return }
        let id = conversationID ?? UUID().uuidString
        let stop = GenerationStop()
        running = true
        activeStop = stop
        activity = searchWeb ? "Searching the web…" : "Preparing…"
        tokensPerSecond = nil
        run = Task {
            defer {
                if let photo { try? FileManager.default.removeItem(at: photo) }
                if messages.last?.id == -1 { messages.removeLast() }
                running = false
                activeStop = nil
                run = nil
                activity = nil
            }
            do {
                let saved = try await archive.append(ChatMessage(role: .user, text: text, photo: photo), to: id)
                if conversationID != id || hasLater || messages.count >= 100 {
                    let page = try await archive.page(in: id, limit: pageSize + 1)
                    messages = Array(page.suffix(pageSize))
                    hasEarlier = page.count > pageSize
                    hasLater = false
                } else {
                    messages.append(saved)
                }
                conversationID = id
                targetMessage = nil
                conversations = try await archive.conversations()
                try Task.checkCancellation()

                let recent = try await archive.page(in: id, limit: 80)
                let history = Self.activeTurns(recent, context: settings.context, searchWeb: searchWeb)
                async let notes = archive.recall(text, in: id, before: history.first?.id ?? saved.id)
                var answer = ChatMessage(role: .assistant, text: "")
                messages.append(answer)

                if searchWeb {
                    do { answer.evidence = try await searcher.find(text) }
                    catch is CancellationError { throw CancellationError() }
                    catch { answer.notice = error.localizedDescription }
                    messages[messages.count - 1] = answer
                }
                var lastPaint = Date.distantPast
                let recall = (try? await notes) ?? []
                try Task.checkCancellation()
                do {
                    for try await event in engine.stream(history: history, settings: settings, evidence: answer.evidence,
                                                         recall: recall, stop: stop) {
                        switch event {
                        case .loading(let backend):
                            profile = nil
                            activity = "Loading model · \(backend)"
                        case .ready(let active):
                            profile = active
                            activity = "Reading prompt…"
                        case .text(let part):
                            if answer.text.isEmpty { activity = "Generating…" }
                            answer.text += part
                            let now = Date()
                            if now.timeIntervalSince(lastPaint) >= 0.04 {
                                messages[messages.count - 1] = answer
                                lastPaint = now
                            }
                        case .finished(let count, let seconds):
                            tokensPerSecond = Double(count - 1) / seconds
                        }
                    }
                } catch {
                    if !Task.isCancelled { answer.notice = error.localizedDescription }
                }
                if !answer.text.isEmpty || answer.notice != nil {
                    messages[messages.count - 1] = answer
                    let savedAnswer = try await archive.append(answer, to: id)
                    messages[messages.count - 1] = savedAnswer
                    conversations = try await archive.conversations()
                }
            } catch is CancellationError {
            } catch {
                if messages.last?.id == -1, !messages[messages.count - 1].text.isEmpty {
                    // Keep a generated answer visible if writing to storage fails.
                    messages[messages.count - 1].id = -2
                }
                problem = error.localizedDescription
            }
        }
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
