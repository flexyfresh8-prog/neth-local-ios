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
                .tint(NethPalette.text)
        }
    }
}

@MainActor
private struct ChatScreen: View {
    private struct FileExport {
        let message: ChatMessage
        let text: String
    }

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
    @AppStorage("promptCacheMode") private var promptCache = PromptCacheMode.storage
    @AppStorage("effortPreset") private var effort = EffortPreset.balanced
    @AppStorage("quattroEnabled") private var quattro = false
    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
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
    @State private var exporting: FileExport?
    @State private var exportName = "Reply.md"

    private let readingWidth: CGFloat = 756

    private var canAttach: Bool { models.current?.isPreset == true && models.projector != nil }
    private var busy: Bool { chat.running || chat.opening }
    private var canSend: Bool {
        !busy && !loadingPhoto && (models.current != nil || quattro)
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photo != nil)
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 840 && !typeSize.isAccessibilitySize
            let railVisible = wide && showSidebar
            HStack(spacing: 0) {
                if railVisible {
                    sidebar(inSheet: false)
                        .frame(width: 226)
                        .overlay(alignment: .trailing) { Rectangle().fill(NethPalette.border.opacity(0.7)).frame(width: 1) }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                VStack(spacing: 0) {
                    header(wide: wide, railVisible: railVisible)
                    Rectangle().fill(NethPalette.border.opacity(0.65)).frame(height: 1)
                    ZStack {
                        if chat.messages.isEmpty {
                            startScreen.transition(.opacity)
                        } else {
                            transcript.transition(.opacity)
                        }
                    }
                    .animation(reduceMotion ? nil : NethMotion.fade, value: chat.messages.isEmpty)
                    composer
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NethPalette.canvas)
                .zIndex(1)
            }
            .animation(reduceMotion ? nil : NethMotion.reveal, value: railVisible)
        }
        .foregroundStyle(NethPalette.text)
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
                           promptCache: $promptCache, active: chat.profile, metrics: chat.promptMetrics,
                           checkpointNotice: chat.checkpointNotice, inferenceBusy: busy,
                           unload: { chat.unload() }, saveAndUnload: { await chat.saveAndUnload() },
                           clearCheckpoints: { await chat.clearPromptCheckpoints() })
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
                    Task { await chat.saveReply(reply.message, text: reply.text, as: name) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in Text("Enter a filename such as Notes.md, Notes.txt or Notes.pdf.") }
        .onChange(of: models.projector) { _, _ in if !canAttach { clearAttachment() } }
        .onChange(of: context) { _, _ in chat.unload() }
        .onChange(of: cache) { _, _ in chat.unload() }
        .onChange(of: cpuOnly) { _, _ in chat.unload() }
        .onChange(of: promptCache) { _, mode in chat.setPromptCache(mode) }
        .onChange(of: scene) { _, phase in
            if phase == .background {
                if promptCache == .storage { chat.background() } else { chat.unload() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            chat.unload()
        }
    }

    private func sidebar(inSheet: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                NethMascotMark()
                Text("Neth Local").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if inSheet {
                    Button("Done") { sheet = nil }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                }
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 34)

            VStack(spacing: 3) {
                sidebarAction("New chat", symbol: "plus", prominent: true, action: newChat)
                    .keyboardShortcut("n", modifiers: .command)
                sidebarAction("Search chats", symbol: "magnifyingglass") { sheet = .search }
                    .keyboardShortcut("f", modifiers: .command)
                sidebarAction("Quattro tools", symbol: "square.grid.2x2") { sheet = .tools }
            }

            if !chat.conversations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent chats")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(NethPalette.muted)
                        .padding(.horizontal, 9)
                        .accessibilityAddTraits(.isHeader)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(chat.conversations) { thread in threadRow(thread) }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(NethPalette.rail.ignoresSafeArea(edges: .vertical))
    }

    private func sidebarAction(_ title: String, symbol: String, prominent: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18).accessibilityHidden(true)
                Text(title)
            }
            .font(.subheadline.weight(prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? NethPalette.text : NethPalette.muted)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(prominent ? NethPalette.selected : .clear, in: .rect(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(NethPress())
        .disabled(busy)
    }

    private func threadRow(_ thread: Conversation) -> some View {
        let selected = thread.id == chat.conversationID
        return Button { changeChat(thread.id) } label: {
            HStack(spacing: 8) {
                Text(verbatim: thread.title)
                    .font(.subheadline)
                    .foregroundStyle(selected ? NethPalette.text : NethPalette.muted)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                Spacer(minLength: 4)
                if selected {
                    Circle().fill(NethPalette.muted).frame(width: 4, height: 4)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(selected ? NethPalette.selected : .clear, in: .rect(cornerRadius: 9))
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : NethMotion.fade, value: selected)
        }
        .buttonStyle(NethPress())
        .disabled(busy)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button(role: .destructive) { deleting = thread } label: {
                Label("Delete chat", systemImage: "trash")
            }
            .disabled(busy)
        }
    }

    private func header(wide: Bool, railVisible: Bool) -> some View {
        HStack(spacing: 7) {
            iconControl(railVisible ? "Hide chat sidebar" : "Show chat sidebar", symbol: "sidebar.left") {
                if wide { showSidebar.toggle() } else { sheet = .history }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: chat.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if !wide, let runtimeDetail {
                    runtimeLabel(runtimeDetail)
                } else if let model = models.current {
                    Text(verbatim: model.isPreset ? "Qwen3.5 4B" : model.title)
                        .font(.caption)
                        .foregroundStyle(NethPalette.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if wide, let runtimeDetail { runtimeLabel(runtimeDetail) }
            if !railVisible {
                iconControl("Search chats", symbol: "magnifyingglass") { sheet = .search }
                    .disabled(busy)
                    .keyboardShortcut("f", modifiers: .command)
                iconControl("New chat", symbol: "square.and.pencil", action: newChat)
                    .disabled(busy)
                    .keyboardShortcut("n", modifiers: .command)
            }
            Button { sheet = .models } label: {
                HStack(spacing: 7) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 15, weight: .medium))
                    if wide { Text("Models").font(.subheadline.weight(.medium)) }
                }
                .padding(.horizontal, wide ? 13 : 0)
                .frame(minWidth: 44, minHeight: 44)
                .background(NethPalette.surface, in: .rect(cornerRadius: 11))
                .contentShape(Rectangle())
            }
            .buttonStyle(NethPress())
            .accessibilityLabel("Models & context")
        }
        .padding(.horizontal, wide ? 20 : 8)
        .padding(.vertical, 8)
    }

    private var runtimeDetail: String? {
        guard let profile = chat.profile else { return nil }
        guard let rate = chat.tokensPerSecond, !chat.running else { return profile.detail }
        return "\(profile.detail) · \(rate.formatted(.number.precision(.fractionLength(1)))) tok/s"
    }

    private func runtimeLabel(_ detail: String) -> some View {
        Text(verbatim: detail)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(NethPalette.muted)
            .lineLimit(1)
    }

    private func iconControl(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(NethPalette.text)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(NethPress())
        .accessibilityLabel(title)
    }

    private var startScreen: some View {
        ScrollView {
            VStack(spacing: 13) {
                NethMascot()
                    .padding(.bottom, 11)
                Text(models.current == nil ? "Choose a model" : "What shall we work on?")
                    .font(.system(.largeTitle, design: .serif, weight: .regular))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if models.current == nil {
                    Text("Download Qwen3.5 4B or import a GGUF to chat on-device.")
                        .font(.subheadline)
                        .foregroundStyle(NethPalette.muted)
                        .multilineTextAlignment(.center)
                    Button { sheet = .models } label: {
                        Label("Browse models", systemImage: "arrow.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(NethPalette.canvas)
                            .padding(.horizontal, 15)
                            .frame(minHeight: 44)
                            .background(NethPalette.text, in: .capsule)
                    }
                    .buttonStyle(NethPress())
                    .padding(.top, 6)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { quickActions }
                        VStack(spacing: 8) { quickActions }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(24)
            .frame(maxWidth: readingWidth)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var quickActions: some View {
        quickAction("Create files", symbol: "doc.badge.plus") {
            quattro = true
            makeFiles = true
            typing = true
        }
        quickAction("Search the web", symbol: "globe") {
            web = true
            typing = true
        }
    }

    private func quickAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(NethPalette.muted)
                .padding(.horizontal, 13)
                .frame(minHeight: 44)
                .background(NethPalette.rail, in: .capsule)
                .overlay(Capsule().strokeBorder(NethPalette.border).allowsHitTesting(false))
        }
        .buttonStyle(NethPress())
        .disabled(busy)
    }

    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
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
                        .foregroundStyle(NethPalette.muted)
                        .disabled(busy)
                    }
                    ForEach(chat.messages) { message in
                        let active = message.id == chat.activeReplyID && chat.running
                        ChatMessageRow(message: message, streaming: active, activity: active ? chat.activity : nil,
                                       allowActions: !busy,
                                       resume: { continueReply(message) },
                                       save: { text, name in saveReply(message, text: text, name: name) })
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
                .padding(.horizontal, 20)
                .padding(.vertical, 26)
                .frame(maxWidth: readingWidth + 40)
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
                Group {
                    if !nearBottom && !chat.hasLater {
                        iconControl("Scroll to latest", symbol: "arrow.down") {
                            withAnimation(reduceMotion ? nil : NethMotion.reveal) {
                                nearBottom = true
                                reader.scrollTo("latest", anchor: .bottom)
                            }
                        }
                        .background(NethPalette.surface, in: .circle)
                        .overlay(Circle().strokeBorder(NethPalette.border).allowsHitTesting(false))
                        .padding(13)
                        .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : NethMotion.fade, value: nearBottom)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if chat.running {
                EffortMeter(activity: chat.activity ?? "Preparing…", step: chat.effortStep, total: chat.effortTotal)
                    .padding(.horizontal, 3)
                    .transition(.offset(y: 4).combined(with: .opacity))
            }
            VStack(alignment: .leading, spacing: 6) {
                if let photo, let preview = UIImage(contentsOfFile: photo.path) {
                    HStack {
                        Image(uiImage: preview).resizable().scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(.rect(cornerRadius: 9))
                            .accessibilityLabel("Attached photo")
                        iconControl("Remove photo", symbol: "xmark.circle") { clearAttachment() }
                    }
                    .padding(.horizontal, 7)
                    .transition(.opacity)
                }
                TextField(models.current == nil && !quattro ? "Choose a model to start" : quattro ? "Message Quattro" : "Message Neth Local",
                          text: $draft, axis: .vertical)
                    .font(.body)
                    .textFieldStyle(.plain)
                    .lineLimit(1...7)
                    .focused($typing)
                    .disabled(models.current == nil && !quattro)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .frame(minHeight: 39)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        attachControl
                        modeButtons
                        Spacer(minLength: 6)
                        effortMenu
                        sendControl
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ScrollView(.horizontal) {
                            HStack(spacing: 3) { modeButtons }
                        }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                        HStack(spacing: 4) {
                            attachControl
                            Spacer(minLength: 1)
                            effortMenu
                            sendControl
                        }
                    }
                }
            }
            .padding(9)
            .background(NethPalette.surface, in: .rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20)
                .strokeBorder(typing ? NethPalette.muted.opacity(0.75) : NethPalette.border)
                .allowsHitTesting(false))
            .animation(reduceMotion ? nil : NethMotion.fade, value: typing)
            .animation(reduceMotion ? nil : NethMotion.fade, value: photo != nil)
        }
        .animation(reduceMotion ? nil : NethMotion.reveal, value: chat.running)
        .frame(maxWidth: readingWidth)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
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
            HStack(spacing: 5) {
                Image(systemName: active ? "checkmark" : icon)
                    .frame(width: 14)
                    .contentTransition(reduceMotion ? .identity : .opacity)
                    .accessibilityHidden(true)
                Text(label)
            }
            .font(.caption.weight(active ? .semibold : .medium))
            .foregroundStyle(active ? NethPalette.text : NethPalette.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(active ? NethPalette.selected : .clear, in: .capsule)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .fixedSize(horizontal: true, vertical: false)
            .animation(reduceMotion ? nil : NethMotion.fade, value: active)
        }
        .buttonStyle(NethPress())
        .disabled(busy)
        .accessibilityAddTraits(active ? .isSelected : [])
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
                .foregroundStyle(NethPalette.muted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Add to message")
        .disabled(busy || loadingPhoto)
    }

    private var effortMenu: some View {
        let displayed = chat.activeEffort ?? effort
        return Menu {
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
                Text(displayed.title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(NethPalette.muted)
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .fixedSize(horizontal: true, vertical: false)
        }
        .disabled(busy)
        .accessibilityLabel("Effort")
        .accessibilityValue(displayed.title)
    }

    private var sendControl: some View {
        let enabled = chat.running || canSend
        return Button {
            if chat.running { chat.stop() } else { send() }
        } label: {
            Image(systemName: chat.running ? "stop.fill" : "arrow.up")
                .font(.system(size: chat.running ? 13 : 17, weight: .semibold))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .foregroundStyle(enabled ? NethPalette.canvas : NethPalette.muted)
                .frame(width: 44, height: 44)
                .background(enabled ? NethPalette.text : NethPalette.selected, in: .circle)
        }
        .buttonStyle(NethPress())
        .disabled(!enabled)
        .accessibilityLabel(chat.running ? "Stop and keep progress" : "Send")
        .keyboardShortcut(chat.running ? nil : KeyboardShortcut(.return, modifiers: .command))
        .animation(reduceMotion ? nil : NethMotion.fade, value: enabled)
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
                              cache: cache, compactHistory: compactHistory, promptCache: promptCache)
    }

    private func continueReply(_ reply: ChatMessage) {
        typing = false
        chat.resume(reply, effort: effort, settings: engineSettings)
    }

    private func saveReply(_ reply: ChatMessage, text: String, name: String) {
        exportName = name
        exporting = FileExport(message: reply, text: text)
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
                        Text(verbatim: hit.title).font(.subheadline.weight(.semibold)).foregroundStyle(NethPalette.text)
                            .lineLimit(1)
                        Text(verbatim: hit.excerpt).font(.footnote).foregroundStyle(NethPalette.muted)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(NethPalette.surface)
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
