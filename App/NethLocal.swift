import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private let surface = Color(red: 0.08, green: 0.08, blue: 0.105)
private let panel = Color(red: 0.115, green: 0.112, blue: 0.15)
private let accent = Color(red: 0.75, green: 0.69, blue: 1)

@main
struct NethLocalApp: App {
    var body: some Scene {
        WindowGroup {
            ChatScreen()
                .preferredColorScheme(.dark)
                .tint(accent)
        }
    }
}

@MainActor
private final class LocalChat: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var running = false
    @Published private(set) var status: String?
    @Published var problem: String?

    private let engine = LocalEngine()
    private var activeStop: GenerationStop?

    func send(_ text: String, photo: URL?, settings: EngineSettings) {
        guard !running else { return }
        messages.append(ChatMessage(role: .user, text: text, photo: photo))
        let prompt = Array(messages.suffix(24))
        messages.append(ChatMessage(role: .assistant, text: ""))
        let stop = GenerationStop()
        activeStop = stop
        running = true
        status = "Loading model"

        Task {
            defer {
                if messages.last?.role == .assistant, messages.last?.text.isEmpty == true {
                    messages.removeLast()
                }
                running = false
                activeStop = nil
            }
            var backend = ""
            do {
                for try await event in engine.stream(history: prompt, settings: settings, stop: stop) {
                    switch event {
                    case .backend(let name):
                        backend = name
                        status = "Preparing · \(name)"
                    case .text(let part):
                        if messages.last?.text.isEmpty == true { status = "Generating · \(backend)" }
                        messages[messages.count - 1].text += part
                    case .finished(let count, let seconds):
                        status = String(format: "%.1f tok/s · %@", Double(count - 1) / seconds, backend)
                    }
                }
                if status?.hasPrefix("Preparing") == true || status?.hasPrefix("Generating") == true {
                    status = nil
                }
            } catch {
                status = nil
                problem = error.localizedDescription
            }
        }
    }

    func stop() { activeStop?.request() }

    func unload() {
        stop()
        engine.unload()
    }

    func reset() {
        guard !running else { return }
        for message in messages {
            if let photo = message.photo { try? FileManager.default.removeItem(at: photo) }
        }
        messages.removeAll()
        status = nil
    }
}

@MainActor
private struct ChatScreen: View {
    @StateObject private var models = LocalModels()
    @StateObject private var chat = LocalChat()
    @AppStorage("contextSize") private var context = 1024
    @AppStorage("cpuOnly") private var cpuOnly = false
    @AppStorage("thinking") private var thinking = false
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var composing: Bool
    @State private var draft = ""
    @State private var showModels = false
    @State private var confirmReset = false
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: URL?
    @State private var photoLoading = false

    private var supportsPhotos: Bool { models.current?.isPreset == true && models.projector != nil }
    private var readyToSend: Bool {
        !chat.running && !photoLoading && models.current != nil
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photo != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if chat.messages.isEmpty { emptyState } else { transcript }
            if let status = chat.status {
                Text(status)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                    .accessibilityLabel(status)
            }
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(surface.ignoresSafeArea())
        .sheet(isPresented: $showModels) {
            ModelPanel(models: models, context: $context, cpuOnly: $cpuOnly,
                       thinking: $thinking, inferenceBusy: chat.running) { chat.unload() }
        }
        .confirmationDialog("Clear this chat?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Clear chat", role: .destructive) {
                chat.reset()
                clearPhoto()
                draft = ""
            }
        }
        .alert("Neth Local", isPresented: Binding(get: { chat.problem != nil }, set: { if !$0 { chat.problem = nil } })) {
            Button("OK", role: .cancel) { chat.problem = nil }
        } message: {
            Text(chat.problem ?? "")
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            loadPhoto(item)
        }
        .onChange(of: models.selectedID) { _, _ in
            chat.unload()
            if !supportsPhotos { clearPhoto() }
        }
        .onChange(of: models.projector) { _, _ in
            if !supportsPhotos { clearPhoto() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { chat.unload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            chat.unload()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 42, height: 42)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Neth Local").font(.system(.headline, design: .rounded, weight: .bold))
                Text(models.current?.title ?? "On-device AI")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                confirmReset = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .frame(minWidth: 34, minHeight: 34)
            }
            .disabled(chat.messages.isEmpty || chat.running)
            .accessibilityLabel("New chat")
            Button { showModels = true } label: {
                Label("Models", systemImage: "square.stack")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 4)
                    .frame(minHeight: 34)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(accent)
                .frame(width: 86, height: 86)
                .background(accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 26))
                .accessibilityHidden(true)
            Text(models.current == nil ? "Choose a model" : "Start a chat")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            if models.current == nil {
                Text("Download Qwen3.5 4B or import a compatible GGUF.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open models") { showModels = true }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .foregroundStyle(.black)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(chat.messages) { message in messageBubble(message) }
                    Color.clear.frame(height: 1).id("chatBottom")
                }
                .padding(.horizontal, 22)
                .padding(.top, 24)
                .padding(.bottom, 12)
                .frame(maxWidth: 840)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.messages.last?.text) { _, _ in reader.scrollTo("chatBottom", anchor: .bottom) }
        }
    }

    private func messageBubble(_ message: ChatMessage) -> some View {
        let assistant = message.role == .assistant
        return VStack(alignment: .leading, spacing: 8) {
            Text(assistant ? "Neth Local" : "You")
                .font(.caption.weight(.semibold))
                .foregroundStyle(assistant ? accent : .secondary)
            if let photo = message.photo, let preview = UIImage(contentsOfFile: photo.path) {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 275, maxHeight: 192, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if message.text.isEmpty && assistant {
                ProgressView().controlSize(.small)
            } else if assistant && message.text.hasPrefix("<think>") {
                let parts = message.text.dropFirst(7).components(separatedBy: "</think>")
                let thought = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !thought.isEmpty {
                    DisclosureGroup(parts.count > 1 ? "Thinking" : "Thinking…") {
                        Text(thought).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .font(.caption)
                }
                if parts.count > 1 {
                    Text(parts.dropFirst().joined(separator: "</think>").trimmingCharacters(in: .whitespacesAndNewlines))
                        .textSelection(.enabled)
                }
            } else if !message.text.isEmpty {
                Text(message.text).textSelection(.enabled)
            }
        }
        .padding(14)
        .background(assistant ? panel : accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, alignment: assistant ? .leading : .trailing)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let photo, let preview = UIImage(contentsOfFile: photo.path) {
                HStack {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Button("Remove photo", systemImage: "xmark.circle.fill") { clearPhoto() }
                        .labelStyle(.iconOnly)
                }
                .padding(.horizontal, 8)
            }
            HStack(alignment: .bottom, spacing: 10) {
                if supportsPhotos {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Image(systemName: "photo").font(.system(size: 20))
                            .frame(width: 38, height: 38)
                    }
                    .disabled(chat.running || photoLoading)
                    .accessibilityLabel("Attach a photo")
                }
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composing)
                    .frame(minHeight: 38)
                    .disabled(models.current == nil)
                    .padding(.horizontal, supportsPhotos ? 0 : 8)
                if chat.running {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.fill").frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .background(Color.white.opacity(0.1), in: Circle())
                    .accessibilityLabel("Stop generating")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .bold))
                            .frame(width: 38, height: 38)
                            .foregroundStyle(readyToSend ? .black : .secondary)
                            .background(readyToSend ? accent : Color.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!readyToSend)
                    .accessibilityLabel("Send message")
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(8)
        .background(panel, in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.08)) }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: 840)
    }

    private func send() {
        guard readyToSend, let model = models.current else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.utf8.count > 30_000 {
            chat.problem = "Shorten this message or choose a larger context."
            return
        }
        let settings = EngineSettings(model: model, projector: supportsPhotos ? models.projector : nil,
                                      context: context, cpuOnly: cpuOnly, thinking: thinking)
        chat.send(text.isEmpty ? "Describe this image." : text, photo: photo, settings: settings)
        draft = ""
        photo = nil
        photoItem = nil
        composing = false
    }

    private func clearPhoto() {
        if let photo { try? FileManager.default.removeItem(at: photo) }
        photo = nil
        photoItem = nil
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        photoLoading = true
        Task {
            defer { photoLoading = false }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw LocalError(message: "Photos did not return an image.")
                }
                let thumbnail = try await Task.detached(priority: .utility) {
                    try Self.smallPhoto(data)
                }.value
                guard supportsPhotos, photoItem == item else {
                    try? FileManager.default.removeItem(at: thumbnail)
                    return
                }
                if let photo { try? FileManager.default.removeItem(at: photo) }
                photo = thumbnail
            } catch {
                chat.problem = error.localizedDescription
            }
        }
    }

    private nonisolated static func smallPhoto(_ data: Data) throws -> URL {
        let error = LocalError(message: "The app could not prepare this photo.")
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw error }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 448
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw error }
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
        guard let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw error
        }
        CGImageDestinationAddImage(out, image, nil)
        guard CGImageDestinationFinalize(out) else { throw error }
        return url
    }
}

@MainActor
private struct ModelPanel: View {
    @ObservedObject var models: LocalModels
    @Binding var context: Int
    @Binding var cpuOnly: Bool
    @Binding var thinking: Bool
    let inferenceBusy: Bool
    let unload: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var removal: URL?
    @State private var available = Int64(nl_available_memory())

    var body: some View {
        NavigationStack {
            List {
                Section {
                    assetRow(.qwen, detail: "HauhauCS · Q4_K_M · \(LocalModels.size(ModelAsset.qwen.bytes))")
                    assetRow(.vision, detail: "Photos · \(LocalModels.size(ModelAsset.vision.bytes))")
                    Link("Model details", destination: ModelAsset.modelCard)
                        .font(.footnote)
                } header: { Text("Qwen3.5") }

                Section {
                    ForEach(models.installed) { model in
                        Button {
                            models.selectedID = model.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.title).foregroundStyle(.primary)
                                    Text(LocalModels.size(model.bytes)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if models.selectedID == model.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                                }
                            }
                        }
                        .disabled(inferenceBusy)
                        .swipeActions {
                            Button("Remove", role: .destructive) { removal = model.url }.disabled(inferenceBusy)
                        }
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label(models.importing ? "Importing…" : "Import GGUF", systemImage: "folder")
                    }
                    .disabled(models.importing || inferenceBusy)
                } header: { Text("On this iPad") }

                Section {
                    Picker("Context", selection: $context) {
                        Text("512 tokens").tag(512)
                        Text("1,024 tokens").tag(1024)
                        Text("2,048 tokens").tag(2048)
                    }
                    Toggle("Thinking mode", isOn: $thinking)
                    Toggle("CPU only", isOn: $cpuOnly)
                } header: { Text("Inference") } footer: {
                    if available > 0 {
                        Text("iPadOS reports \(LocalModels.size(available)) of additional memory available to this app.")
                    }
                }
                .disabled(inferenceBusy)
            }
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): models.importGGUF(url)
            case .failure(let error): models.problem = error.localizedDescription
            }
        }
        .confirmationDialog("Remove this model file?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("Remove download", role: .destructive) {
                if let removal {
                    unload()
                    models.remove(removal)
                }
                removal = nil
            }
        }
        .alert("Models", isPresented: Binding(get: { models.problem != nil }, set: { if !$0 { models.problem = nil } })) {
            Button("OK", role: .cancel) { models.problem = nil }
        } message: {
            Text(models.problem ?? "")
        }
    }

    private func assetRow(_ asset: ModelAsset, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.title).font(.body.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if models.has(asset) {
                    if asset == .vision, let projector = models.projector {
                        Button("Remove", systemImage: "trash") { removal = projector }
                            .labelStyle(.iconOnly)
                            .disabled(inferenceBusy)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                            .accessibilityLabel("Downloaded")
                    }
                } else if models.activeDownload == asset {
                    if !models.verifying {
                        Button("Cancel") { models.cancelDownload() }
                    }
                } else {
                    Button("Download") { models.download(asset) }
                        .buttonStyle(.bordered)
                        .disabled(models.activeDownload != nil)
                }
            }
            if models.activeDownload == asset {
                if models.verifying {
                    ProgressView("Checking file")
                } else {
                    ProgressView(value: models.fraction) {
                        Text(models.fraction.formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption.monospacedDigit())
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}
