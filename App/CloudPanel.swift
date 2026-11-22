import SwiftUI

@MainActor
struct CloudComputeSection: View {
    @ObservedObject var cloud: NethCloud
    let windowsLinked: Bool
    let busy: Bool
    let pair: () -> Void
    let report: (String) -> Void
    @State private var metrics = CloudMetrics.Snapshot()

    var body: some View {
        Section {
            if cloud.servers.isEmpty {
                Button { pair() } label: {
                    Label("Add cloud server", systemImage: "server.rack")
                }
                .disabled(busy || windowsLinked)
            } else {
                ForEach(cloud.servers) { server in
                    Button {
                        guard !busy, !windowsLinked else { return }
                        Task { await cloud.connect(server) }
                    } label: {
                        deviceRow(server.name, detail: server.host, icon: "icloud",
                                  selected: cloud.selectedID == server.id)
                    }
                    .disabled(busy || windowsLinked)
                    .swipeActions {
                        Button("Forget", role: .destructive) {
                            do { try cloud.remove(server) }
                            catch { report(error.localizedDescription) }
                        }
                    }
                }
                Button("Add another server", systemImage: "plus") { pair() }
                    .disabled(busy || windowsLinked)
            }
            if cloud.selectedID != nil || cloud.status != .idle {
                statusRow
            }
            if let compute = cloud.compute {
                LabeledContent("Model", value: compute.server.model.isEmpty ? "Server default" : compute.server.model)
                Picker("Context", selection: $cloud.context) {
                    ForEach(CloudCompute.contexts, id: \.self) { tokens in
                        Text("\(tokens.formatted()) tokens").tag(tokens)
                    }
                }
                connectionDetails
                Button("Disconnect", role: .destructive) { cloud.disconnect() }
                    .disabled(busy)
            }
        } header: {
            Text("Neth Cloud GPU")
        } footer: {
            if windowsLinked {
                Text("Disconnect the Windows compute device to use cloud inference.")
            } else {
                Text("Free Colab runtimes sleep and disconnect on their own, and each session prints a fresh connect code. Keep Colab as the interactive test environment; use a dedicated GPU host for always-on service.")
            }
        }
        .listRowBackground(NethPalette.surface)
        .disabled(busy)
        .task(id: cloud.status) {
            while !Task.isCancelled {
                metrics = CloudMetrics.shared.snapshot
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(verbatim: cloud.status.detail)
                .font(.caption)
                .foregroundStyle(NethPalette.muted)
                .lineLimit(3)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch cloud.status {
        case .ready: NethPalette.violet
        case .checking: NethPalette.lilac
        case .failed: NethPalette.lilac
        case .idle: NethPalette.muted
        }
    }

    @ViewBuilder
    private var connectionDetails: some View {
        LabeledContent("Server latency", value: metrics.latency.map { String(format: "%.0f ms", $0 * 1000) } ?? "—")
        LabeledContent("Last reply speed", value: metrics.tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "—")
        LabeledContent("First token", value: metrics.firstToken.map { String(format: "%.2f s", $0) } ?? "—")
        if let tokens = metrics.tokens {
            LabeledContent("Last reply", value: "\(tokens.formatted()) tokens")
        }
    }

    private func deviceRow(_ name: String, detail: String, icon: String, selected: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(selected ? NethPalette.lilac : NethPalette.muted)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: name).foregroundStyle(NethPalette.text)
                Text(detail).font(.caption).foregroundStyle(NethPalette.muted)
            }
            Spacer()
            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(NethPalette.violet) }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor
struct CloudPairingPanel: View {
    @ObservedObject var cloud: NethCloud
    let paired: (CloudServer) -> Void
    @State private var code = ""
    @State private var pending = false
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                Text("Run the Neth Cloud notebook in Colab, wait for the connect cell to print a code, then paste it here. The code contains the HTTPS address and the API key this session generated.")
                    .foregroundStyle(NethPalette.muted)
                TextField("Connect code", text: $code)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .onSubmit { connect(code) }
                PasteButton(payloadType: String.self) { values in
                    if let value = values.first { code = value }
                }
                Button("Connect", systemImage: "link") { connect(code) }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pending)
            }
            .listRowBackground(NethPalette.surface)
            .disabled(pending)
            if pending {
                Section {
                    ProgressView("Checking the server…")
                    Button("Cancel") { pending = false }
                }
                .listRowBackground(NethPalette.surface)
            }
            if let problem {
                Text(verbatim: problem)
                    .foregroundStyle(NethPalette.lilac)
                    .listRowBackground(NethPalette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(NethPalette.canvas)
        .navigationTitle("Add cloud server")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func connect(_ candidate: String) {
        guard !pending else { return }
        do {
            let server = try CloudServer.parse(candidate)
            pending = true
            problem = nil
            Task {
                defer { pending = false }
                await cloud.connect(server)
                switch cloud.status {
                case .ready:
                    code = ""
                    paired(server)
                case .failed(let reason):
                    problem = reason
                default: break
                }
            }
        } catch {
            problem = error.localizedDescription
        }
    }
}
