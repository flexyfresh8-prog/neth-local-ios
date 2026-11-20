import QuickLook
import SwiftUI

struct EffortMeter: View {
    let activity: String
    let step: Int
    let total: Int
    let running: Bool
    let metrics: GenerationMetrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scene

    private var fraction: Double {
        min(0.96, max(0.12, (Double(step) - 0.35) / Double(max(1, total))))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    status
                    Spacer(minLength: 0)
                    signal.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 4) {
                    status
                    readout
                }
            }
            .font(.caption.weight(.medium))

            if running {
                GeometryReader { layout in
                    ZStack(alignment: .leading) {
                        Capsule().fill(NethPalette.border)
                        progressFill(width: layout.size.width)
                    }
                }
                .frame(height: 2)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(running ? NethPalette.violetSurface.opacity(0.47) : NethPalette.inset, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(running ? NethPalette.violet.opacity(0.25) : NethPalette.border.opacity(0.7))
            .allowsHitTesting(false))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func progressFill(width: CGFloat) -> some View {
        let fill = LinearGradient(colors: [NethPalette.violet.opacity(0.5), NethPalette.lilac],
                                  startPoint: .leading, endPoint: .trailing)
        if total > 1 && step > 0 {
            Capsule().fill(fill)
                .frame(width: width * fraction)
                .animation(reduceMotion ? nil : NethMotion.reveal, value: fraction)
        } else {
            let bandWidth = width * 0.23
            Capsule().fill(fill)
                .frame(width: bandWidth)
                .phaseAnimator(reduceMotion || scene != .active ? [false] : [false, true]) { band, atEnd in
                    band.offset(x: atEnd ? width - bandWidth : 0)
                } animation: { _ in .easeInOut(duration: 1.35) }
        }
    }

    private var status: some View {
        HStack(spacing: 7) {
            NethMascotMark(active: running)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(running ? NethPalette.violetSurface : NethPalette.rail, in: .rect(cornerRadius: 5))
            Text(verbatim: activity)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : NethMotion.fade, value: activity)
            if running && total > 1 && step > 0 {
                Text("\(step)/\(total)").monospacedDigit()
            }
        }
        .foregroundStyle(NethPalette.muted)
    }

    private var signal: some View {
        HStack(spacing: 12) {
            if !metrics.speeds.isEmpty { speedGraph }
            readout
        }
    }

    private var speedGraph: some View {
        let scale = max(1, metrics.speeds.max() ?? 0)
        let missing = GenerationMetrics.speedSampleLimit - metrics.speeds.count
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<GenerationMetrics.speedSampleLimit, id: \.self) { index in
                let sample = index >= missing ? metrics.speeds[index - missing] : 0
                let height = sample > 0 ? 3 + 13 * (sample / scale) : 2
                Capsule()
                    .fill(sample > 0 ? NethPalette.violet.opacity(0.40 + Double(index) * 0.05) : NethPalette.border)
                    .frame(width: 2.5, height: height)
                    .animation(reduceMotion ? nil : NethMotion.reveal, value: height)
            }
        }
        .frame(height: 16, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private var readout: some View {
        HStack(spacing: 9) {
            Text("\(metrics.tokens.formatted()) \(metrics.tokens == 1 ? "token" : "tokens")")
                .foregroundStyle(NethPalette.violet)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : NethMotion.press, value: metrics.tokens)
            let rate = metrics.tokensPerSecond?.formatted(.number.precision(.fractionLength(1))) ?? "—"
            Text("\(rate) tok/s")
                .foregroundStyle(NethPalette.muted)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : NethMotion.press, value: rate)
        }
        .font(.system(.caption, design: .monospaced, weight: .medium))
        .monospacedDigit()
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
                            .foregroundStyle(NethPalette.lilac)
                            .frame(width: 34, height: 34)
                            .background(NethPalette.violetSurface, in: .rect(cornerRadius: 8))
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
