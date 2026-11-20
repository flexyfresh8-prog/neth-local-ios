import CoreGraphics
import CoreText
import Foundation

actor ChatWorkspace {
    static let supportedExtensions: Set<String> = [
        "txt", "md", "csv", "tsv", "json", "jsonl", "html", "css", "js", "mjs", "ts", "tsx", "jsx",
        "py", "swift", "lua", "luau", "gd", "rs", "go", "c", "h", "cpp", "hpp", "java", "kt", "cs",
        "yaml", "yml", "toml", "xml", "ini", "conf", "sql", "sh", "ps1", "bat", "log", "svg", "pdf"
    ]

    private let root: URL
    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "ChatFiles", directoryHint: .isDirectory)
    }

    init(root: URL = ChatWorkspace.directory) { self.root = root }

    static func cleanPath(_ input: String, internalID: Bool = false) throws -> String {
        let path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= (internalID ? 7 : 5), path.utf8.count <= (internalID ? 340 : 180),
              parts.allSatisfy({ part in
                  !part.isEmpty && part.count <= 75 && part != "." && part != ".."
                  && !part.hasPrefix(".") && !part.hasSuffix(" ")
                  && part.allSatisfy { $0.isLetter || $0.isNumber || "-_. ".contains($0) }
              }) else {
            throw LocalError(message: "Use a relative filename with letters, numbers, spaces, dashes or underscores.")
        }
        return parts.joined(separator: "/")
    }

    static func supportedPath(_ input: String) throws -> String {
        let path = try cleanPath(input)
        let ext = (path as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw LocalError(message: "Choose a text, code, data or PDF filename.")
        }
        return path
    }

    static func url(for file: WorkspaceFile, root: URL = ChatWorkspace.directory) -> URL? {
        guard let id = try? cleanPath(file.id, internalID: true) else { return nil }
        return root.appending(path: id)
    }

    func save(_ text: String, name: String, conversation: String, folder: String = UUID().uuidString,
              partial: Bool = false) throws -> WorkspaceFile {
        let name = try Self.supportedPath(name)
        let ext = (name as NSString).pathExtension.lowercased()
        let bytes: Data
        if ext == "pdf" {
            bytes = try Self.pdf(text)
        } else {
            bytes = Data(text.utf8)
        }
        return try write(bytes, name: name, conversation: conversation, folder: folder, partial: partial)
    }

    func read(_ id: String, conversation: String, limit: Int = 16_000) throws -> String {
        let id = try Self.cleanPath(id, internalID: true)
        guard id.split(separator: "/").first == Substring(conversation) else {
            throw LocalError(message: "That file belongs to a different conversation.")
        }
        let url = root.appending(path: id)
        let ext = url.pathExtension.lowercased()
        guard ext != "pdf" && ext != "zip" else {
            throw LocalError(message: "Open the PDF or ZIP from its file card.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        let text = String(decoding: data.prefix(limit), as: UTF8.self)
        return data.count > limit ? text + "\n… [preview truncated]" : text
    }

    func list(conversation: String) throws -> [String] {
        let folder = try Self.cleanPath(conversation)
        guard !folder.contains("/") else { throw LocalError(message: "Invalid workspace.") }
        let directory = root.appending(path: folder)
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                                               options: [.skipsHiddenFiles]) else { return [] }
        var names: [String] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                names.append(String(url.path.dropFirst(root.path.count + 1)))
                if names.count >= 100 { break }
            }
        }
        return names.sorted()
    }

    func remove(conversation: String) {
        guard let directory = try? Self.cleanPath(conversation), !directory.contains("/") else { return }
        try? FileManager.default.removeItem(at: root.appending(path: directory))
    }

    func archive(_ files: [WorkspaceFile], name: String, conversation: String,
                 folder: String = UUID().uuidString) throws -> WorkspaceFile {
        guard !files.isEmpty else { throw LocalError(message: "Create files before making a ZIP.") }
        let name = try Self.cleanPath(name)
        guard (name as NSString).pathExtension.lowercased() == "zip" else {
            throw LocalError(message: "Use a .zip filename.")
        }
        let prefix = try Self.cleanPath(conversation) + "/"
        var entries: [(String, Data)] = []
        var combined = 0
        for file in files {
            guard file.id.hasPrefix(prefix), let url = Self.url(for: file, root: root) else {
                throw LocalError(message: "Open a file from this conversation.")
            }
            let itemName = try Self.cleanPath(file.name)
            if entries.contains(where: { $0.0 == itemName }) {
                throw LocalError(message: "Two files have the same path in the ZIP.")
            }
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            combined += bytes.count
            guard combined <= 32_000_000 else { throw LocalError(message: "The ZIP exceeds 32 MB.") }
            entries.append((itemName, bytes))
        }
        return try write(StoredZIP.make(entries), name: name, conversation: conversation, folder: folder,
                         partial: files.contains(where: \.partial))
    }

    private func write(_ data: Data, name: String, conversation: String, folder: String,
                       partial: Bool) throws -> WorkspaceFile {
        let conversation = try Self.cleanPath(conversation)
        let folder = try Self.cleanPath(folder)
        guard !conversation.contains("/"), !folder.contains("/"), data.count <= 32_000_000 else {
            throw LocalError(message: "The workspace path or file size is invalid.")
        }
        let id = try Self.cleanPath("\(conversation)/\(folder)/\(name)", internalID: true)
        let url = root.appending(path: id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return WorkspaceFile(id: id, name: name, bytes: data.count, partial: partial)
    }

    private static func pdf(_ text: String) throws -> Data {
        let output = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: output), let pdf = CGContext(consumer: consumer, mediaBox: &page, nil)
        else { throw LocalError(message: "Couldn't create the PDF.") }
        let content = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        ])
        let layout = CTFramesetterCreateWithAttributedString(content)
        let bounds = CGPath(rect: page.insetBy(dx: 47, dy: 49), transform: nil)
        var position = 0
        while position < content.length {
            pdf.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(layout, CFRange(location: position, length: 0), bounds, nil)
            CTFrameDraw(frame, pdf)
            pdf.endPDFPage()
            let count = CTFrameGetVisibleStringRange(frame).length
            guard count > 0 else { break }
            position += count
        }
        pdf.closePDF()
        return output as Data
    }
}

private enum StoredZIP {
    private static let checksums: [UInt32] = (0..<256).map { byte in
        (0..<8).reduce(UInt32(byte)) { value, _ in
            (value >> 1) ^ ((value & 1) == 0 ? 0 : 0xedb88320)
        }
    }

    static func make(_ entries: [(String, Data)]) -> Data {
        var zip = Data()
        var central = Data()
        for (name, bytes) in entries {
            let path = Data(name.utf8)
            let crc = ~bytes.reduce(UInt32.max) { (value, byte) in
                (value >> 8) ^ checksums[Int((value ^ UInt32(byte)) & 255)]
            }
            let start = UInt32(zip.count)
            let size = UInt32(bytes.count)
            let nameLength = UInt16(path.count)
            let flags: UInt16 = 0x0800
            zip.little(UInt32(0x04034b50))
            for field in [UInt16(20), flags, 0, 0, 33] { zip.little(field) }
            for field in [crc, size, size] { zip.little(field) }
            zip.little(nameLength)
            zip.little(UInt16(0))
            zip.append(path)
            zip.append(bytes)

            central.little(UInt32(0x02014b50))
            for field in [UInt16(20), 20, flags, 0, 0, 33] { central.little(field) }
            for field in [crc, size, size] { central.little(field) }
            for field in [nameLength, 0, 0, 0, 0] { central.little(field) }
            central.little(UInt32(0))
            central.little(start)
            central.append(path)
        }
        let start = UInt32(zip.count)
        zip.append(central)
        zip.little(UInt32(0x06054b50))
        for field in [UInt16(0), 0, UInt16(entries.count), UInt16(entries.count)] { zip.little(field) }
        zip.little(UInt32(central.count))
        zip.little(start)
        zip.little(UInt16(0))
        return zip
    }
}

private extension Data {
    mutating func little<T: FixedWidthInteger>(_ n: T) {
        var copy = n.littleEndian
        Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
    }
}
