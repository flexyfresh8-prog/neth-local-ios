import QuickLook
import SwiftUI

struct EffortMeter: View {
    let activity: String
    let step: Int
    let total: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double {
        if total <= 1 { return 0.23 }
        return min(0.93, max(0.12, (Double(step) - 0.35) / Double(total)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(verbatim: activity)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : NethMotion.fade, value: activity)
                Spacer(minLength: 5)
                if total > 1 {
                    Text("\(step)/\(total)").monospacedDigit()
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(NethPalette.muted)

            GeometryReader { layout in
                let width = layout.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(NethPalette.border)
                    Capsule().fill(NethPalette.muted)
                        .frame(width: width * fraction)
                        .animation(reduceMotion ? nil : NethMotion.reveal, value: fraction)
                }
            }
            .frame(height: 2)
            .accessibilityHidden(true)
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
                .listRowBackground(NethPalette.surface)
                ForEach(results.prefix(limit)) { tool in
                    Button {
                        choose(tool)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: tool.title).foregroundStyle(NethPalette.text)
                            Text(verbatim: tool.summary).font(.caption).foregroundStyle(NethPalette.muted)
                            Text(verbatim: tool.id).font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(NethPalette.muted)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(NethPress())
                    .listRowBackground(NethPalette.surface)
                }
                if results.count > limit {
                    Button("More tools") { limit += 100 }.listRowBackground(NethPalette.surface)
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
                            .foregroundStyle(NethPalette.text)
                            .frame(width: 34, height: 34)
                            .background(NethPalette.selected, in: .rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: file.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(NethPalette.text)
                                .lineLimit(2)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file)
                                 + (file.partial ? " · Draft" : ""))
                                .font(.caption)
                                .foregroundStyle(NethPalette.muted)
                        }
                    }
                    .frame(minHeight: 44, alignment: .leading)
                }
                .buttonStyle(NethPress())
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
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NethPalette.border).allowsHitTesting(false))
            .quickLookPreview($preview)
        }
    }
}
