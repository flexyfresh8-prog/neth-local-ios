import AVFoundation
import SwiftUI
import VisionKit

@MainActor
struct WindowsComputeSection: View {
    @ObservedObject var devices: WindowsDevices
    let hasModel: Bool
    let busy: Bool
    let chooseModel: () -> Void
    @State private var pairing = false
    @State private var problem: String?

    var body: some View {
        Section {
            Button { devices.choose(nil) } label: {
                deviceRow("This iPad", detail: "Local inference", icon: "ipad", selected: devices.compute == nil)
            }
            ForEach(devices.devices) { device in
                Button {
                    chooseModel()
                    devices.choose(device)
                } label: {
                    deviceRow(device.name, detail: "5 GHz Mobile Hotspot", icon: "laptopcomputer",
                              selected: devices.selectedID == device.id)
                }
                .disabled(!hasModel)
                .swipeActions {
                    Button("Forget", role: .destructive) {
                        do { try devices.remove(device) }
                        catch { problem = error.localizedDescription }
                    }
                }
            }
            Button("Pair Windows device", systemImage: "qrcode.viewfinder") { pairing = true }
            if devices.compute != nil {
                Picker("Layers on Windows", selection: $devices.layers) {
                    ForEach(WindowsCompute.splits, id: \.self) { layers in
                        Text("\(layers) of 32").tag(layers)
                    }
                }
            }
        } header: {
            Text("Compute device")
        } footer: {
            if !hasModel {
                Text("Download the bundled Qwen3.5 4B on both devices to share inference.")
            } else if devices.compute != nil {
                Text("Both devices run one Qwen3.5 4B reply. Shared compute supports text and up to 32K context. Prompt checkpoints are available on This iPad.")
            }
        }
        .listRowBackground(NethPalette.surface)
        .disabled(busy)
        .sheet(isPresented: $pairing) {
            WindowsPairingPanel { peer in
                try devices.add(peer)
                if hasModel {
                    chooseModel()
                    devices.choose(peer)
                }
            }
        }
        .alert("Windows compute", isPresented: Binding(
            get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
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
private struct WindowsPairingPanel: View {
    let paired: (WindowsDevice) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var checking = false
    @State private var scanning = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Start the Windows companion and join its 5 GHz Mobile Hotspot in iPad Settings. Then scan the QR code shown on the laptop.")
                        .foregroundStyle(NethPalette.muted)
                    Button("Scan Windows QR code", systemImage: "qrcode.viewfinder") {
                        Task { await scan() }
                    }
                    TextField("Pairing code", text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .onSubmit { add(code) }
                    Button("Connect", systemImage: "link") { add(code) }
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if checking { ProgressView("Checking the 5 GHz connection…") }
                    if let problem {
                        Text(verbatim: problem).foregroundStyle(NethPalette.lilac)
                    }
                }
                .listRowBackground(NethPalette.surface)
                .disabled(checking)
            }
            .scrollContentBackground(.hidden)
            .background(NethPalette.canvas)
            .navigationTitle("Pair Windows device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(checking)
                }
            }
        }
        .interactiveDismissDisabled(checking)
        .sheet(isPresented: $scanning) {
            NavigationStack {
                WindowsQRScanner { payload in
                    scanning = false
                    add(payload)
                } failed: {
                    scanning = false
                    problem = "The camera is unavailable. Paste the Windows pairing code to continue."
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Scan pairing code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { scanning = false }
                    }
                }
            }
        }
    }

    private func scan() async {
        guard DataScannerViewController.isSupported,
              await AVCaptureDevice.requestAccess(for: .video),
              DataScannerViewController.isAvailable else {
            problem = "Camera access is unavailable. Paste the Windows pairing code to continue."
            return
        }
        scanning = true
    }

    private func add(_ candidate: String) {
        guard !checking else { return }
        do {
            let peer = try WindowsDevice.parse(candidate)
            checking = true
            problem = nil
            Task {
                defer { checking = false }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try WindowsLink(device: peer).open()
                    }.value
                    try paired(peer)
                    dismiss()
                } catch {
                    problem = error.localizedDescription
                }
            }
        } catch {
            problem = error.localizedDescription
        }
    }
}

private struct WindowsQRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void
    let failed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        DispatchQueue.main.async {
            do { try scanner.startScanning() }
            catch { failed() }
        }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var recognized = false

        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !recognized else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let code = barcode.payloadStringValue, code.hasPrefix("NETH36.") {
                    recognized = true
                    scanner.stopScanning()
                    found(code)
                    break
                }
            }
        }
    }
}
