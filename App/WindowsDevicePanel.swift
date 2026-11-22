import AVFoundation
import SwiftUI
import UIKit
import VisionKit

@MainActor
struct WindowsComputeSection: View {
    @ObservedObject var devices: WindowsDevices
    let hasModel: Bool
    let cloudLinked: Bool
    let busy: Bool
    let chooseModel: () -> Void
    let pair: () -> Void
    let report: (String) -> Void

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
                    deviceRow(device.name, detail: devices.sessionOnly.contains(device.id) ? "Paired for this session" : "5 GHz Mobile Hotspot",
                              icon: "laptopcomputer",
                              selected: devices.selectedID == device.id)
                }
                .disabled(!hasModel)
                .swipeActions {
                    Button("Forget", role: .destructive) {
                        do { try devices.remove(device) }
                        catch { report(error.localizedDescription) }
                    }
                }
            }
            Button("Pair Windows device", systemImage: "qrcode.viewfinder", action: pair)
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
            if cloudLinked {
                Text("Disconnect the Neth Cloud GPU server to share inference with a paired Windows computer.")
            } else if !hasModel {
                Text("Download the bundled Qwen3.5 4B on both devices to share inference.")
            } else if devices.compute != nil {
                Text("Both devices run one Qwen3.5 4B reply. Shared compute supports text and up to 32K context. Prompt checkpoints are available on This iPad.")
            }
        }
        .listRowBackground(NethPalette.surface)
        .disabled(busy || cloudLinked)
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
struct WindowsPairingPanel: View {
    let paired: (WindowsDevice) -> Void
    @State private var code = ""
    @State private var pending: WindowsDevice?
    @State private var showCamera = false
    @State private var scanning = false
    @State private var problem: String?

    var body: some View {
        Group {
            if scanning {
                WindowsQRScanner { payload in
                    scanning = false
                    add(payload)
                } failed: {
                    scanning = false
                    problem = "The camera is unavailable. Paste the Windows pairing code to continue."
                }
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    Text("Scan the QR code in Neth Local Windows")
                        .font(.footnote.weight(.semibold))
                        .padding(12)
                        .background(.regularMaterial, in: .capsule)
                        .padding()
                        .allowsHitTesting(false)
                }
            } else {
                pairingForm
            }
        }
        .background(NethPalette.canvas)
        .navigationTitle("Pair Windows device")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if scanning {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enter code") { scanning = false }
                }
            }
        }
        .task(id: showCamera) {
            if showCamera { await scan() }
        }
        .task(id: pending) {
            if let pending { await connect(pending) }
        }
    }

    private var pairingForm: some View {
        List {
            Section {
                Text("Join the laptop’s 5 GHz Mobile Hotspot in iPad Settings. Then scan the QR code in Neth Local Windows or paste its pairing code.")
                    .foregroundStyle(NethPalette.muted)
                Button("Scan Windows QR code", systemImage: "qrcode.viewfinder") { showCamera = true }
                    .disabled(showCamera)
                TextField("Pairing code", text: $code)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .onSubmit { add(code) }
                PasteButton(payloadType: String.self) { values in
                    if let value = values.first { code = value }
                }
                Button("Connect", systemImage: "link") { add(code) }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .listRowBackground(NethPalette.surface)
            .disabled(pending != nil || showCamera)
            if pending != nil {
                Section {
                    ProgressView("Checking the hotspot connection…")
                    Button("Cancel connection") { pending = nil }
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
    }

    private func scan() async {
        defer { showCamera = false }
        let available = DataScannerViewController.isSupported
        let allowed = available ? await AVCaptureDevice.requestAccess(for: .video) : false
        guard !Task.isCancelled else { return }
        guard allowed, DataScannerViewController.isAvailable else {
            problem = "Camera access is unavailable. Paste the Windows pairing code to continue."
            return
        }
        problem = nil
        scanning = true
    }

    private func add(_ candidate: String) {
        guard pending == nil else { return }
        do {
            pending = try WindowsDevice.parse(candidate)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func connect(_ peer: WindowsDevice) async {
        let stop = GenerationStop()
        defer { if !Task.isCancelled { pending = nil } }
        do {
            try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try WindowsLink(device: peer, stop: stop).open()
                }.value
                try Task.checkCancellation()
            } onCancel: {
                stop.request()
            }
            code = ""
            paired(peer)
        } catch {
            if !Task.isCancelled { problem = error.localizedDescription }
        }
    }
}

private struct WindowsQRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void
    let failed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(found: found, failed: failed) }

    func makeUIViewController(context: Context) -> ScannerHost {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return ScannerHost(scanner: scanner, failed: failed)
    }

    func updateUIViewController(_ host: ScannerHost, context: Context) {}

    static func dismantleUIViewController(_ host: ScannerHost, coordinator: Coordinator) {
        host.scanner.stopScanning()
    }

    final class ScannerHost: UIViewController {
        let scanner: DataScannerViewController
        let failed: () -> Void

        init(scanner: DataScannerViewController, failed: @escaping () -> Void) {
            self.scanner = scanner
            self.failed = failed
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Use init(scanner:failed:)") }

        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(scanner)
            scanner.view.frame = view.bounds
            scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(scanner.view)
            scanner.didMove(toParent: self)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            do { try scanner.startScanning() }
            catch { failed() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            scanner.stopScanning()
            super.viewWillDisappear(animated)
        }
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        let failed: () -> Void
        private var finished = false

        init(found: @escaping (String) -> Void, failed: @escaping () -> Void) {
            self.found = found
            self.failed = failed
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !finished else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let code = barcode.payloadStringValue,
                   code.hasPrefix(WindowsDevice.pairingPrefix) {
                    finished = true
                    scanner.stopScanning()
                    found(code)
                    break
                }
            }
        }

        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            guard !finished else { return }
            finished = true
            failed()
        }
    }
}
