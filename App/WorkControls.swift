import QuickLook
import SwiftUI

struct EffortMeter: View {
    let preset: EffortPreset
    let activity: String?
    let step: Int
    let total: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double {
        if activity == nil { return Double(preset.segments) / 4 }
        if total <= 1 { return 0.23 }
        return min(0.93, max(0.12, (Double(step) - 0.35) / Double(total)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "waveform.path").foregroundStyle(NethPalette.green)
                Text(verbatim: activity ?? "Effort").lineLimit(1)
                Spacer(minLength: 5)
                if activity != nil && total > 1 {
                    Text("\(step)/\(total)").monospacedDigit()
                }
                Text(preset.title).foregroundStyle(NethPalette.accent)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(NethPalette.muted)
            .frame(maxWidth: .infinity)

            GeometryReader { layout in
                let width = layout.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(NethPalette.border)
                    Capsule().fill(LinearGradient(colors: [NethPalette.accent, NethPalette.green],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: width * fraction)
                    if activity != nil && !reduceMotion {
                        TimelineView(.animation(minimumInterval: 1.0 / 18)) { timeline in
                            Canvas { graphics, size in
                                let t = timeline.date.timeIntervalSinceReferenceDate * 0.52
                                for particle in 0..<12 {
                                    let phase = (t + Double(particle) * 0.083).truncatingRemainder(dividingBy: 1)
                                    let x = CGFloat(phase) * size.width
                                    let glow = (1 - abs(phase - 0.5) * 2) * 0.68
                                    let radius = particle.isMultiple(of: 3) ? 1.4 : 0.8
                                    let rect = CGRect(x: x, y: 2 - radius, width: radius * 2, height: radius * 2)
                                    graphics.fill(Path(ellipseIn: rect), with: .color(NethPalette.green.opacity(glow)))
                                }
                            }
                        }
                        .accessibilityHidden(true)
                    }
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct QuattroPanel: View {
    @Environment(\.dismiss) private var dismiss
    let choose: (ToolDefinition) -> Void
    @State private var query = ""
    @State private var category = "All"
    @State private var limit = 80
    private let catalog = ToolCatalog.shared

    var body: some View {
        let selectedCategory = category == "All" ? nil : category
        let results = catalog.find(query, category: selectedCategory, limit: limit + 1)
        NavigationStack {
            List {
                Section {
                    Picker("Category", selection: $category) {
                        Text("All").tag("All")
                        ForEach(Set(catalog.tools.map(\.category)).sorted(), id: \.self) { item in
                            Text(item).tag(item)
                        }
                    }
                } footer: {
                    Text("\(catalog.actionCount) actions · \(catalog.conversionCount.formatted()) unit conversions")
                }
                ForEach(results.prefix(limit)) { tool in
                    Button {
                        choose(tool)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: tool.title).foregroundStyle(.white)
                            Text(verbatim: tool.summary).font(.caption).foregroundStyle(NethPalette.muted)
                            Text(verbatim: tool.id).font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(NethPalette.accent)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                if results.count > limit {
                    Button("More tools") { limit += 100 }
                }
            }
            .scrollContentBackground(.hidden)
            .background(NethPalette.canvas)
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView("No matching tools", systemImage: "magnifyingglass")
                }
            }
            .searchable(text: $query, prompt: "Search tool names or units")
            .navigationTitle("Quattro tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: query) { _, _ in limit = 80 }
            .onChange(of: category) { _, _ in limit = 80 }
        }
    }
}

struct WorkspaceFileCard: View {
    let file: WorkspaceFile
    @State private var preview: URL?

    var body: some View {
        if let url = ChatWorkspace.url(for: file) {
            HStack(spacing: 11) {
                Button {
                    preview = url
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: file.name.hasSuffix(".zip") ? "archivebox" : "doc.text")
                            .foregroundStyle(NethPalette.green)
                            .frame(width: 34, height: 34)
                            .background(NethPalette.green.opacity(0.11), in: .rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: file.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file)
                                 + (file.partial ? " · Draft" : ""))
                                .font(.caption)
                                .foregroundStyle(NethPalette.muted)
                        }
                    }
                    .frame(minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 3)
                ShareLink(item: url, preview: SharePreview(file.name, image: Image(systemName: "doc.text"))) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Share \(file.name)")
            }
            .padding(6)
            .padding(.leading, 4)
            .background(NethPalette.surface, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NethPalette.border))
            .quickLookPreview($preview)
        }
    }
}
