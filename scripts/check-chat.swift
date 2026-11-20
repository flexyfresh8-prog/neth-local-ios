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
        precondition(QuattroPlan.looksComplete("{\"a\": 1}", path: "data.json"))
        precondition(!QuattroPlan.looksComplete("{\"a\": ", path: "data.json"))
        try await checkLegacy(root)
        if CommandLine.arguments.count == 2 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1])
            let calculator = catalog["math.calculate"]!
            try QuattroPlan.toolGrammar([calculator]).write(to: directory.appending(path: "tool.gbnf"), atomically: true, encoding: .utf8)
            try QuattroPlan.projectGrammar.write(to: directory.appending(path: "project.gbnf"), atomically: true, encoding: .utf8)
        }
        print("Checked reply continuation, migration, compression, web parsers, files and \(catalog.tools.count) callable tools.")
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
