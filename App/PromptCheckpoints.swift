import Foundation

struct PromptCheckpoints {
    private static let capacity: Int64 = 1_610_612_736
    private static let freeSpaceReserve: Int64 = 536_870_912
    private let directory = URL.cachesDirectory.appending(path: "PromptCheckpoints", directoryHint: .isDirectory)
    private let files = FileManager.default

    func location(conversation: String, profile: RuntimeProfile) -> URL? {
        guard let id = UUID(uuidString: conversation) else { return nil }
        let model = ModelAsset.qwen.checksum
        let name = "\(id.uuidString)-b12549-v1-\(model)-\(profile.backend)-\(profile.context)-\(profile.cache).state"
        return directory.appending(path: name)
    }

    func save(_ runtime: OpaquePointer, at location: URL) -> Bool {
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            for pending in entries() where pending.pathExtension == "pending" {
                try? files.removeItem(at: pending)
            }
            let free = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
            guard let free else { return false }
            let limit = min(Self.capacity, Int64(free) - Self.freeSpaceReserve)
            guard limit > 0 else { return false }
            let pending = location.appendingPathExtension("pending")
            let saved = nl_save_prompt(runtime, location.path, pending.path, Int(limit)) > 0
            if saved {
                touch(location)
                prune(keeping: location)
            }
            return saved
        } catch { return false }
    }

    func touch(_ location: URL) {
        try? files.setAttributes([.modificationDate: Date()], ofItemAtPath: location.path)
    }

    func remove(conversation: String) {
        guard let id = UUID(uuidString: conversation) else { return }
        for file in entries() where file.lastPathComponent.hasPrefix("\(id.uuidString)-") {
            try? files.removeItem(at: file)
        }
    }

    func clear() -> Bool {
        guard files.fileExists(atPath: directory.path) else { return true }
        do {
            try files.removeItem(at: directory)
            return true
        } catch { return false }
    }

    private func entries() -> [URL] {
        (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private func prune(keeping current: URL) {
        let states = entries().filter { $0.pathExtension == "state" }.compactMap { file -> (URL, Int64, Date)? in
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = values?.fileSize else { return nil }
            return (file, Int64(size), values?.contentModificationDate ?? .distantPast)
        }
        var total = states.reduce(Int64(0)) { $0 + $1.1 }
        for (file, size, _) in states.sorted(by: { $0.2 < $1.2 }) where file != current && total > Self.capacity {
            do {
                try files.removeItem(at: file)
                total -= size
            } catch { continue }
        }
    }
}
