import Foundation

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
        let matches = try await reopened.search("prototype called")
        precondition(matches.map(\.id) == [first.id])
        let notes = try await reopened.recall("What was the Tern prototype?", in: "audio", before: second.id)
        precondition(notes.map(\.id) == [first.id])
        let newer = try await reopened.hasNewer(in: "audio", than: first.id)
        precondition(newer)
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
        print("Verified chat storage, scoped history recall, web result parsers and code copying.")
    }
}
