import Foundation
import SQLite3

@main
struct ChatChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let page = Data("""
            <a href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Fpage&amp;rut=test" class='result-link'>Example &amp; Test</a>
            <td class="result-snippet">An <b>indexed</b> source from <b>the web</b>.</td>
            <a href="javascript:alert(1)" class='result-link'>Invalid result</a>
            """.utf8)
        let results = SearchResults.duckDuckGo(page)
        precondition(results.count == 1)
        precondition(results[0].url.absoluteString == "https://example.org/page")
        precondition(results[0].title == "Example & Test")
        precondition(results[0].snippet == "An indexed source from the web.")
        let rss = Data("""
            <rss version="2.0"><channel><title>Search</title><item>
            <title>A result</title><link>https://example.org/rss</link>
            <description>A &amp; B</description></item></channel></rss>
            """.utf8)
        let feed = SearchResults.bing(rss)
        precondition(feed.count == 1 && feed[0].snippet == "A & B")

        let transcript = ChatArchive(directory: root)
        let first = try await transcript.append(ChatMessage(role: .user, text: "The audio prototype is called Tern."),
                                                to: "audio")
        let evidence = WebEvidence(provider: "DuckDuckGo", sources: results)
        let second = try await transcript.append(ChatMessage(role: .assistant, text: "Tern is a good name.",
                                                            evidence: evidence), to: "audio")
        _ = try await transcript.append(ChatMessage(role: .user, text: "Tern is a bird."), to: "birds")

        let reopened = ChatArchive(directory: root)
        let saved = try await reopened.page(in: "audio", limit: 12)
        precondition(saved == [first, second])
        var updated = second
        updated.text = "Tern uses a sealed cabinet."
        updated.metadata = ReplyMetadata(effort: .deep, quattro: true, finish: .outputLimit)
        try await reopened.updateReply(updated, in: "audio")
        let checkUpdated = try await reopened.page(in: "audio", limit: 1)
        precondition(checkUpdated == [updated])
        let indexed = try await reopened.search("sealed cabinet")
        precondition(indexed.map(\.id) == [second.id])
        let matches = try await reopened.search("prototype called")
        precondition(matches.map(\.id) == [first.id])
        let notes = try await reopened.recall("What was the Tern prototype?", in: "audio", before: second.id)
        precondition(notes.map(\.id) == [first.id])
        let newer = try await reopened.hasNewer(in: "audio", than: first.id)
        precondition(newer)
        let digest = try await reopened.compact(in: "audio", before: second.id + 1)
        precondition(digest.through == second.id && digest.turns == 2 && digest.excerpt(limit: 200).contains("sealed cabinet"))
        let sameDigest = try await reopened.compact(in: "audio", before: second.id + 1)
        precondition(sameDigest == digest)
        try await reopened.delete("audio")
        let remaining = try await reopened.search("Tern")
        precondition(remaining.count == 1 && remaining.first?.conversationID == "birds")

        let fence = String(repeating: "\u{60}", count: 3)
        let reply = ReplyFormat("<think>Plan</think>\nHere it is.\n\(fence)swift\nif true {\n    print(42)\n}\n\(fence)\nDone.")
        precondition(reply.reasoning == "Plan" && reply.reasoningComplete)
        precondition(reply.blocks == [.prose("Here it is."),
                                      .code(language: "swift", text: "if true {\n    print(42)\n}"),
                                      .prose("Done.")])
        precondition(ReplyFormat("\(fence)sh\nls").blocks == [.code(language: "sh", text: "ls")])
        precondition(ReplyFormat("\(fence)sh\nls").hasOpenFence)
        precondition(ReplyContinuation.closeThought("<think>Notes").hasSuffix("</think>\n\n"))
        let repeated = "an exact continuation boundary"
        precondition(ReplyContinuation.removeOverlap(previous: "Before \(repeated)", added: "\(repeated) after") == " after")

        let workspace = ChatWorkspace(root: root.appending(path: "Work"))
        let tools = QuattroTools(archive: reopened, workspace: workspace, searcher: WebSearch())
        let catalog = tools.catalog
        precondition(catalog.tools.count > 1000)
        precondition(Set(catalog.tools.map(\.id)).count == catalog.tools.count)
        let context = ToolContext(conversation: "test", before: .max, web: false, files: [])
        for item in catalog.tools where item.id != "web.search" && item.category != "Files" {
            let call = try ToolCall.parseCommand("/tool \(item.id) \(item.example)")!
            let result = try await tools.execute(call, in: context)
            precondition(!result.text.isEmpty, item.id)
        }
        let conversion = catalog.directConversion("Convert 50 mph to km/h")!
        let speed = try await tools.execute(conversion, in: context)
        precondition(speed.text == "50 mph = 80.4672 km/h")
        let temp = catalog.directConversion("32 °F to °C")!
        let freezing = try await tools.execute(temp, in: context)
        precondition(freezing.text == "32 °F = 0 °C")
        let decimal = catalog.directConversion("2 MB to Mb")!
        precondition(decimal.tool == "convert.storage.megabyte.to.megabit")

        let nested = try await workspace.save("hello\n", name: "a/b/c/d/Notes.txt", conversation: "test")
        let savedText = try await workspace.read(nested.id, conversation: "test")
        precondition(savedText == "hello\n")
        let pdf = try await workspace.save(String(repeating: "Page of notes.\n", count: 190), name: "Notes.pdf", conversation: "test")
        let pdfData = try Data(contentsOf: ChatWorkspace.url(for: pdf, root: root.appending(path: "Work"))!)
        precondition(pdfData.starts(with: "%PDF-".utf8))
        let zip = try await workspace.archive([nested, pdf], name: "Project.zip", conversation: "test")
        let zipPath = ChatWorkspace.url(for: zip, root: root.appending(path: "Work"))!
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        check.arguments = ["-tqq", zipPath.path]
        try check.run()
        check.waitUntilExit()
        precondition(check.terminationStatus == 0)
        do {
            _ = try await workspace.save("bad", name: "../bad.txt", conversation: "test")
            preconditionFailure("Path traversal was accepted")
        } catch is LocalError {}
        do {
            _ = try await workspace.read(nested.id, conversation: "other")
            preconditionFailure("Read a file from another chat")
        } catch is LocalError {}
        let planRequest = try QuattroPlan.projectRequest("Create a website with index.html and css/style.css", explicit: true)!
        let project = QuattroPlan.project(planRequest, output: nil, maximum: 4)
        precondition(project.files.map(\.path) == ["index.html", "css/style.css"])
        try checkFileRouting()
        let firstPass = GenerationMetrics().addingPass(tokens: 11, seconds: 2)
        precondition(firstPass.tokens == 11 && firstPass.tokensPerSecond == 5)
        precondition(firstPass.addingPass(tokens: 1, seconds: 0).tokens == 12)
        let secondPass = firstPass.addingPass(tokens: 8, seconds: 1)
        precondition(secondPass.tokens == 19 && secondPass.tokensPerSecond == 7)
        var liveMetrics = secondPass
        for speed in 1...16 { liveMetrics.recordSpeed(Double(speed)) }
        liveMetrics.recordSpeed(.infinity)
        precondition(liveMetrics.speeds == (5...16).map(Double.init))
        precondition(liveMetrics.addingPass(tokens: 2, seconds: 1).speeds == liveMetrics.speeds)
        precondition(QuattroPlan.looksComplete("{\"a\": 1}", path: "data.json"))
        precondition(!QuattroPlan.looksComplete("{\"a\": ", path: "data.json"))
        try await checkQuattro(tools)
        try await checkLegacy(root)
        try checkCloud()
        if CommandLine.arguments.count == 2 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1])
            let calculator = catalog["math.calculate"]!
            try QuattroPlan.toolGrammar([calculator]).write(to: directory.appending(path: "tool.gbnf"), atomically: true, encoding: .utf8)
            try QuattroPlan.projectGrammar.write(to: directory.appending(path: "project.gbnf"), atomically: true, encoding: .utf8)
        }
        print("Checked reply continuation, migration, compression, web parsers, files, \(catalog.tools.count) callable tools and the Neth Cloud connect layer.")
    }

    private static func checkFileRouting() throws {
        let browserPlan = #"{"name":"Web","files":[{"path":"index.html","purpose":"Browser entry point"}]}"#
        let script = try QuattroPlan.projectRequest("Make a Roblox Studio script for a day-night cycle", explicit: false)!
        precondition(!script.needsManifest)
        precondition(QuattroPlan.project(script, output: browserPlan, maximum: 4).files.map(\.path) == ["Script.luau"])

        let game = try QuattroPlan.projectRequest("Build a Roblox game", explicit: false)!
        precondition(game.needsManifest)
        precondition(QuattroPlan.project(game, output: browserPlan, maximum: 4).files.map(\.path) == ["Script.luau"])

        let native = try QuattroPlan.projectRequest("Write a Python script to parse HTML", explicit: false)!
        precondition(QuattroPlan.project(native, output: nil, maximum: 4).files.map(\.path) == ["Script.py"])

        let browser = try QuattroPlan.projectRequest("Make a browser game", explicit: false)!
        precondition(QuattroPlan.project(browser, output: nil, maximum: 4).files.first?.path == "index.html")

        let named = try QuattroPlan.projectRequest("/file Weather.lua Add a weather cycle", explicit: false)!
        precondition(QuattroPlan.project(named, output: browserPlan, maximum: 4).files.map(\.path) == ["Weather.lua"])

        let unspecified = try QuattroPlan.projectRequest("Create a project", explicit: false)!
        precondition(QuattroPlan.project(unspecified, output: browserPlan, maximum: 4).files.map(\.path) == ["Draft.md"])
    }

    @MainActor
    private static func checkQuattro(_ tools: QuattroTools) async throws {
        let agent = QuattroAgent(tools: tools)
        let task = ChatMessage(id: 41, role: .user, text: "Create a website with index.html and style.css named Site.zip")
        let mode = RunSettings(effort: .balanced, quattro: true, web: false, makeFiles: true)
        var reply = ChatMessage(id: 42, role: .assistant, text: "", metadata: ReplyMetadata(effort: .balanced, quattro: true))
        let first = try await agent.run(reply: &reply, task: task, conversation: "site", historyFiles: [], settings: mode,
            report: { _, _, _ in }, stream: { request, receive in
                precondition(request.history.last?.text.contains("index.html") == true)
                try await receive("<!doctype html>\n<html><body>Saved")
                return .stopped
            }, checkpoint: { _, _ in })
        guard case .handled = first else { preconditionFailure("Quattro did not run file creation.") }
        precondition(reply.metadata?.finish == .stopped && reply.metadata?.files.first?.partial == true)
        let partialID = reply.metadata?.files.first?.id
        var passes = 0
        let resumed = try await agent.run(reply: &reply, task: task, conversation: "site", historyFiles: [], settings: mode,
            report: { _, _, _ in }, stream: { request, receive in
                passes += 1
                if passes == 1 {
                    precondition(request.prefix.hasSuffix("Saved"))
                    try await receive(" draft.</body></html>")
                } else {
                    precondition(request.prefix.isEmpty)
                    try await receive("body { color: #123; }")
                }
                return .complete
            }, checkpoint: { _, _ in })
        guard case .handled = resumed else { preconditionFailure("Quattro did not resume the saved project.") }
        precondition(reply.metadata?.finish == .complete && passes == 2)
        let files = reply.metadata!.files
        precondition(files.map(\.name) == ["index.html", "style.css", "Site.zip"] && files.first?.id == partialID)
        precondition(files.allSatisfy { !$0.partial })
        let html = try await tools.workspace.read(files[0].id, conversation: "site")
        precondition(html.contains("Saved draft.</body></html>"))

        let calculation = ChatMessage(role: .user, text: "Calculate the area of a circle with radius 3.")
        let automatic = RunSettings(effort: .balanced, quattro: true, web: false, makeFiles: false)
        var result = ChatMessage(id: 44, role: .assistant, text: "", metadata: ReplyMetadata(effort: .balanced, quattro: true))
        var calls = 0
        let passed = try await agent.run(reply: &result, task: calculation, conversation: "circle", historyFiles: [],
            settings: automatic, report: { _, _, _ in }, stream: { request, receive in
                precondition(request.grammar != nil)
                calls += 1
                try await receive(calls == 1 ? #"{"tool":"math.circle","arguments":{"radius":3}}"#
                                            : #"{"tool":"answer","arguments":{}}"#)
                return .complete
            }, checkpoint: { _, _ in })
        guard case .answer = passed else { preconditionFailure("Quattro did not pass its tool result back to chat.") }
        precondition(calls == 2 && result.metadata?.trace.first?.detail.contains("28.274333882") == true)
    }

    private static func checkCloud() throws {
        let server = CloudServer(name: "Colab T4",
                                 url: URL(string: "https://neth-test.trycloudflare.com")!,
                                 token: "nl-session-key-123456", model: "gpt-oss-20b")
        precondition(server.isValid && server.id.count == 24)
        let parsed = try CloudServer.parse(server.pairingCode)
        precondition(parsed == server)
        do {
            _ = try CloudServer.parse("NETHCLOUD1.not-a-code")
            preconditionFailure("Invalid cloud code was accepted")
        } catch is LocalError {}
        do {
            _ = try CloudServer.parse("NETH36.ignored-windows-code")
            preconditionFailure("Windows pairing code was accepted as a cloud code")
        } catch is LocalError {}
        let loopback = CloudServer(name: "Dev", url: URL(string: "http://127.0.0.1:8080")!,
                                   token: "nl-session-key-123456", model: "m")
        precondition(loopback.isValid)
        let plainHTTP = CloudServer(name: "Insecure", url: URL(string: "http://10.0.0.5:8080")!,
                                    token: "nl-session-key-123456", model: "m")
        precondition(!plainHTTP.isValid)
        let emptyToken = CloudServer(name: "Empty", url: server.url, token: "short", model: "m")
        precondition(!emptyToken.isValid)

        let content = HarmonyAdapter.parseChunk(#"{"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"#)
        precondition(content?.content == "Hi" && content?.reasoning == nil && content?.finish == nil)
        let reasoning = HarmonyAdapter.parseChunk(#"{"choices":[{"delta":{"reasoning_content":"plan"}}]}"#)
        precondition(reasoning?.reasoning == "plan" && reasoning?.content == nil)
        let roleOnly = HarmonyAdapter.parseChunk(#"{"choices":[{"delta":{"role":"assistant"}}]}"#)
        precondition(roleOnly?.content == nil && roleOnly?.reasoning == nil && roleOnly?.finish == nil)
        let usage = HarmonyAdapter.parseChunk(
            #"{"choices":[{"delta":{},"finish_reason":"length"}],"usage":{"completion_tokens":42}}"#)
        precondition(usage?.finish == "length" && usage?.completionTokens == 42)
        let serverError = HarmonyAdapter.parseChunk(#"{"error":{"message":"CUDA out of memory"}}"#)
        precondition(serverError?.detail == "CUDA out of memory")
        let nameCall = HarmonyAdapter.parseChunk(
            #"{"choices":[{"delta":{"tool_calls":[{"index":3,"function":{"name":"math.add"}}]}}]}"#)
        precondition(nameCall?.toolIndex == 3 && nameCall?.toolName == "math.add")
        let fragmentCall = HarmonyAdapter.parseChunk(
            #"{"choices":[{"delta":{"tool_calls":[{"index":3,"function":{"arguments":"{\"a\":"}}]}}]}"#)
        precondition(fragmentCall?.toolArguments == "{\"a\":")

        let body = try JSONSerialization.jsonObject(with: CloudSession.makeBody(
            CloudRequest(system: "sys", turns: [.init(role: .user, text: "q")], prefix: "part",
                         grammar: "root", limit: 300, reasoningEffort: "medium"),
            model: "gpt-oss-20b")) as! [String: Any]
        let messages = body["messages"] as! [[String: String]]
        precondition(messages.count == 3)
        precondition(messages[0]["role"] == "system" && messages[0]["content"] == "sys")
        precondition(messages[1]["role"] == "user" && messages[1]["content"] == "q")
        precondition(messages[2]["role"] == "assistant" && messages[2]["content"] == "part")
        precondition(body["grammar"] as? String == "root" && body["max_tokens"] as? Int == 300)
        precondition(body["stream"] as? Bool == true && body["cache_prompt"] as? Bool == true)
        precondition((body["chat_template_kwargs"] as? [String: Any])?["reasoning_effort"] as? String == "medium")
        precondition((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
        let plain = try JSONSerialization.jsonObject(with: CloudSession.makeBody(
            CloudRequest(system: "", turns: [CloudTurn(role: .assistant, text: "<think>plan</think>\n\nVisible")]),
            model: nil)) as! [String: Any]
        let plainMessages = plain["messages"] as! [[String: String]]
        precondition(plainMessages.count == 1
                     && plainMessages[0]["content"]?.trimmingCharacters(in: .whitespacesAndNewlines) == "Visible")
        precondition((plain["model"] as? String) == nil && plain["grammar"] == nil)
    }

    private static func checkLegacy(_ root: URL) async throws {
        let directory = root.appending(path: "Legacy")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: "transcripts.sqlite")
        var database: OpaquePointer?
        precondition(sqlite3_open(path.path, &database) == SQLITE_OK)
        let sql = """
            CREATE TABLE conversations (id TEXT PRIMARY KEY, title TEXT NOT NULL, updated_at REAL NOT NULL);
            CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, conversation_id TEXT NOT NULL,
                                   role TEXT NOT NULL, body TEXT NOT NULL, photo TEXT, evidence TEXT, notice TEXT);
            INSERT INTO conversations VALUES ('old', 'Old conversation', 0);
            INSERT INTO messages (conversation_id, role, body) VALUES ('old', 'assistant', 'Legacy response');
            """
        precondition(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let legacy = ChatArchive(directory: directory)
        let page = try await legacy.page(in: "old", limit: 5)
        precondition(page.count == 1 && page.first?.text == "Legacy response" && page.first?.metadata == nil)
        var message = page[0]
        message.text = "A migrated response"
        message.metadata = ReplyMetadata(effort: .balanced, quattro: false, finish: .complete)
        try await legacy.updateReply(message, in: "old")
        let read = try await legacy.page(in: "old", limit: 5)
        precondition(read == [message])
    }
}
