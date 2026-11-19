import Darwin
import Foundation

struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var photo: URL? = nil
}

struct EngineSettings: Equatable, Sendable {
    let model: InstalledModel
    let projector: URL?
    let context: Int
    let cpuOnly: Bool
    let thinking: Bool
}

enum EngineEvent: Sendable {
    case backend(String)
    case text(String)
    case finished(count: Int, seconds: Double)
}

final class GenerationStop: @unchecked Sendable {
    let handle = nl_cancel_create()!
    func request() { nl_cancel_request(handle) }
    deinit { nl_cancel_free(handle) }
}

private final class TokenSink {
    let continuation: AsyncThrowingStream<EngineEvent, Error>.Continuation
    var firstToken: TimeInterval?

    init(_ continuation: AsyncThrowingStream<EngineEvent, Error>.Continuation) {
        self.continuation = continuation
    }
}

private let receiveChunk: NLChunk = { bytes, count, user in
    guard let bytes, let user else { return }
    let sink = Unmanaged<TokenSink>.fromOpaque(user).takeUnretainedValue()
    if sink.firstToken == nil { sink.firstToken = ProcessInfo.processInfo.systemUptime }
    sink.continuation.yield(.text(String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)))
}

final class LocalEngine: @unchecked Sendable {
    private struct RuntimeKey: Equatable {
        let url: URL
        let context: Int
        let cpuOnly: Bool
        let vision: Bool
    }

    private let work = DispatchQueue(label: "com.neth.local.inference", qos: .userInitiated)
    private var runtime: OpaquePointer?
    private var runtimeKey: RuntimeKey?
    private var usesMetal = false

    deinit { if let runtime { nl_close(runtime) } }

    func unload() { work.async { self.releaseRuntime() } }

    func stream(history: [ChatMessage], settings: EngineSettings, stop: GenerationStop)
        -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in stop.request() }
            work.async {
                do {
                    try self.generate(history: history, settings: settings, stop: stop, continuation: continuation)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }

    private func releaseRuntime() {
        if let runtime { nl_close(runtime) }
        runtime = nil
        runtimeKey = nil
    }

    private func generate(history: [ChatMessage], settings: EngineSettings, stop: GenerationStop,
                          continuation: AsyncThrowingStream<EngineEvent, Error>.Continuation) throws {
        let vision = settings.projector != nil && history.contains { $0.photo != nil }
        let key = RuntimeKey(url: settings.model.url, context: settings.context, cpuOnly: settings.cpuOnly, vision: vision)
        if runtimeKey != key { releaseRuntime() }

        let photoBudget: Int64 = vision ? 1_210_000_000 : 0
        let overhead: Int64 = 440_000_000 + Int64(settings.context) * 65_536
        let available = Int64(nl_available_memory())
        let preferMetal = !settings.cpuOnly && (available == 0 || available > settings.model.bytes + overhead + photoBudget)
        let useMetal = runtime != nil ? usesMetal : preferMetal
        let routes = useMetal ? [true, false] : [false]

        let strings = history.map { message in
            [strdup(message.role.rawValue), strdup(message.text),
             vision ? message.photo.map { strdup($0.path) } ?? nil : nil]
        }
        defer { for fields in strings { for field in fields { free(field) } } }
        let messages = strings.map { fields in
            NLMessage(role: fields[0].map { UnsafePointer($0) },
                      text: fields[1].map { UnsafePointer($0) },
                      image_path: fields[2].map { UnsafePointer($0) })
        }
        let projector = settings.projector.map { strdup($0.path) } ?? nil
        defer { free(projector) }

        let sink = TokenSink(continuation)
        let opaque = Unmanaged.passUnretained(sink).toOpaque()
        for metal in routes {
            var error = [CChar](repeating: 0, count: 512)
            let errorLength = error.count
            let start = ProcessInfo.processInfo.systemUptime
            continuation.yield(.backend(metal ? "Metal" : "CPU"))
            if runtime == nil {
                runtime = nl_open(settings.model.url.path, Int32(settings.context), metal, stop.handle, &error, errorLength)
                if runtime != nil {
                    runtimeKey = key
                    usesMetal = metal
                }
            }
            guard let runtime else {
                if metal { continue }
                let message = String(cString: error)
                if !message.isEmpty { throw LocalError(message: message) }
                return
            }

            var generated: Int32 = 0
            let maxTokens: Int32 = settings.thinking ? 640 : 384
            let status = messages.withUnsafeBufferPointer { messages in
                nl_generate(runtime, messages.baseAddress, messages.count,
                            projector.map { UnsafePointer($0) }, settings.thinking, maxTokens,
                            stop.handle, receiveChunk, opaque, &generated, &error, errorLength)
            }
            if status == NL_STOPPED { return }
            if status == NL_RETRY && metal && generated == 0 {
                releaseRuntime()
                continue
            }
            guard status == NL_OK else {
                let message = String(cString: error)
                throw LocalError(message: message.isEmpty ? "Local generation failed." : message)
            }
            let elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - (sink.firstToken ?? start))
            if generated > 1 { continuation.yield(.finished(count: Int(generated), seconds: elapsed)) }
            return
        }
    }
}
