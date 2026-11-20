import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ModelPanel: View {
    @ObservedObject var models: LocalModels
    @Binding var context: Int
    @Binding var cpuOnly: Bool
    @Binding var thinking: Bool
    @Binding var cache: CachePrecision
    @Binding var compactHistory: Bool
    @Binding var promptCache: PromptCacheMode
    let active: RuntimeProfile?
    let metrics: PromptMetrics?
    let checkpointNotice: String?
    let inferenceBusy: Bool
    let unload: () -> Void
    let saveAndUnload: () async -> Void
    let clearCheckpoints: () async -> Void
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
                .listRowBackground(NethPalette.surface)

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
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(NethPalette.text)
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
                .listRowBackground(NethPalette.surface)

                Section {
                    Picker("Context", selection: $context) {
                        Text("512 tokens").tag(512)
                        Text("1,024 tokens").tag(1024)
                        Text("2,048 tokens").tag(2048)
                        Text("4,096 tokens").tag(4096)
                        Text("8,192 tokens").tag(8192)
                        Text("16,384 tokens").tag(16384)
                        Text("32,768 tokens").tag(32768)
                        Text("65,536 tokens").tag(65536)
                        Text("131,072 tokens").tag(131072)
                    }
                    Picker("Cache precision", selection: $cache) {
                        ForEach(CachePrecision.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Toggle("Compact older chat turns", isOn: $compactHistory)
                        .tint(NethPalette.muted)
                    Toggle("Thinking mode", isOn: $thinking)
                        .tint(NethPalette.muted)
                    Toggle("CPU only", isOn: $cpuOnly)
                        .tint(NethPalette.muted)
                    if let active {
                        LabeledContent("Active context", value: active.detail)
                    }
                } header: { Text("Inference") } footer: {
                    Text("Q4 and Q8 compress the bundled Qwen model’s active attention cache. iPadOS memory can reduce the actual context. Older chat excerpts are stored on disk.")
                    if available > 0 {
                        Text("iPadOS reports \(LocalModels.size(available)) of additional memory available to this app.")
                    }
                }
                .listRowBackground(NethPalette.surface)
                .disabled(inferenceBusy)

                Section {
                    Picker("Prompt reuse", selection: $promptCache) {
                        ForEach(PromptCacheMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .disabled(inferenceBusy || models.current?.isPreset != true)
                    if let metrics {
                        LabeledContent("Last prompt", value: metrics.source)
                        LabeledContent("Tokens reused", value: "\(metrics.reused.formatted()) / \(metrics.tokens.formatted())")
                        LabeledContent("Prefill", value: String(format: "%.2f s", metrics.prefill))
                        if let first = metrics.firstToken {
                            LabeledContent("First token after model load", value: String(format: "%.2f s", first))
                        }
                        if metrics.headroom > 0 {
                            LabeledContent("Memory available after prefill", value: LocalModels.size(metrics.headroom))
                        }
                    }
                    if promptCache == .storage {
                        Button("Save checkpoint and unload model") { Task { await saveAndUnload() } }
                            .disabled(inferenceBusy || active == nil || models.current?.isPreset != true)
                    }
                    Button("Clear saved checkpoints", role: .destructive) { Task { await clearCheckpoints() } }
                        .disabled(inferenceBusy)
                    if let checkpointNotice { Text(checkpointNotice).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Prompt checkpoints") } footer: {
                    Text("Bundled Qwen text chats can reuse matching prompts. Storage mode saves longer prompts when you switch chats or leave the app. Saved checkpoints use up to 1.5 GiB of storage.")
                }
                .listRowBackground(NethPalette.surface)
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    LabeledContent("App version", value: version)
                        .foregroundStyle(NethPalette.muted)
                        .listRowBackground(NethPalette.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(NethPalette.canvas)
            .navigationTitle("Models & context")
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
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(NethPalette.text)
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
