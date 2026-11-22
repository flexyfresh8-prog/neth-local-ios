import CryptoKit
import Combine
import Foundation
import Security

// Neth Cloud connects the app to a user-launched llama.cpp server (Colab T4 or any GPU host).
// A pairing code printed by the Colab notebook carries the HTTPS base URL and the API key.
// Nothing about a server is hardcoded; codes are created by the notebook at session start.

struct CloudServer: Codable, Identifiable, Equatable, Sendable {
    let name: String
    let url: URL
    let token: String
    var model: String

    static let pairingPrefix = "NETHCLOUD1."

    init(name: String, url: URL, token: String, model: String = "") {
        self.name = name
        self.url = url
        self.token = token
        self.model = model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Neth Cloud"
        url = try container.decode(URL.self, forKey: .url)
        token = try container.decode(String.self, forKey: .token)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
    }

    var id: String { Self.fingerprint(url: url, token: token) }

    var isValid: Bool {
        guard !name.isEmpty, name.utf8.count <= 80 else { return false }
        guard token.count >= 8, token.utf8.count <= 256 else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        guard url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { return false }
        return url.scheme?.lowercased() == "https" || Self.isLoopback(host)
    }

    var host: String { url.host ?? url.absoluteString }

    private static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    static func fingerprint(url: URL, token: String) -> String {
        let digest = SHA256.hash(data: Data("\(url.absoluteString.lowercased())|\(token)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func parse(_ input: String) throws -> Self {
        let code = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = LocalError(message: "Paste the connect code printed by the Neth Cloud notebook. It starts with \(pairingPrefix).")
        guard code.hasPrefix(pairingPrefix), code.utf8.count < 4096 else { throw invalid }
        var encoded = String(code.dropFirst(pairingPrefix.count))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let server = try? JSONDecoder().decode(Self.self, from: data),
              server.isValid else { throw invalid }
        return server
    }

    var pairingCode: String {
        let payload = (try? JSONEncoder().encode(self)) ?? Data()
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return Self.pairingPrefix + encoded
    }
}

struct CloudCompute: Equatable, Sendable {
    let server: CloudServer
    let context: Int
    static let maxContext = 32_768
    static let defaultContext = 2_048
    static let contexts = [2_048, 4_096, 8_192, 16_384, 32_768]
}

enum CloudStatus: Equatable, Sendable {
    case idle, checking, ready, failed(String)

    var detail: String {
        switch self {
        case .idle: "Not connected"
        case .checking: "Checking server…"
        case .ready: "Connected"
        case .failed(let reason): reason
        }
    }

    var connected: Bool {
        if case .ready = self { return true }
        return false
    }
}

enum CloudEndpoint {
    static let health = "v1/models"
    static let chat = "v1/chat/completions"
    static let props = "props"
}

struct CloudTurn: Sendable {
    let role: ChatMessage.Role
    let text: String
}

struct CloudRequest: Sendable {
    var system = ""
    var turns: [CloudTurn] = []
    var prefix = ""
    var grammar: String? = nil
    var limit = 1024
    var reasoningEffort = "low"
}

// Parsed piece of one OpenAI-compatible streaming chunk. The server applies the model's
// Harmony template (llama.cpp --jinja), so analysis-channel text arrives as
// reasoning_content and final-channel text as content. Native tool_call deltas are parsed
// so they can be reported, never executed: tool execution runs only through the
// grammar-constrained Quattro catalog on this device.

struct HarmonyDelta: Equatable, Sendable {
    var reasoning: String?
    var content: String?
    var toolIndex: Int?
    var toolName: String?
    var toolArguments: String?
    var finish: String?
    var completionTokens: Int?
    var detail: String?
}

enum HarmonyAdapter {
    static func parseChunk(_ payload: String) -> HarmonyDelta? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            return nil
        }
        var delta = HarmonyDelta()
        if let error = object["error"] as? [String: Any] {
            delta.detail = (error["message"] as? String) ?? "The server reported an error."
            return delta
        }
        if let usage = object["usage"] as? [String: Any] {
            delta.completionTokens = usage["completion_tokens"] as? Int
        }
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return delta }
        delta.finish = choice["finish_reason"] as? String
        guard let piece = choice["delta"] as? [String: Any] else { return delta }
        delta.reasoning = piece["reasoning_content"] as? String
        delta.content = piece["content"] as? String
        if let calls = piece["tool_calls"] as? [[String: Any]], let call = calls.first {
            delta.toolIndex = call["index"] as? Int
            if let function = call["function"] as? [String: Any] {
                delta.toolName = function["name"] as? String
                delta.toolArguments = function["arguments"] as? String
            }
        }
        return delta
    }
}

final class CloudMetrics: @unchecked Sendable {
    static let shared = CloudMetrics()

    struct Snapshot: Equatable, Sendable {
        var tokensPerSecond: Double?
        var firstToken: Double?
        var latency: Double?
        var tokens: Int?
    }

    private let lock = NSLock()
    private var snapshotValue = Snapshot()

    private init() {}

    func record(tokensPerSecond: Double? = nil, firstToken: Double? = nil,
                latency: Double? = nil, tokens: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let tokensPerSecond { snapshotValue.tokensPerSecond = tokensPerSecond }
        if let firstToken { snapshotValue.firstToken = firstToken }
        if let latency { snapshotValue.latency = latency }
        if let tokens { snapshotValue.tokens = tokens }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        snapshotValue = Snapshot()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotValue
    }
}

@MainActor
final class NethCloud: ObservableObject {
    @Published private(set) var servers: [CloudServer] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var status: CloudStatus = .idle
    @Published private(set) var remoteModels: [String] = []
    @Published private(set) var sessionOnly: Set<String> = []
    @Published var context: Int {
        didSet { UserDefaults.standard.set(context, forKey: "cloudContext") }
    }

    private static let keychain: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.neth.local.cloud",
        kSecAttrAccount as String: "cloud-servers"
    ]
    private var storedIDs: Set<String> = []

    init() {
        var query = Self.keychain
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            servers = (try? JSONDecoder().decode([CloudServer].self, from: data).filter(\.isValid)) ?? []
        }
        let stored = UserDefaults.standard.integer(forKey: "cloudContext")
        context = CloudCompute.contexts.contains(stored) ? stored : CloudCompute.defaultContext
        selectedID = UserDefaults.standard.string(forKey: "cloudServer")
        storedIDs = Set(servers.map(\.id))
    }

    var compute: CloudCompute? {
        guard status.connected, let server = servers.first(where: { $0.id == selectedID }) else { return nil }
        return CloudCompute(server: server, context: min(context, CloudCompute.maxContext))
    }

    func choose(_ server: CloudServer?) {
        selectedID = server?.id
        UserDefaults.standard.set(server?.id, forKey: "cloudServer")
        if server == nil {
            status = .idle
            remoteModels = []
        }
    }

    func connect(_ candidate: CloudServer) async {
        status = .checking
        let session = CloudSession(server: candidate)
        do {
            let report = try await session.health()
            var server = candidate
            if server.model.isEmpty { server.model = report.models.first ?? "" }
            remoteModels = report.models
            CloudMetrics.shared.record(latency: report.latency)
            add(server)
            selectedID = server.id
            UserDefaults.standard.set(server.id, forKey: "cloudServer")
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        choose(nil)
    }

    func add(_ server: CloudServer) {
        let updated = [server] + Array(servers.filter { $0.id != server.id }.prefix(7))
        do {
            try store(updated)
        } catch {
            sessionOnly.insert(server.id)
            sessionOnly.formIntersection(updated.map(\.id))
        }
        servers = updated
    }

    func remove(_ server: CloudServer) throws {
        let updated = servers.filter { $0.id != server.id }
        if storedIDs.contains(server.id) { try store(updated) }
        sessionOnly.remove(server.id)
        servers = updated
        if selectedID == server.id { choose(nil) }
    }

    private func store(_ updated: [CloudServer]) throws {
        let data = try JSONEncoder().encode(updated)
        let status = SecItemUpdate(Self.keychain as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess {
            didStore(updated)
            return
        }
        if status == errSecItemNotFound {
            var item = Self.keychain
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            if SecItemAdd(item as CFDictionary, nil) == errSecSuccess {
                didStore(updated)
                return
            }
        }
        throw LocalError(message: "This installation could not save the cloud server in the iPad keychain.")
    }

    private func didStore(_ servers: [CloudServer]) {
        storedIDs = Set(servers.map(\.id))
        sessionOnly.removeAll()
    }
}

final class CloudSession: @unchecked Sendable {
    let server: CloudServer
    private let session: URLSession

    init(server: CloudServer) {
        self.server = server
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 75
        configuration.timeoutIntervalForResource = 900
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    private func request(_ path: String, body: Data? = nil, timeout: Double = 60) -> URLRequest {
        var request = URLRequest(url: server.url.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private static var retryableCodes: Set<URLError.Code> {
        [.networkConnectionLost, .timedOut, .cannotConnectToHost, .dnsLookupFailed]
    }

    private static func networkMessage(_ error: Error) -> LocalError {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return LocalError(message: "The cloud server took too long to answer. The model may still be loading; try again shortly.")
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
                return LocalError(message: "Couldn’t reach the cloud server. The tunnel may have closed — run the connect cell in Colab again and paste the new code.")
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return LocalError(message: "The iPad lost its network connection to the cloud server.")
            case .cancelled:
                return LocalError(message: "The request was cancelled.")
            case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return LocalError(message: "The cloud server certificate did not verify.")
            default: break
            }
        }
        return LocalError(message: error.localizedDescription)
    }

    private static func statusMessage(_ status: Int, body: String) -> LocalError {
        switch status {
        case 401, 403:
            return LocalError(message: "The server rejected the API key. Paste a fresh connect code from the notebook.")
        case 404:
            return LocalError(message: "The server answered 404. Paste the tunnel URL exactly as the notebook printed it, without an added path.")
        case 503:
            return LocalError(message: "The model is still loading on the GPU. Try connecting again in a few seconds.")
        default:
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return LocalError(message: "The cloud server returned HTTP \(status). \(String(detail.prefix(180)))")
        }
    }

    func fetch(_ path: String, body: Data? = nil, attempts: Int = 2, timeout: Double = 60) async throws -> Data {
        var lastError: Error?
        for attempt in 0..<max(1, attempts) {
            do {
                let (data, response) = try await session.data(for: request(path, body: body, timeout: timeout))
                guard let http = response as? HTTPURLResponse else {
                    throw LocalError(message: "The cloud server response was not HTTP.")
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw Self.statusMessage(http.statusCode, body: String(decoding: data, as: UTF8.self))
                }
                return data
            } catch {
                let retryable = (error as? LocalError) == nil
                    && (error as? URLError).map { Self.retryableCodes.contains($0.code) } == true
                lastError = error
                if !retryable || attempt + 1 >= attempts { throw error }
                try? await Task.sleep(for: .seconds(1.2))
                if Task.isCancelled { throw CancellationError() }
            }
        }
        throw lastError ?? LocalError(message: "The cloud server request failed.")
    }

    struct HealthReport: Sendable {
        let models: [String]
        let context: Int?
        let latency: Double
    }

    func health() async throws -> HealthReport {
        let started = Date()
        let data = try await fetch(CloudEndpoint.health, attempts: 2, timeout: 30)
        let latency = Date().timeIntervalSince(started)
        var models: [String] = []
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entries = object["data"] as? [[String: Any]] {
            models = entries.compactMap { $0["id"] as? String }
        }
        var context: Int?
        if let props = try? await fetch(CloudEndpoint.props, attempts: 1, timeout: 20),
           let object = try? JSONSerialization.jsonObject(with: props) as? [String: Any],
           let generation = object["default_generation_settings"] as? [String: Any] {
            context = generation["n_ctx"] as? Int
        }
        return HealthReport(models: models, context: context, latency: latency)
    }

    // The request body for an OpenAI-compatible chat completion. llama.cpp accepts the
    // grammar and chat_template_kwargs extensions; other servers ignore them, and the
    // Quattro catalog still validates every tool call before it runs on this device.
    static func makeBody(_ request: CloudRequest, model: String?) -> Data {
        var messages: [[String: String]] = []
        if !request.system.isEmpty {
            messages.append(["role": "system", "content": request.system])
        }
        for turn in request.turns {
            let text = turn.role == .assistant ? ReplyContinuation.visible(turn.text) : turn.text
            messages.append(["role": turn.role.rawValue, "content": text])
        }
        if !request.prefix.isEmpty {
            messages.append(["role": "assistant", "content": request.prefix])
        }
        var body: [String: Any] = [
            "messages": messages,
            "stream": true,
            "max_tokens": max(1, request.limit),
            "temperature": 1.0,
            "top_p": 1.0,
            "cache_prompt": true,
            "stream_options": ["include_usage": true],
            "chat_template_kwargs": ["reasoning_effort": request.reasoningEffort]
        ]
        if let model, !model.isEmpty { body["model"] = model }
        if let grammar = request.grammar, !grammar.isEmpty { body["grammar"] = grammar }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }
}
