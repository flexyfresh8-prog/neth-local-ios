import SwiftUI
import UIKit

enum NethPalette {
    static let canvas = Color(red: 0.048, green: 0.053, blue: 0.072)
    static let rail = Color(red: 0.074, green: 0.080, blue: 0.111)
    static let surface = Color(red: 0.10, green: 0.112, blue: 0.155)
    static let inset = Color(red: 0.060, green: 0.066, blue: 0.09)
    static let border = Color(red: 0.185, green: 0.194, blue: 0.26)
    static let muted = Color(red: 0.66, green: 0.70, blue: 0.79)
    static let accent = Color(red: 0.77, green: 0.69, blue: 1)
    static let green = Color(red: 0.57, green: 0.92, blue: 0.81)
}

struct ChatMessageRow: View, Equatable {
    let message: ChatMessage
    let streaming: Bool
    let activity: String?
    let allowActions: Bool
    let resume: () -> Void
    let save: (String, String) -> Void

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
                .foregroundStyle(.white)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(NethPalette.accent.opacity(0.13), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(NethPalette.accent.opacity(0.14)))
        .frame(maxWidth: 570, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var assistantMessage: some View {
        let content = ReplyFormat(message.text)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: message.metadata?.quattro == true ? "square.grid.2x2" : "waveform")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(NethPalette.accent)
                .frame(width: 29, height: 29)
                .background(NethPalette.accent.opacity(0.12), in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 13) {
                if let notice = message.notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(NethPalette.muted)
                }
                if message.text.isEmpty && streaming {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(activity ?? "Preparing…").font(.subheadline)
                    }
                    .foregroundStyle(NethPalette.muted)
                    .padding(.vertical, 5)
                }
                if let thought = content.reasoning, !thought.isEmpty {
                    DisclosureGroup(streaming && !content.reasoningComplete ? "Thinking…" : "Reasoning") {
                        Text(verbatim: thought)
                            .foregroundStyle(NethPalette.muted)
                            .textSelection(.enabled)
                            .padding(.top, 7)
                    }
                    .font(.footnote)
                }
                ForEach(Array(content.blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .prose(let prose):
                        Text((try? AttributedString(markdown: prose,
                                                   options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                             ?? AttributedString(prose))
                            .textSelection(.enabled)
                            .lineSpacing(4)
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
                                        .foregroundStyle(item.failed ? NethPalette.accent : NethPalette.green)
                                    Text(verbatim: item.detail)
                                        .foregroundStyle(NethPalette.muted)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.top, 7)
                        } label: {
                            Label("Quattro activity · \(metadata.trace.count)", systemImage: "square.grid.2x2")
                        }
                        .font(.footnote)
                    }
                }
                if !content.answer.isEmpty && !streaming {
                    HStack(spacing: 8) {
                        CopyControl(content: content.answer, accessibilityTitle: "Copy reply", compact: true)
                        Button { save(content.answer, "Reply.md") } label: {
                            Label("Save as file", systemImage: "doc.badge.plus")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(!allowActions)
                    }
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
            .padding(.top, 3)
        }
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
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                Text("[\(index + 1)]  \(source.url.host ?? source.url.absoluteString)")
                                    .font(.caption2)
                                    .foregroundStyle(NethPalette.muted)
                                    .lineLimit(1)
                            }
                            .frame(width: 171, height: 46, alignment: .leading)
                            .padding(8)
                            .background(NethPalette.surface, in: .rect(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(NethPalette.border))
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
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(NethPalette.accent)
                    .accessibilityHidden(true)
                Text(verbatim: language).font(.system(.caption, design: .monospaced))
                Spacer()
                if allowSave && !code.isEmpty {
                    Button(action: save) {
                        Image(systemName: "doc.badge.plus").frame(width: 36, height: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Save code as file")
                }
                CopyControl(content: code, accessibilityTitle: "Copy \(language) code", compact: false)
            }
            .font(.caption)
            .foregroundStyle(NethPalette.muted)
            .padding(.horizontal, 12)
            .frame(minHeight: 42)
            .background(NethPalette.surface)
            Divider().overlay(NethPalette.border)
            ScrollView(.horizontal) {
                Text(verbatim: code)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.94))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(13)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NethPalette.inset)
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NethPalette.border))
    }
}

private struct CopyControl: View {
    let content: String
    let accessibilityTitle: String
    let compact: Bool
    @State private var copiedAt: Date?

    var body: some View {
        Button {
            UIPasteboard.general.string = content
            copiedAt = Date()
        } label: {
            Label(copiedAt != nil ? "Copied" : compact ? "Copy reply" : "Copy",
                  systemImage: copiedAt != nil ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.semibold))
                .foregroundStyle(copiedAt != nil ? NethPalette.green : NethPalette.muted)
                .padding(.horizontal, 7)
                .frame(minHeight: compact ? 34 : 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(content.isEmpty)
        .accessibilityLabel(copiedAt == nil ? accessibilityTitle : "Copied")
        .task(id: copiedAt) {
            guard copiedAt != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copiedAt = nil }
        }
    }
}
