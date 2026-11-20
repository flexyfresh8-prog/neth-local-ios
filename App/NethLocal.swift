import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@main
struct NethLocalApp: App {
    var body: some Scene {
        WindowGroup {
            ChatScreen()
                .preferredColorScheme(.dark)
                .tint(NethPalette.accent)
        }
    }
}

@MainActor
private struct ChatScreen: View {
    private enum Sheet: String, Identifiable {
        case history, search, models, tools
        var id: Self { self }
    }

    @StateObject private var models = LocalModels()
    @StateObject private var chat = LocalChat()
    @AppStorage("contextSize") private var context = 4096
    @AppStorage("cpuOnly") private var cpuOnly = false
    @AppStorage("thinking") private var thinking = false
    @AppStorage("cachePrecision") private var cache = CachePrecision.automatic
    @AppStorage("compactHistory") private var compactHistory = true
    @AppStorage("effortPreset") private var effort = EffortPreset.balanced
    @AppStorage("quattroEnabled") private var quattro = false
    @Environment(\.scenePhase) private var scene
    @FocusState private var typing: Bool
    @State private var draft = ""
    @State private var web = false
    @State private var makeFiles = false
    @State private var showSidebar = true
    @State private var sheet: Sheet?
    @State private var deleting: Conversation?
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: URL?
    @State private var loadingPhoto = false
    @State private var nearBottom = true
    @State private var exporting: ChatMessage?
    @State private var exportName = "Reply.md"

    private var canAttach: Bool { models.current?.isPreset == true && models.projector != nil }
    private var busy: Bool { chat.running || chat.opening }
    private var canSend: Bool {
        !busy && !loadingPhoto && (models.current != nil || quattro)
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photo != nil)
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 835
            HStack(spacing: 0) {
                if wide && showSidebar {
                    sidebar(inSheet: false).frame(width: 246)
                    Rectangle().fill(NethPalette.border).frame(width: 1)
                }
                VStack(spacing: 0) {
                    header(wide: wide)
                    Rectangle().fill(NethPalette.border).frame(height: 1)
                    if chat.messages.isEmpty { startScreen } else { transcript }
                    composer
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NethPalette.canvas)
            }
        }
        .background(NethPalette.canvas.ignoresSafeArea())
        .task { await chat.restore() }
        .sheet(item: $sheet) { selected in
            switch selected {
            case .history: sidebar(inSheet: true).presentationDetents([.large])
            case .search:
                ChatSearchPanel(search: chat.search) { hit in
                    changeChat(hit.conversationID, at: hit.id)
                }
                .presentationDetents([.large])
            case .models:
                ModelPanel(models: models, context: $context, cpuOnly: $cpuOnly,
                           thinking: $thinking, cache: $cache, compactHistory: $compactHistory,
                           active: chat.profile, inferenceBusy: busy) { chat.unload() }
            case .tools:
                QuattroPanel { tool in
                    quattro = true
                    if tool.id == "web.search" { web = true }
                    draft = "/tool \(tool.id) \(tool.example)"
                    typing = true
                }
            }
        }
        .alert("Delete chat?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { selection in
                Button("Delete", role: .destructive) { Task { await chat.remove(selection) } }
                Button("Cancel", role: .cancel) {}
            } message: { selection in
                Text("“\(selection.title)” and its attachments will be deleted from this iPad.")
            }
        .alert("Neth Local", isPresented: Binding(
            get: { chat.problem != nil }, set: { if !$0 { chat.problem = nil } })) {
                Button("OK", role: .cancel) { chat.problem = nil }
            } message: {
                Text(chat.problem ?? "")
            }
        .onChange(of: photoItem) { _, item in if let item { preparePhoto(item) } }
        .onChange(of: models.selectedID) { _, _ in
            chat.unload()
            if !canAttach { clearAttachment() }
        }
        .alert("Save reply", isPresented: Binding(
            get: { exporting != nil }, set: { if !$0 { exporting = nil } }), presenting: exporting) { reply in
                TextField("Filename", text: $exportName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save") {
                    let name = exportName
                    Task { await chat.saveReply(reply, as: name) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in Text("Enter a filename such as Notes.md, Notes.txt or Notes.pdf.") }
        .onChange(of: models.projector) { _, _ in if !canAttach { clearAttachment() } }
        .onChange(of: scene) { _, phase in if phase == .background { chat.unload() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            chat.unload()
        }
    }

    private func sidebar(inSheet: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "waveform")
                    .foregroundStyle(NethPalette.accent)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(NethPalette.accent.opacity(0.11), in: .rect(cornerRadius: 9))
                    .accessibilityHidden(true)
                Text("Neth Local").font(.title3.weight(.semibold))
                Spacer()
                if inSheet {
                    Button("Done") { sheet = nil }
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.bottom, 6)

            Button(action: newChat) {
                Label("New chat", systemImage: "square.and.pencil")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NethPalette.canvas)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(NethPalette.accent, in: .rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .opacity(busy ? 0.55 : 1)
            .keyboardShortcut("n", modifiers: .command)

            Button { sheet = .search } label: {
                Label("Search chats", systemImage: "magnifyingglass")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(NethPalette.muted)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(NethPalette.inset, in: .rect(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(NethPalette.border))
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .keyboardShortcut("f", modifiers: .command)

            Button { sheet = .tools } label: {
                Label("Quattro tools", systemImage: "square.grid.2x2")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(NethPalette.green)
                    .frame(maxWidth: .infinity, minHeight: 39, alignment: .leading)
                    .padding(.horizontal, 9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)

            if !chat.conversations.isEmpty {
                Text("Recents")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NethPalette.muted)
                    .padding(.horizontal, 6)
                    .padding(.top, 7)
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(chat.conversations) { thread in
                        threadRow(thread)
                    }
                }
            }
            .scrollIndicators(.hidden)

            Rectangle().fill(NethPalette.border).frame(height: 1)
            Button { sheet = .models } label: {
                Label("Models & context", systemImage: "slider.horizontal.3")
                    .foregroundStyle(NethPalette.muted)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 17)
        .frame(maxHeight: .infinity)
        .background(NethPalette.rail.ignoresSafeArea(edges: .vertical))
    }

    private func threadRow(_ thread: Conversation) -> some View {
        let selected = thread.id == chat.conversationID
        return Button { changeChat(thread.id) } label: {
            HStack(spacing: 9) {
                Image(systemName: "bubble.left").font(.caption)
                    .foregroundStyle(selected ? NethPalette.accent : NethPalette.muted)
                Text(verbatim: thread.title)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.8))
                    .lineLimit(1)
                Spacer(minLength: 2)
            }
            .frame(minHeight: 39)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(selected ? NethPalette.accent.opacity(0.13) : .clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button(role: .destructive) { deleting = thread } label: {
                Label("Delete chat", systemImage: "trash")
            }
            .disabled(busy)
        }
    }

    private func header(wide: Bool) -> some View {
        HStack(spacing: 10) {
            iconControl("Chat sidebar", symbol: "sidebar.left") {
                if wide {
                    withAnimation(.easeInOut(duration: 0.19)) { showSidebar.toggle() }
                } else { sheet = .history }
            }
            if !wide {
                iconControl("Search chats", symbol: "magnifyingglass") { sheet = .search }
                    .disabled(busy)
                    .keyboardShortcut("f", modifiers: .command)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: chat.title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(.white)
                Text(verbatim: models.current?.isPreset == true ? "Qwen3.5 · 4B" : models.current?.title ?? "Neth Local")
                    .font(.caption)
                    .foregroundStyle(NethPalette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let runtime = chat.profile {
                VStack(alignment: .trailing, spacing: 3) {
                    if let rate = chat.tokensPerSecond, !chat.running {
                        Text(String(format: "%.1f tok/s", rate))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(NethPalette.green)
                    }
                    Text(verbatim: runtime.detail)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(NethPalette.muted)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
            iconControl("New chat", symbol: "square.and.pencil", action: newChat).disabled(busy)
            iconControl("Models & context", symbol: "slider.horizontal.3") { sheet = .models }
        }
        .padding(.horizontal, wide ? 23 : 10)
        .frame(height: 63)
        .background(NethPalette.rail.opacity(0.24))
    }

    private func iconControl(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(NethPalette.accent)
                .frame(width: 43, height: 43)
                .background(NethPalette.surface, in: .rect(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var startScreen: some View {
        VStack(spacing: 15) {
            Image(systemName: "waveform")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(NethPalette.accent)
                .frame(width: 91, height: 91)
                .background(NethPalette.accent.opacity(0.12), in: .rect(cornerRadius: 27))
                .overlay(RoundedRectangle(cornerRadius: 27).strokeBorder(NethPalette.accent.opacity(0.19)))
                .accessibilityHidden(true)
            Text(models.current == nil ? "Choose a model" : "Start a conversation")
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            if models.current == nil {
                Text("Download Qwen3.5 4B or import a GGUF to chat on-device.")
                    .font(.subheadline)
                    .foregroundStyle(NethPalette.muted)
                    .multilineTextAlignment(.center)
                Button("Browse models") { sheet = .models }
                    .buttonStyle(.borderedProminent)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { quickActions }
                    VStack(spacing: 9) { quickActions }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var quickActions: some View {
        Button {
            quattro = true
            makeFiles = true
            typing = true
        } label: {
            Label("Create files", systemImage: "doc.badge.plus")
        }
        .buttonStyle(.bordered)
        Button {
            web = true
            typing = true
        } label: {
            Label("Search the web", systemImage: "globe")
        }
        .buttonStyle(.bordered)
    }

    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if chat.hasEarlier {
                        Button {
                            Task {
                                if let previous = await chat.loadEarlier() { reader.scrollTo(previous, anchor: .top) }
                            }
                        } label: {
                            Label("Load earlier messages", systemImage: "arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(NethPalette.accent)
                        .disabled(busy)
                    }
                    ForEach(chat.messages) { message in
                        let active = message.id == chat.activeReplyID && chat.running
                        ChatMessageRow(message: message, streaming: active, activity: active ? chat.activity : nil,
                                       allowActions: !busy,
                                       resume: { continueReply(message) }, save: { saveReply(message) })
                            .equatable()
                            .id(message.id)
                    }
                    if chat.hasLater, let id = chat.conversationID {
                        Button("Jump to latest") {
                            nearBottom = true
                            Task {
                                await chat.open(id)
                                reader.scrollTo("latest", anchor: .bottom)
                            }
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    }
                    Color.clear.frame(height: 1).id("latest")
                }
                .padding(.horizontal, 19)
                .padding(.vertical, 22)
                .frame(maxWidth: 842)
                .frame(maxWidth: .infinity)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY <= 170
            } action: { _, close in nearBottom = close }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.messages.last?.text) { _, _ in
                if nearBottom && !chat.hasLater && chat.targetMessage == nil { reader.scrollTo("latest", anchor: .bottom) }
            }
            .onChange(of: chat.activeReplyID) { _, active in
                if let active, active != chat.messages.last?.id { reader.scrollTo(active, anchor: .center) }
            }
            .onChange(of: chat.messages.last?.id) { _, _ in
                if (nearBottom || chat.running) && !chat.hasLater && chat.targetMessage == nil {
                    reader.scrollTo("latest", anchor: .bottom)
                }
            }
            .task(id: chat.targetMessage) {
                if let target = chat.targetMessage {
                    await Task.yield()
                    reader.scrollTo(target, anchor: .center)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !nearBottom && !chat.hasLater {
                    iconControl("Scroll to latest", symbol: "arrow.down") {
                        nearBottom = true
                        reader.scrollTo("latest", anchor: .bottom)
                    }
                    .padding(12)
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            EffortMeter(preset: chat.activeEffort ?? effort, activity: chat.running ? chat.activity : nil,
                        step: chat.effortStep, total: chat.effortTotal)
                .padding(.horizontal, 15)
                .padding(.top, 11)
                .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 8) {
                if let photo, let preview = UIImage(contentsOfFile: photo.path) {
                    HStack {
                        Image(uiImage: preview).resizable().scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(.rect(cornerRadius: 9))
                        Button("Remove photo", systemImage: "xmark.circle.fill") { clearAttachment() }
                            .labelStyle(.iconOnly)
                    }
                    .padding(.horizontal, 7)
                }
                TextField(models.current == nil && !quattro ? "Choose a model to start" : quattro ? "Message Quattro" : "Message Neth Local",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...7)
                    .focused($typing)
                    .disabled(models.current == nil && !quattro)
                    .padding(.horizontal, 9)
                    .padding(.top, 4)
                    .frame(minHeight: 35)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        attachControl
                        modeButtons
                        Spacer(minLength: 2)
                        effortMenu
                        sendControl
                    }
                    VStack(spacing: 2) {
                        HStack(spacing: 6) { modeButtons; Spacer(minLength: 0) }
                        HStack(spacing: 6) { attachControl; Spacer(minLength: 1); effortMenu; sendControl }
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 8)
        }
        .background(NethPalette.surface, in: .rect(cornerRadius: 23))
        .overlay(RoundedRectangle(cornerRadius: 23)
            .strokeBorder(typing ? NethPalette.accent.opacity(0.43) : NethPalette.border))
        .frame(maxWidth: 795)
        .padding(.horizontal, 14)
        .padding(.bottom, 13)
    }

    @ViewBuilder
    private var modeButtons: some View {
        chip("Quattro", icon: "square.grid.2x2", active: quattro) {
            quattro.toggle()
            if !quattro { makeFiles = false }
        }
        .accessibilityHint("Enable the on-device tool agent for the main chat.")
        chip("Web", icon: "globe", active: web) { web.toggle() }
            .accessibilityHint("Send the next search query to the web search provider.")
        chip("Files", icon: "doc.badge.plus", active: makeFiles) {
            makeFiles.toggle()
            if makeFiles { quattro = true }
        }
        .accessibilityHint("Create files from the next message.")
    }

    private func chip(_ label: String, icon: String, active: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            Label(label, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(active ? NethPalette.green : NethPalette.muted)
                .padding(.horizontal, 8)
                .frame(minHeight: 40)
                .background(active ? NethPalette.green.opacity(0.13) : NethPalette.inset, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(active ? NethPalette.green.opacity(0.34) : NethPalette.border))
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityValue(active ? "On" : "Off")
    }

    private var attachControl: some View {
        Menu {
            if canAttach {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Attach a photo", systemImage: "photo")
                }
            }
            Button {
                makeFiles = true
                quattro = true
                typing = true
            } label: { Label("Create files with Quattro", systemImage: "doc.badge.plus") }
            Button { sheet = .tools } label: {
                Label("Browse \(ToolCatalog.shared.tools.count.formatted()) tools", systemImage: "square.grid.2x2")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(NethPalette.accent)
                .frame(width: 39, height: 43)
        }
        .accessibilityLabel("Add to message")
        .disabled(busy || loadingPhoto)
    }

    private var effortMenu: some View {
        Menu {
            ForEach(EffortPreset.allCases) { item in
                Button { effort = item } label: {
                    if effort == item {
                        Label(item.title, systemImage: "checkmark")
                    } else {
                        Text(item.title)
                    }
                }
            }
            Text(effort.description)
        } label: {
            HStack(spacing: 5) {
                Text(effort.title).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(NethPalette.accent)
            .frame(minHeight: 41)
            .padding(.horizontal, 5)
            .fixedSize(horizontal: true, vertical: false)
        }
        .disabled(busy)
        .accessibilityLabel("Effort")
    }

    @ViewBuilder
    private var sendControl: some View {
        if chat.running {
            Button { chat.stop() } label: {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.white)
                    .frame(width: 43, height: 43)
                    .background(NethPalette.border, in: .rect(cornerRadius: 12))
            }
            .accessibilityLabel("Stop and keep progress")
            .buttonStyle(.plain)
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(canSend ? NethPalette.canvas : NethPalette.muted)
                    .frame(width: 43, height: 43)
                    .background(canSend ? NethPalette.accent : NethPalette.border, in: .rect(cornerRadius: 12))
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private func send() {
        guard canSend else { return }
        let text = draft.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.utf8.count > 280_000 {
            chat.problem = "This message is too long for the available context."
            return
        }
        guard !text.isEmpty || photo != nil else { return }
        let allowWeb = !text.isEmpty && (web || (quattro && QuattroPlan.requestsWeb(text)))
        let run = RunSettings(effort: effort, quattro: quattro, web: allowWeb, makeFiles: makeFiles)
        chat.send(text.isEmpty ? "Describe this image." : text, photo: photo,
                  runSettings: run, settings: engineSettings)
        photo = nil
        photoItem = nil
        web = false
        makeFiles = false
        draft = ""
        typing = false
        nearBottom = true
    }

    private var engineSettings: EngineSettings? {
        guard let model = models.current else { return nil }
        return EngineSettings(model: model, projector: canAttach ? models.projector : nil,
                              context: context, cpuOnly: cpuOnly, thinking: thinking,
                              cache: cache, compactHistory: compactHistory)
    }

    private func continueReply(_ reply: ChatMessage) {
        typing = false
        chat.resume(reply, effort: effort, settings: engineSettings)
    }

    private func saveReply(_ reply: ChatMessage) {
        exportName = "Reply.md"
        exporting = reply
    }

    private func newChat() {
        chat.newChat()
        resetComposer()
        sheet = nil
        if models.current != nil { typing = true }
    }

    private func changeChat(_ id: String, at message: Int64? = nil) {
        resetComposer()
        sheet = nil
        Task { await chat.open(id, at: message) }
    }

    private func resetComposer() {
        draft = ""
        web = false
        makeFiles = false
        nearBottom = true
        clearAttachment()
    }

    private func clearAttachment() {
        if let photo { try? FileManager.default.removeItem(at: photo) }
        photo = nil
        photoItem = nil
    }

    private func preparePhoto(_ item: PhotosPickerItem) {
        loadingPhoto = true
        Task {
            defer { loadingPhoto = false }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw LocalError(message: "Photos did not return an image.")
                }
                let path = try await Task.detached(priority: .utility) { try Self.thumbnail(data) }.value
                guard canAttach, photoItem == item else {
                    try? FileManager.default.removeItem(at: path)
                    return
                }
                if let photo { try? FileManager.default.removeItem(at: photo) }
                photo = path
            } catch { chat.problem = error.localizedDescription }
        }
    }

    private nonisolated static func thumbnail(_ data: Data) throws -> URL {
        let issue = LocalError(message: "Couldn't prepare this photo.")
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw issue }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 448
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw issue }
        let path = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(path as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw issue }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw issue }
        return path
    }
}

@MainActor
private struct ChatSearchPanel: View {
    let search: (String) async throws -> [TranscriptMatch]
    let open: (TranscriptMatch) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var matches: [TranscriptMatch] = []
    @State private var searched = false
    @State private var issue: String?

    var body: some View {
        NavigationStack {
            List(matches) { hit in
                Button { open(hit) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: hit.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .lineLimit(1)
                        Text(verbatim: hit.excerpt).font(.footnote).foregroundStyle(NethPalette.muted)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 4)
                }
            }
            .scrollContentBackground(.hidden)
            .background(NethPalette.canvas)
            .overlay {
                if let issue {
                    ContentUnavailableView("Search unavailable", systemImage: "exclamationmark.magnifyingglass",
                                           description: Text(issue))
                } else if searched && matches.isEmpty {
                    ContentUnavailableView("No matches", systemImage: "magnifyingglass")
                }
            }
            .navigationTitle("Search chats")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Words in your chats")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task(id: query) {
            searched = false
            issue = nil
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { matches = []; return }
            do {
                try await Task.sleep(for: .milliseconds(160))
                let found = try await search(text)
                try Task.checkCancellation()
                matches = found
                searched = true
            } catch is CancellationError {
            } catch { issue = error.localizedDescription }
        }
    }
}
