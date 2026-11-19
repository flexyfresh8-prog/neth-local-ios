import CryptoKit
import Foundation
import SwiftUI

struct LocalError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ModelAsset: String, CaseIterable {
    case qwen, vision

    private static let repo = "HauhauCS/Qwen3.5-4B-Uncensored-HauhauCS-Aggressive"
    private static let revision = "c09cdbcdb1fefad6d335809d445621b5f5ba0c6e"

    var title: String {
        switch self {
        case .qwen: "Qwen3.5 4B Uncensored"
        case .vision: "Qwen vision projector"
        }
    }

    var filename: String {
        switch self {
        case .qwen: "Qwen3.5-4B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf"
        case .vision: "mmproj-Qwen3.5-4B-Uncensored-HauhauCS-Aggressive-BF16.gguf"
        }
    }

    var bytes: Int64 {
        switch self {
        case .qwen: 2_707_513_696
        case .vision: 675_568_768
        }
    }

    var checksum: String {
        switch self {
        case .qwen: "79e28ecacf84e75b6056cf4059636d435aa9eb67795780f7b7dbc7d32a962741"
        case .vision: "a1e32e86ea99aa7a56f3dcfe7e63c1d0be9439d31fd07087099f15bc0fda0f22"
        }
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(Self.repo)/resolve/\(Self.revision)/\(filename)?download=true")!
    }

    static let modelCard = URL(string: "https://huggingface.co/\(repo)")!
}

struct InstalledModel: Identifiable, Equatable, Sendable {
    var id: String { url.path }
    let title: String
    let url: URL
    let bytes: Int64
    let isPreset: Bool
}

private final class ModelTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private let completion: @Sendable (Result<URL, Error>) -> Void
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var result: Result<URL, Error>?

    init(destination: URL, progress: @escaping @Sendable (Int64) -> Void,
         completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        self.destination = destination
        self.progress = progress
        self.completion = completion
    }

    func start(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 8 * 60 * 60
        configuration.waitsForConnectivity = true
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        task = session.downloadTask(with: url)
        task?.resume()
    }

    func cancel() { task?.cancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        result = Result {
            guard let http = downloadTask.response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
                throw LocalError(message: "The model server returned HTTP \(status).")
            }
            try FileManager.default.moveItem(at: location, to: destination)
            return destination
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            try? FileManager.default.removeItem(at: destination)
            completion(.failure(error))
        } else {
            completion(result ?? .failure(LocalError(message: "The download produced no file.")))
        }
        session.finishTasksAndInvalidate()
    }
}

@MainActor
final class LocalModels: ObservableObject {
    @Published private(set) var installed: [InstalledModel] = []
    @Published var selectedID: String? {
        didSet { UserDefaults.standard.set(selectedID, forKey: "selectedModel") }
    }
    @Published private(set) var activeDownload: ModelAsset?
    @Published private(set) var fraction: Double = 0
    @Published private(set) var verifying = false
    @Published private(set) var importing = false
    @Published private(set) var projector: URL?
    @Published var problem: String?

    private let root: URL
    private let imports: URL
    private var transfer: ModelTransfer?
    private var downloadID: UUID?

    var current: InstalledModel? { installed.first { $0.id == selectedID } }

    init() {
        root = URL.applicationSupportDirectory.appending(path: "Models", directoryHint: .isDirectory)
        imports = root.appending(path: "Imported", directoryHint: .isDirectory)
        selectedID = UserDefaults.standard.string(forKey: "selectedModel")
        do {
            try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
            var directory = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where file.pathExtension == "partial" {
                try? FileManager.default.removeItem(at: file)
            }
            refresh()
        } catch {
            problem = error.localizedDescription
        }
    }

    func has(_ asset: ModelAsset) -> Bool {
        switch asset {
        case .qwen: installed.contains(where: \.isPreset)
        case .vision: projector != nil
        }
    }

    func download(_ asset: ModelAsset) {
        guard activeDownload == nil, !has(asset) else { return }
        if let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage, free < asset.bytes + 134_217_728 {
            problem = "Free at least \(Self.size(asset.bytes + 134_217_728)) of iPad storage to download this model."
            return
        }
        let id = UUID()
        downloadID = id
        activeDownload = asset
        fraction = 0
        let temp = root.appending(path: "\(id.uuidString).partial")
        let destination = root.appending(path: asset.filename)
        let transfer = ModelTransfer(destination: temp) { [weak self] bytes in
            Task { @MainActor in
                guard let self, self.downloadID == id else { return }
                self.fraction = min(1, Double(bytes) / Double(asset.bytes))
            }
        } completion: { [weak self] result in
            Task { @MainActor in
                guard let self, self.downloadID == id else {
                    try? FileManager.default.removeItem(at: temp)
                    return
                }
                do {
                    let downloaded = try result.get()
                    self.verifying = true
                    try await Task.detached(priority: .utility) {
                        try Self.verify(downloaded, asset: asset)
                        try FileManager.default.moveItem(at: downloaded, to: destination)
                    }.value
                    self.refresh()
                } catch {
                    try? FileManager.default.removeItem(at: temp)
                    if (error as? URLError)?.code != .cancelled { self.problem = error.localizedDescription }
                }
                self.downloadID = nil
                self.activeDownload = nil
                self.verifying = false
                self.transfer = nil
            }
        }
        self.transfer = transfer
        transfer.start(url: asset.downloadURL)
    }

    func cancelDownload() { transfer?.cancel() }

    func importGGUF(_ source: URL) {
        guard !importing else { return }
        let importedName = source.deletingPathExtension().lastPathComponent
        let destination = imports.appending(path: "\(importedName).gguf")
        importing = true
        Task {
            defer { importing = false }
            do {
                try await Task.detached(priority: .utility) {
                    let access = source.startAccessingSecurityScopedResource()
                    defer { if access { source.stopAccessingSecurityScopedResource() } }
                    let file = try FileHandle(forReadingFrom: source)
                    let magic = try file.read(upToCount: 4)
                    try file.close()
                    guard magic == Data("GGUF".utf8) else {
                        throw LocalError(message: "Choose a GGUF model file in Files.")
                    }
                    if FileManager.default.fileExists(atPath: destination.path) {
                        throw LocalError(message: "A model with that filename is already imported.")
                    }
                    let temp = destination.deletingLastPathComponent().appending(path: "\(UUID().uuidString).partial")
                    defer { try? FileManager.default.removeItem(at: temp) }
                    try FileManager.default.copyItem(at: source, to: temp)
                    try FileManager.default.moveItem(at: temp, to: destination)
                }.value
                refresh()
                selectedID = destination.path
            } catch { problem = error.localizedDescription }
        }
    }

    func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            refresh()
        } catch { problem = error.localizedDescription }
    }

    private func refresh() {
        let preset = root.appending(path: ModelAsset.qwen.filename)
        let imported = (try? FileManager.default.contentsOfDirectory(at: imports, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        installed = ([preset] + imported.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }))
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .compactMap { url in
                guard let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, bytes > 0 else { return nil }
                let isPreset = url == preset
                return InstalledModel(title: isPreset ? ModelAsset.qwen.title : url.deletingPathExtension().lastPathComponent,
                                      url: url, bytes: Int64(bytes), isPreset: isPreset)
            }
        let vision = root.appending(path: ModelAsset.vision.filename)
        let bytes = (try? vision.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        projector = Int64(bytes) == ModelAsset.vision.bytes ? vision : nil
        if current == nil { selectedID = installed.first?.id }
    }

    nonisolated static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private nonisolated static func verify(_ url: URL, asset: ModelAsset) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(size) == asset.bytes else { throw LocalError(message: "The downloaded file is incomplete. Download it again.") }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let block = try file.read(upToCount: 1_048_576), !block.isEmpty {
            hash.update(data: block)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == asset.checksum else {
            throw LocalError(message: "The downloaded file failed its integrity check. Download it again.")
        }
    }
}
