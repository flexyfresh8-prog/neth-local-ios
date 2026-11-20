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
    let active: RuntimeProfile?
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
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(NethPalette.accent)
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
                    Toggle("Thinking mode", isOn: $thinking)
                    Toggle("CPU only", isOn: $cpuOnly)
                    if let active {
                        LabeledContent("Active context", value: active.detail)
                    }
                } header: { Text("Inference") } footer: {
                    Text("Q4 and Q8 compress the bundled Qwen model’s active attention cache. iPadOS memory can reduce the actual context. Older chat excerpts are stored on disk.")
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
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(NethPalette.accent)
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
