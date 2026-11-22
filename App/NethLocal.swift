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

    private enum ComposerPicker: Hashable {
        case model, effort
    }

    @StateObject private var models = LocalModels()
    @StateObject private var windows = WindowsDevices()
    @StateObject private var cloud = NethCloud()
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
    @State private var expandedPicker: ComposerPicker?
    @State private var deleting: Conversation?
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: URL?
    @State private var loadingPhoto = false
    @State private var nearBottom = true
    @State private var exporting: FileExport?
    @State private var exportName = "Reply.md"

    private let readingWidth: CGFloat = 756
    private let composerWidth: CGFloat = 680

    private var canAttach: Bool {
        models.current?.isPreset == true && models.projector != nil
            && windows.compute == nil && cloud.compute == nil
    }
    private var busy: Bool { chat.running || chat.opening }
    private var canSend: Bool {
        !busy && !loadingPhoto && (models.current != nil || quattro || cloud.compute != nil)
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photo != nil)
    }

    var body: some View {
        observeChat(attachAlerts(attachSheet(layout)))
    }

    private var layout: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 850 && !typeSize.isAccessibilitySize
            let panelVisible = wide && showSidebar
            HStack(spacing: 0) {
                if wide { activityRail(panelVisible: panelVisible) }
                if panelVisible {
                    sidebar(inSheet: false)
                        .frame(width: 204)
                        .overlay(alignment: .trailing) { Rectangle().fill(NethPalette.border).frame(width: 1) }
                        .transition(reduceMotion ? .identity : .move(edge: .leading).combined(with: .opacity))
                }
                VStack(spacing: 0) {
                    header(wide: wide)
                    Rectangle().fill(NethPalette.border).frame(height: 1)
                    workspace
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NethPalette.canvas)
                .zIndex(1)
            }
            .animation(reduceMotion ? nil : NethMotion.open, value: panelVisible)
        }
        .foregroundStyle(NethPalette.text)
        .background(NethPalette.canvas.ignoresSafeArea())
    }

    private func attachSheet(_ content: some View) -> some View {
        content.sheet(item: $sheet) { selected in
            switch selected {
            case .history: sidebar(inSheet: true).presentationDetents([.large])
            case .search:
                ChatSearchPanel(search: chat.search) { hit in
                    changeChat(hit.conversationID, at: hit.id)
                }
                .presentationDetents([.large])
            case .models:
                ModelPanel(models: models, windows: windows, cloud: cloud, context: $context, cpuOnly: $cpuOnly,
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
    }

    private func attachAlerts(_ content: some View) -> some View {
        content.alert("Delete chat?", isPresented: Binding(
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
    }

    private func observeChat(_ content: some View) -> some View {
        content.task { await chat.restore() }
        .onChange(of: photoItem) { _, item in if let item { preparePhoto(item) } }
        .onChange(of: typing) { _, focused in if focused { expandedPicker = nil } }
        .onChange(of: sheet) { _, active in if active != nil { expandedPicker = nil } }
        .onChange(of: chat.running) { _, running in if running { expandedPicker = nil } }
        .onChange(of: models.selectedID) { _, _ in
            chat.unload()
            if models.current?.isPreset != true { windows.choose(nil) }
            if !canAttach { clearAttachment() }
        }
        .onChange(of: windows.compute) { _, _ in
            chat.unload()
            if !canAttach { clearAttachment() }
        }
        .onChange(of: cloud.selectedID) { _, _ in
            chat.unload()
            if !canAttach { clearAttachment() }
        }
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

    private func activityRail(panelVisible: Bool) -> some View {
        VStack(spacing: 5) {
            NethMascotMark()
                .frame(width: 44, height: 41)
            railButton(panelVisible ? "Hide chats" : "Show chats", symbol: "sidebar.left", selected: panelVisible) {
                showSidebar.toggle()
            }
            .keyboardShortcut("b", modifiers: .command)
            railButton("New chat", symbol: "plus", action: newChat)
                .disabled(busy)
                .keyboardShortcut("n", modifiers: .command)
            railButton("Search chats", symbol: "magnifyingglass") { sheet = .search }
                .disabled(busy)
                .keyboardShortcut("f", modifiers: .command)
            railButton("Quattro tools", symbol: "square.grid.2x2") { sheet = .tools }
                .disabled(busy)
            Spacer(minLength: 0)
            railButton("Models & context", symbol: "slider.horizontal.3") { sheet = .models }
        }
        .padding(.vertical, 6)
        .frame(width: 56)
        .frame(maxHeight: .infinity)
        .background(NethPalette.inset.ignoresSafeArea(edges: .vertical))
        .overlay(alignment: .trailing) { Rectangle().fill(NethPalette.border).frame(width: 1) }
        .zIndex(2)
    }

    private func railButton(_ title: String, symbol: String, selected: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(selected ? NethPalette.violet : NethPalette.muted)
                .frame(width: 44, height: 44)
                .background(selected ? NethPalette.selected : .clear, in: .rect(cornerRadius: 8))
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : NethMotion.fade, value: selected)
        }
        .buttonStyle(NethPress())
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sidebar(inSheet: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Text(inSheet ? "Chats" : "Neth Local")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if inSheet {
                    Button("Done") { sheet = nil }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                } else if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text("v\(version)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(NethPalette.muted)
                }
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 32)

            if inSheet {
                VStack(spacing: 3) {
                    sidebarAction("New chat", symbol: "plus", prominent: true, action: newChat)
                        .keyboardShortcut("n", modifiers: .command)
                    sidebarAction("Search chats", symbol: "magnifyingglass") { sheet = .search }
                        .keyboardShortcut("f", modifiers: .command)
                    sidebarAction("Quattro tools", symbol: "square.grid.2x2") { sheet = .tools }
                }
            }

            if chat.conversations.isEmpty {
                Text("No chats yet")
                    .font(.caption)
                    .foregroundStyle(NethPalette.muted)
                    .padding(.horizontal, 9)
            } else {
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
        .padding(.vertical, 11)
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
                Image(systemName: "bubble.left")
                    .font(.caption)
                    .foregroundStyle(NethPalette.muted)
                    .accessibilityHidden(true)
                Text(verbatim: thread.title)
                    .font(.subheadline)
                    .foregroundStyle(selected ? NethPalette.text : NethPalette.muted)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                Spacer(minLength: 4)
                if selected {
                    Circle().fill(NethPalette.violet).frame(width: 4, height: 4)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(selected ? NethPalette.violetSurface : .clear, in: .rect(cornerRadius: 7))
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

    @ViewBuilder
    private func header(wide: Bool) -> some View {
        if wide {
            HStack(spacing: 15) {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left").foregroundStyle(NethPalette.muted).accessibilityHidden(true)
                    chatTitle
                }
                .font(.caption)
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(NethPalette.canvas)
                .overlay(alignment: .top) { Rectangle().fill(NethPalette.violet.opacity(0.8)).frame(height: 1) }
                .overlay(alignment: .trailing) { Rectangle().fill(NethPalette.border).frame(width: 1) }
                Spacer(minLength: 4)
                if let runtimeDetail {
                    runtimeLabel(runtimeDetail).padding(.trailing, 15)
                }
            }
            .background(NethPalette.rail)
        } else {
            HStack(spacing: 4) {
                iconControl("Show chats", symbol: "sidebar.left") { sheet = .history }
                VStack(alignment: .leading, spacing: 3) {
                    chatTitle
                    if let runtimeDetail { runtimeLabel(runtimeDetail) }
                }
                Spacer(minLength: 4)
                iconControl("Search chats", symbol: "magnifyingglass") { sheet = .search }
                    .disabled(busy)
                    .keyboardShortcut("f", modifiers: .command)
                iconControl("New chat", symbol: "plus", action: newChat)
                    .disabled(busy)
                    .keyboardShortcut("n", modifiers: .command)
                iconControl("Models & context", symbol: "slider.horizontal.3") { sheet = .models }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(NethPalette.rail)
        }
    }

    private var chatTitle: some View {
        Text(verbatim: chat.title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }

    private var runtimeDetail: String? {
        chat.profile?.detail
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

    private var workspace: some View {
        let atStart = chat.messages.isEmpty && !chat.running
        return GeometryReader { layout in
            let height = layout.size.height
            let oneRow = layout.size.width >= 535 && !typeSize.isAccessibilitySize
            let showWelcome = atStart && !typing && draft.isEmpty && photo == nil && expandedPicker == nil
            let showScene = showWelcome && height >= (oneRow ? 415 : 530) && !typeSize.isAccessibilitySize
            let showShortcuts = showWelcome && height >= (oneRow ? 340 : 470)

            VStack(spacing: 0) {
                if atStart {
                    Spacer(minLength: 0)
                } else {
                    transcript.transition(.opacity)
                }
                VStack(alignment: .leading, spacing: 9) {
                    if showScene {
                        WorkspaceScene().transition(reduceMotion ? .identity : NethMotion.rise)
                    }
                    composer(maxLines: height < 360 ? 3 : 7, optionsHeight: min(246, max(104, height * 0.37)))
                    if showShortcuts {
                        Group {
                            if oneRow {
                                HStack(spacing: 8) { quickActions }
                            } else {
                                VStack(spacing: 6) { quickActions }
                            }
                        }
                        .transition(reduceMotion ? .identity : NethMotion.rise)
                    }
                }
                .frame(maxWidth: composerWidth)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, atStart ? 8 : 13)
                .layoutPriority(1)
                if atStart { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if atStart { WorkspaceBackdrop().transition(.opacity) }
            }
            .animation(reduceMotion ? nil : NethMotion.reveal, value: atStart)
            .animation(reduceMotion ? nil : NethMotion.reveal, value: showScene)
            .animation(reduceMotion ? nil : NethMotion.reveal, value: showShortcuts)
        }
    }

    @ViewBuilder
    private var quickActions: some View {
        quickAction("Draft a note", symbol: "doc.badge.plus", available: models.current != nil || cloud.compute != nil) {
            quattro = true
            makeFiles = true
            if draft.isEmpty { draft = "/file Notes.md " }
            typing = true
        }
        quickAction("Research a topic", symbol: "globe") {
            web = true
            makeFiles = false
            if models.current == nil { quattro = true }
            if draft.isEmpty { draft = "Find reliable sources about " }
            typing = true
        }
        quickAction("Browse tools", symbol: "square.grid.2x2") { sheet = .tools }
    }

    private func quickAction(_ title: String, symbol: String, available: Bool = true,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .foregroundStyle(NethPalette.lilac)
                    .frame(width: 26, height: 26)
                    .background(NethPalette.violetSurface, in: .rect(cornerRadius: 6))
                    .accessibilityHidden(true)
                Text(title).foregroundStyle(NethPalette.text)
                Spacer(minLength: 2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(NethPalette.muted)
                    .accessibilityHidden(true)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background(NethPalette.rail, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(NethPalette.border).allowsHitTesting(false))
        }
        .buttonStyle(NethPress())
        .disabled(busy || !available)
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
                            .transition(reduceMotion ? .identity : NethMotion.rise)
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
                .animation(reduceMotion ? nil : NethMotion.reveal, value: chat.messages.last?.id)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY <= 170
            } action: { _, close in nearBottom = close }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.top, for: .alignment)
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

    private func composer(maxLines: Int, optionsHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if chat.running || chat.generation.tokens > 0 {
                EffortMeter(activity: chat.running ? (chat.activity ?? "Preparing…") : "Generated",
                            step: chat.effortStep, total: chat.effortTotal, running: chat.running, metrics: chat.generation)
                    .transition(reduceMotion ? .identity : NethMotion.rise)
            }
            if typeSize.isAccessibilitySize {
                VStack(spacing: 6) {
                    modelSelector
                    effortSelector
                }
            } else {
                HStack(spacing: 8) {
                    modelSelector
                    effortSelector.frame(maxWidth: 150)
                }
            }
            if let expandedPicker {
                pickerPanel(expandedPicker, height: optionsHeight)
                    .id(expandedPicker)
                    .transition(reduceMotion ? .identity : NethMotion.panel)
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
                    .transition(reduceMotion ? .identity : NethMotion.panel)
                }
                TextField(composerPlaceholder,
                          text: $draft, axis: .vertical)
                    .font(.body)
                    .textFieldStyle(.plain)
                    .lineLimit(1...maxLines)
                    .focused($typing)
                    .disabled(models.current == nil && !quattro && cloud.compute == nil)
                    .padding(.horizontal, 8)
                    .padding(.top, 7)
                    .frame(minHeight: maxLines <= 3 ? 36 : 51, alignment: .topLeading)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        attachControl
                        modeButtons
                        Spacer(minLength: 6)
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
                            sendControl
                        }
                    }
                }
            }
            .padding(10)
            .background(LinearGradient(colors: [NethPalette.surface, NethPalette.rail],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(typing ? NethPalette.violet.opacity(0.68) : NethPalette.border)
                .allowsHitTesting(false))
            .shadow(color: NethPalette.violet.opacity(typing ? 0.12 : 0), radius: 12, y: 2)
            .animation(reduceMotion ? nil : NethMotion.fade, value: typing)
            .animation(reduceMotion ? nil : NethMotion.fade, value: photo != nil)
        }
        .animation(reduceMotion ? nil : NethMotion.open, value: expandedPicker)
        .animation(reduceMotion ? nil : NethMotion.reveal, value: chat.running)
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
            .foregroundStyle(active ? NethPalette.violet : NethPalette.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(active ? NethPalette.violet.opacity(0.13) : .clear, in: .rect(cornerRadius: 7))
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

    @ViewBuilder
    private var modelSelector: some View {
        if let compute = cloud.compute {
            Button { togglePicker(.model) } label: {
                selectorLabel("GPT-OSS 20B · Cloud", symbol: "icloud", expanded: expandedPicker == .model)
            }
            .buttonStyle(NethPress())
            .accessibilityLabel("Model")
            .accessibilityValue("Neth Cloud GPU")
            .accessibilityAddTraits(expandedPicker == .model ? .isSelected : [])
        } else if models.installed.isEmpty {
            Button { sheet = .models } label: {
                selectorLabel("Choose a model", symbol: "cpu", trailing: "arrow.up.right")
            }
            .buttonStyle(NethPress())
        } else {
            let title = models.current.map(modelName) ?? "Choose a model"
            Button { togglePicker(.model) } label: {
                selectorLabel(title, symbol: "cpu", expanded: expandedPicker == .model)
            }
            .buttonStyle(NethPress())
            .accessibilityLabel("Model")
            .accessibilityValue(title)
            .accessibilityAddTraits(expandedPicker == .model ? .isSelected : [])
        }
    }

    private func modelName(_ model: InstalledModel) -> String {
        model.isPreset ? "Qwen3.5 4B" : model.title
    }

    private var effortSelector: some View {
        let displayed = chat.activeEffort ?? effort
        return Button { togglePicker(.effort) } label: {
            selectorLabel(displayed.title, symbol: "speedometer", expanded: expandedPicker == .effort)
        }
        .buttonStyle(NethPress())
        .disabled(busy)
        .accessibilityLabel("Effort")
        .accessibilityValue(displayed.title)
        .accessibilityAddTraits(expandedPicker == .effort ? .isSelected : [])
    }

    private func togglePicker(_ picker: ComposerPicker) {
        typing = false
        expandedPicker = expandedPicker == picker ? nil : picker
    }

    @ViewBuilder
    private func pickerPanel(_ picker: ComposerPicker, height: CGFloat) -> some View {
        switch picker {
        case .model:
            ComposerOptions(title: "Model", rowCount: models.installed.count + 1, heightLimit: height,
                            close: { expandedPicker = nil }) {
                ForEach(Array(models.installed.enumerated()), id: \.element.id) { index, model in
                    ComposerChoice(title: modelName(model), detail: LocalModels.size(model.bytes), symbol: "cpu",
                                   selected: model.id == models.selectedID, order: index) {
                        models.selectedID = model.id
                        expandedPicker = nil
                    }
                    .disabled(busy)
                }
                ComposerChoice(title: "Models & context", detail: "Downloads, imports and inference settings",
                               symbol: "slider.horizontal.3", order: models.installed.count) {
                    expandedPicker = nil
                    sheet = .models
                }
            }
        case .effort:
            ComposerOptions(title: "Effort", rowCount: EffortPreset.allCases.count, heightLimit: height,
                            close: { expandedPicker = nil }) {
                ForEach(EffortPreset.allCases) { item in
                    ComposerChoice(title: item.title, detail: item.description, symbol: "cellularbars",
                                   selected: item == effort, order: item.segments - 1) {
                        effort = item
                        expandedPicker = nil
                    }
                }
            }
        }
    }

    private func selectorLabel(_ title: String, symbol: String, trailing: String = "chevron.down",
                               expanded: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(expanded ? NethPalette.lilac : NethPalette.muted)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
                .foregroundStyle(NethPalette.text)
            Spacer(minLength: 2)
            Image(systemName: trailing)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(expanded ? NethPalette.lilac : NethPalette.muted)
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .accessibilityHidden(true)
        }
        .font(.system(.caption, design: .monospaced, weight: .medium))
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(expanded ? NethPalette.violetSurface : NethPalette.inset, in: .rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(expanded ? NethPalette.violet.opacity(0.45) : NethPalette.border)
            .allowsHitTesting(false))
        .contentShape(Rectangle())
    }

    private var composerPlaceholder: String {
        if models.current == nil && !quattro {
            return cloud.compute == nil ? "Choose a model to start" : "Ask GPT-OSS 20B on Neth Cloud"
        }
        return quattro ? "Give Quattro a task" : "Describe a task or ask a question"
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
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: enabled ? [NethPalette.lilac, NethPalette.violet] : [NethPalette.selected, NethPalette.rail],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .shadow(color: enabled ? NethPalette.violet.opacity(0.18) : .clear, radius: 7, y: 2)
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
        expandedPicker = nil
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
        if let compute = cloud.compute {
            return EngineSettings(model: Self.cloudModel, projector: nil, context: compute.context, cpuOnly: false,
                                  thinking: thinking, cache: cache, compactHistory: compactHistory,
                                  promptCache: promptCache, windows: nil, cloud: compute)
        }
        guard let model = models.current else { return nil }
        return EngineSettings(model: model, projector: canAttach ? models.projector : nil,
                              context: context, cpuOnly: cpuOnly, thinking: thinking,
                              cache: cache, compactHistory: compactHistory, promptCache: promptCache,
                              windows: model.isPreset ? windows.compute : nil, cloud: nil)
    }

    private static let cloudModel = InstalledModel(
        title: "GPT-OSS 20B · Cloud",
        url: URL(fileURLWithPath: "/NethCloud/GPT-OSS-20B-Uncensored-HauhauCS-MXFP4-Aggressive.gguf"),
        bytes: 12_109_565_888, isPreset: false)

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
    }

    private func changeChat(_ id: String, at message: Int64? = nil) {
        resetComposer()
        sheet = nil
        Task { await chat.open(id, at: message) }
    }

    private func resetComposer() {
        expandedPicker = nil
        typing = false
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
