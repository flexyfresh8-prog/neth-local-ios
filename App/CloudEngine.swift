import Foundation

// CloudGeneration adapts the app's ModelRequest pipeline to the remote llama.cpp server.
// Everything Quattro and chat already do locally — effort levels, continuation, web
// evidence, grammar-constrained tool selection — flows through the same events, so the
// rest of the app does not branch on the backend.

enum CloudGeneration {
    static func effort(of reasoningBudget: Int) -> String {
        reasoningBudget >= 480 ? "high" : reasoningBudget >= 200 ? "medium" : "low"
    }

    static func run(_ request: ModelRequest, cloud: CloudCompute, stop: GenerationStop)
        -> AsyncThrowingStream<EngineEvent, Error> {
        let cloudRequest = CloudRequest(
            system: LocalEngine.referenceText(context: cloud.context, evidence: request.evidence,
                                              recall: request.recall, digest: request.digest,
                                              instructions: request.instructions),
            turns: request.history.map { CloudTurn(role: $0.role, text: $0.text) },
            prefix: ReplyContinuation.tail(of: request.prefix, context: cloud.context),
            grammar: request.grammar,
            limit: request.limit,
            reasoningEffort: effort(of: request.reasoning))
        let session = CloudSession(server: cloud.server)
        let profile = RuntimeProfile(backend: "Neth Cloud GPU", context: cloud.context, cache: "Remote")
        return session.stream(cloudRequest, profile: profile, model: cloud.server.model.isEmpty ? nil : cloud.server.model,
                              stop: stop)
    }
}

extension CloudSession {
    func stream(_ request: CloudRequest, profile: RuntimeProfile, model: String?, stop: GenerationStop)
        -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await deliver(request, profile: profile, model: model, stop: stop, continuation: continuation)
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { stop.request() }
                task.cancel()
            }
        }
    }

    private func deliver(_ request: CloudRequest, profile: RuntimeProfile, model: String?,
                         stop: GenerationStop, continuation: AsyncThrowingStream<EngineEvent, Error>.Continuation) async {
        var attempt = 0
        while true {
            attempt += 1
            do {
                var finish = ReplyFinish.complete
                try await pass(request, profile: profile, model: model, stop: stop, continuation: continuation,
                               finish: &finish)
                continuation.yield(.finished(stop.cancelled ? .stopped : finish))
                continuation.finish()
                return
            } catch {
                // One automatic retry when the tunnel drops before the first token.
                let retryable = (error as? URLError).map { [.networkConnectionLost, .timedOut].contains($0.code) } == true
                    && attempt == 1
                if retryable && !stop.cancelled {
                    try? await Task.sleep(for: .seconds(1.2))
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    continue
                }
                if stop.cancelled {
                    continuation.yield(.finished(.stopped))
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
                return
            }
        }
    }

    private func pass(_ request: CloudRequest, profile: RuntimeProfile, model: String?, stop: GenerationStop,
                      continuation: AsyncThrowingStream<EngineEvent, Error>.Continuation,
                      finish: inout ReplyFinish) async throws {
        var urlRequest = URLRequest(url: server.url.appending(path: CloudEndpoint.chat), timeoutInterval: 180)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = CloudSession.makeBody(request, model: model)

        let started = Date()
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw LocalError(message: "The cloud server response was not HTTP.")
        }
        guard (200..<300).contains(http.statusCode) else {
            var detail = ""
            for try await line in bytes.lines {
                detail += line
                if detail.utf8.count > 400 { break }
            }
            throw Self.statusMessage(http.statusCode, body: detail)
        }

        continuation.yield(.ready(profile))
        var firstDelta: Date?
        var counted = 0
        var lastPaint = Date.distantPast
        var reasoningOpen = false
        var exactTokens: Int?
        var toolCalls: [Int: (name: String, arguments: String)] = [:]

        func sampleProgress() {
            let now = Date()
            guard let first = firstDelta, now.timeIntervalSince(lastPaint) >= 0.3 else { return }
            lastPaint = now
            continuation.yield(.progress(tokens: counted, seconds: max(0, now.timeIntervalSince(first))))
        }

        for try await line in bytes.lines {
            if stop.cancelled { return }
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]" else { break }
            guard let delta = HarmonyAdapter.parseChunk(payload) else { continue }
            if let detail = delta.detail {
                throw LocalError(message: "The cloud server reported an error: \(String(detail.prefix(220)))")
            }
            if let reasoning = delta.reasoning {
                if !reasoningOpen {
                    continuation.yield(.text("<think>"))
                    reasoningOpen = true
                }
                if firstDelta == nil { firstDelta = Date() }
                counted += 1
                continuation.yield(.text(reasoning))
                sampleProgress()
            }
            if let content = delta.content {
                if reasoningOpen {
                    continuation.yield(.text("</think>\n\n"))
                    reasoningOpen = false
                }
                if firstDelta == nil { firstDelta = Date() }
                counted += 1
                continuation.yield(.text(content))
                sampleProgress()
            }
            if let index = delta.toolIndex {
                let previous = toolCalls[index] ?? ("", "")
                toolCalls[index] = (delta.toolName ?? previous.0, previous.1 + (delta.toolArguments ?? ""))
            }
            if let tokens = delta.completionTokens { exactTokens = tokens }
            if let reason = delta.finish {
                finish = reason == "length" ? .outputLimit : .complete
            }
        }
        if stop.cancelled { return }
        if reasoningOpen { continuation.yield(.text("</think>\n\n")) }
        if !toolCalls.isEmpty {
            // GPT-OSS on llama.cpp (--jinja) can emit native tool_calls. Show the
            // model's actual calls with their arguments so nothing the backend
            // decides is hidden; execution stays on the Quattro catalog.
            let ordered = toolCalls.sorted { $0.key < $1.key }.enumerated().map { position, entry in
                let call = entry.value
                let name = call.name.isEmpty ? "tool" : call.name
                let args = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
                let shown = args.isEmpty ? "" : String(args.prefix(220)) + (args.count > 220 ? "…" : "")
                return "\(position + 1). \(name)\(shown.isEmpty ? "()" : "(\(shown))")"
            }
            continuation.yield(.text("\n\nNative tool call\(toolCalls.count == 1 ? "" : "s") from GPT-OSS:\n"
                                     + ordered.joined(separator: "\n")
                                     + "\nNeth Local executes tools only through its own Quattro catalog on this device."))
        }
        let generationSeconds = (firstDelta ?? started).distance(to: Date())
        let tokens = exactTokens ?? counted
        CloudMetrics.shared.record(tokensPerSecond: generationSeconds > 0.05 && tokens > 1 ? Double(tokens - 1) / generationSeconds : nil,
                                   firstToken: (firstDelta ?? started).timeIntervalSince(started),
                                   tokens: tokens)
        if tokens > 0 {
            continuation.yield(.progress(tokens: tokens, seconds: max(0, generationSeconds)))
        }
    }
}
