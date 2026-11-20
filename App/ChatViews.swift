import SwiftUI
import UIKit

struct ChatMessageRow: View, Equatable {
    let message: ChatMessage
    let streaming: Bool
    let activity: String?
    let allowActions: Bool
    let resume: () -> Void
    let save: (String, String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.streaming == rhs.streaming && lhs.activity == rhs.activity
            && lhs.allowActions == rhs.allowActions
    }

    var body: some View {
        if message.role == .user {
            userMessage
        } else {
            assistantMessage
        }
    }

    private var userMessage: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let photo = message.photo, let preview = UIImage(contentsOfFile: photo.path) {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 200, alignment: .leading)
                    .clipShape(.rect(cornerRadius: 10))
                    .accessibilityLabel("Attached photo")
            }
            Text(verbatim: message.text)
                .foregroundStyle(NethPalette.text)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
        .background(LinearGradient(colors: [NethPalette.violetSurface.opacity(0.90), NethPalette.surface],
                                   startPoint: .topTrailing, endPoint: .bottomLeading), in: .rect(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17)
            .strokeBorder(NethPalette.violet.opacity(0.14))
            .allowsHitTesting(false))
        .frame(maxWidth: 550, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var assistantMessage: some View {
        let content = ReplyFormat(message.text)
        return VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                NethMascotMark(active: streaming)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(streaming ? NethPalette.violetSurface : NethPalette.rail, in: .rect(cornerRadius: 6))
                Text(message.metadata?.quattro == true ? "Quattro" : "Neth Local")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            if let notice = message.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(NethPalette.muted)
            }
            if message.text.isEmpty && streaming {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small).tint(NethPalette.violet)
                    Text(activity ?? "Preparing…").font(.subheadline)
                }
                .foregroundStyle(NethPalette.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(NethPalette.rail, in: .capsule)
                .transition(reduceMotion ? .identity : .opacity)
            }
            if let thought = content.reasoning, !thought.isEmpty {
                DisclosureGroup(streaming && !content.reasoningComplete ? "Thinking…" : "Reasoning") {
                    Text(verbatim: thought)
                        .foregroundStyle(NethPalette.muted)
                        .textSelection(.enabled)
                        .padding(.top, 6)
                }
                .font(.footnote)
            }
            ForEach(Array(content.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let prose):
                    Text((try? AttributedString(markdown: prose,
                                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                         ?? AttributedString(prose))
                        .foregroundStyle(NethPalette.text)
                        .textSelection(.enabled)
                        .lineSpacing(5)
                case .code(let language, let code):
                    CodePanel(language: language, code: code, allowSave: allowActions && !streaming) {
                        save(code, "Snippet.\(Self.extensionForLanguage(language))")
                    }
                }
            }
            if let evidence = message.evidence { sources(evidence) }
            if let metadata = message.metadata {
                ForEach(metadata.files) { WorkspaceFileCard(file: $0) }
                if !metadata.trace.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(metadata.trace) { item in
                                Label(item.title, systemImage: item.failed ? "exclamationmark.circle" : "checkmark.circle")
                                Text(verbatim: item.detail)
                                    .foregroundStyle(NethPalette.muted)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Label("Quattro activity · \(metadata.trace.count)", systemImage: "square.grid.2x2")
                    }
                    .font(.footnote)
                }
            }
            if !content.answer.isEmpty && !streaming {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { replyActions(content.answer) }
                    VStack(alignment: .leading, spacing: 3) { replyActions(content.answer) }
                }
                .transition(reduceMotion ? .identity : NethMotion.rise)
            }
            if !streaming, let reason = message.metadata?.finish.label ?? (content.hasOpenFence ? "Open code block" : nil) {
                ViewThatFits(in: .horizontal) {
                    HStack { Text(verbatim: reason); resumeButton }
                    VStack(alignment: .leading, spacing: 5) { Text(verbatim: reason); resumeButton }
                }
                .font(.caption)
                .foregroundStyle(NethPalette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : NethMotion.fade, value: message.text.isEmpty)
        .animation(reduceMotion ? nil : NethMotion.reveal, value: streaming)
    }

    @ViewBuilder
    private func replyActions(_ answer: String) -> some View {
        CopyControl(content: answer, accessibilityTitle: "Copy reply", compact: true)
        Button { save(answer, "Reply.md") } label: {
            Label("Save as file", systemImage: "doc.badge.plus")
                .font(.caption.weight(.medium))
                .foregroundStyle(NethPalette.muted)
                .padding(.horizontal, 7)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(NethPress())
        .disabled(!allowActions)
    }

    private static func extensionForLanguage(_ language: String) -> String {
        let label = language.lowercased()
        let aliases = ["javascript": "js", "typescript": "ts", "python": "py", "bash": "sh",
                       "shell": "sh", "rust": "rs", "c++": "cpp", "markdown": "md", "kotlin": "kt",
                       "csharp": "cs", "golang": "go", "powershell": "ps1"]
        let ext = aliases[label] ?? label
        return ChatWorkspace.supportedExtensions.contains(ext) ? ext : "txt"
    }

    private var resumeButton: some View {
        Button(action: resume) {
            Label("Continue", systemImage: "arrow.right.circle")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .disabled(!allowActions)
    }

    private func sources(_ evidence: WebEvidence) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Sources · \(evidence.provider)", systemImage: "link")
                .font(.caption.weight(.medium))
                .foregroundStyle(NethPalette.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(evidence.sources.enumerated()), id: \.offset) { index, source in
                        Link(destination: source.url) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: source.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(NethPalette.text)
                                    .lineLimit(2)
                                Text("[\(index + 1)]  \(source.url.host ?? source.url.absoluteString)")
                                    .font(.caption2)
                                    .foregroundStyle(NethPalette.muted)
                                    .lineLimit(1)
                            }
                            .frame(width: 170, alignment: .leading)
                            .padding(10)
                            .frame(minHeight: 60, alignment: .leading)
                            .background(NethPalette.inset, in: .rect(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(NethPalette.border)
                                .allowsHitTesting(false))
                        }
                    }
                }
            }
        }
    }
}

private struct CodePanel: View {
    let language: String
    let code: String
    let allowSave: Bool
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: language).font(.system(.caption, design: .monospaced))
                Spacer()
                if allowSave && !code.isEmpty {
                    Button(action: save) {
                        Image(systemName: "doc.badge.plus")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(NethPress())
                    .accessibilityLabel("Save code as file")
                }
                CopyControl(content: code, accessibilityTitle: "Copy \(language) code", compact: false)
            }
            .font(.caption)
            .foregroundStyle(NethPalette.muted)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(NethPalette.surface)
            Rectangle().fill(NethPalette.border).frame(height: 1)
            ScrollView(.horizontal) {
                Text(verbatim: code)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(NethPalette.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(13)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NethPalette.inset)
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NethPalette.border).allowsHitTesting(false))
    }
}

private struct CopyControl: View {
    let content: String
    let accessibilityTitle: String
    let compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copiedAt: Date?

    var body: some View {
        Button {
            UIPasteboard.general.string = content
            copiedAt = Date()
        } label: {
            Label(copiedAt != nil ? "Copied" : compact ? "Copy reply" : "Copy",
                  systemImage: copiedAt != nil ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.medium))
                .foregroundStyle(copiedAt != nil ? NethPalette.lilac : NethPalette.muted)
                .padding(.horizontal, 7)
                .frame(minHeight: 44)
                .background(copiedAt != nil ? NethPalette.violetSurface : .clear, in: .rect(cornerRadius: 8))
                .contentTransition(.opacity)
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : NethMotion.fade, value: copiedAt != nil)
        }
        .buttonStyle(NethPress())
        .disabled(content.isEmpty)
        .accessibilityLabel(copiedAt == nil ? accessibilityTitle : "Copied")
        .task(id: copiedAt) {
            guard copiedAt != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copiedAt = nil }
        }
    }
}
