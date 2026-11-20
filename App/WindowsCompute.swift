import CryptoKit
import Foundation
import Network
import Security
import SwiftUI

struct WindowsDevice: Codable, Identifiable, Equatable, Sendable {
    let name: String
    let address: String
    let fingerprint: Data
    let secret: Data

    static let pairingPrefix = "NETH36."

    var id: String { fingerprint.base64EncodedString() }

    var isValid: Bool {
        fingerprint.count == 32 && secret.count == 32 &&
        !name.isEmpty && name.utf8.count <= 128 &&
        (IPv4Address(address).map(Self.privateAddress) ?? false)
    }

    static func parse(_ input: String) throws -> Self {
        let code = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = LocalError(message: "Scan the QR code or copy the pairing code from Neth Local Windows.")
        guard code.hasPrefix(pairingPrefix), code.utf8.count < 1024 else { throw invalid }
        var encoded = String(code.dropFirst(pairingPrefix.count))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let peer = try? JSONDecoder().decode(Self.self, from: data),
              peer.isValid else { throw invalid }
        return peer
    }

    private static func privateAddress(_ ip: IPv4Address) -> Bool {
        let bytes = Array(ip.rawValue)
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
    }
}

struct WindowsCompute: Equatable, Sendable {
    let device: WindowsDevice
    let layers: Int
    static let maxContext = 32_768
    static let splits = [4, 8, 12, 16]
}

@MainActor
final class WindowsDevices: ObservableObject {
    @Published private(set) var devices: [WindowsDevice]
    @Published private(set) var selectedID: String?
    @Published private(set) var sessionOnly: Set<String> = []
    @Published var layers: Int {
        didSet { UserDefaults.standard.set(layers, forKey: "windowsLayers") }
    }

    var compute: WindowsCompute? {
        guard let device = devices.first(where: { $0.id == selectedID }) else { return nil }
        return WindowsCompute(device: device, layers: layers)
    }

    private static let keychain: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.neth.local.windows",
        kSecAttrAccount as String: "paired-devices"
    ]
    private var storedIDs: Set<String> = []

    init() {
        var query = Self.keychain
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            devices = (try? JSONDecoder().decode([WindowsDevice].self, from: data).filter(\.isValid)) ?? []
        } else {
            devices = []
        }
        let storedLayers = UserDefaults.standard.integer(forKey: "windowsLayers")
        layers = WindowsCompute.splits.contains(storedLayers) ? storedLayers : 8
        selectedID = UserDefaults.standard.string(forKey: "windowsDevice")
        storedIDs = Set(devices.map(\.id))
    }

    func choose(_ device: WindowsDevice?) {
        selectedID = device?.id
        let persisted = device.flatMap { sessionOnly.contains($0.id) ? nil : $0.id }
        UserDefaults.standard.set(persisted, forKey: "windowsDevice")
    }

    func add(_ device: WindowsDevice) {
        let updated = [device] + Array(devices.filter { $0.id != device.id }.prefix(7))
        do {
            try store(updated)
        } catch {
            sessionOnly.insert(device.id)
            sessionOnly.formIntersection(updated.map(\.id))
        }
        devices = updated
    }

    func remove(_ device: WindowsDevice) throws {
        let updated = devices.filter { $0.id != device.id }
        if storedIDs.contains(device.id) { try store(updated) }
        sessionOnly.remove(device.id)
        devices = updated
        if selectedID == device.id { choose(nil) }
    }

    private func store(_ updated: [WindowsDevice]) throws {
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
        throw LocalError(message: "This installation could not save the Windows pairing in the iPad keychain.")
    }

    private func didStore(_ devices: [WindowsDevice]) {
        storedIDs = Set(devices.map(\.id))
        sessionOnly.removeAll()
    }
}

private final class WireResult<Value>: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard self.result == nil else { return }
        self.result = result
        ready.signal()
    }

    func value() throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try result!.get()
    }
}

final class WindowsLink {
    private static let batchSize = 128
    private static let activationWidth = 2560
    private static let port: NWEndpoint.Port = 52436
    private let device: WindowsDevice
    private let stop: GenerationStop?
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.neth.local.windows-link", qos: .userInitiated)
    private(set) var failure: Error?

    init(device: WindowsDevice, stop: GenerationStop? = nil) {
        self.device = device
        self.stop = stop
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, candidate, complete in
            let trust = sec_trust_copy_ref(candidate).takeRetainedValue()
            let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
            let hash = certificate.map { Data(SHA256.hash(data: SecCertificateCopyData($0) as Data)) }
            complete(hash == device.fingerprint)
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.requiredInterfaceType = .wifi
        connection = NWConnection(host: NWEndpoint.Host(device.address), port: Self.port, using: parameters)
    }

    deinit { connection.cancel() }

    func open() throws {
        var tlsConnected = false
        do {
            let _: Void = try wait(seconds: 15) { done in
                connection.stateUpdateHandler = { [weak connection] state in
                    switch state {
                    case .ready: done(.success(()))
                    case .failed(let error): done(.failure(error))
                    case .waiting where connection?.currentPath?.unsatisfiedReason == .localNetworkDenied:
                        done(.failure(LocalError(message: "Allow Neth Local under iPad Settings → Privacy & Security → Local Network, then try again.")))
                    case .cancelled: done(.failure(CancellationError()))
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
            tlsConnected = true
            var hello = Data("NETH36/1".utf8)
            hello.append(device.secret)
            try send(hello)
            try response(seconds: 6)
        } catch {
            connection.cancel()
            if stop?.cancelled == true { throw CancellationError() }
            if tlsConnected {
                throw LocalError(message: "Pairing with \(device.name) did not finish. Scan the current QR code in the Windows app and try again.")
            }
            if let networkError = error as? NWError {
                switch networkError {
                case .tls:
                    throw LocalError(message: "The certificate for \(device.name) did not verify. Scan the current QR code in the Windows app.")
                case .posix(.ECONNREFUSED):
                    throw LocalError(message: "\(device.name) refused the connection. Click Start server in the Windows app and check its status.")
                default: break
                }
            }
            if let reason = error as? LocalError, reason.message.hasPrefix("Allow Neth Local") { throw reason }
            throw LocalError(message: "Couldn’t reach \(device.name) at \(device.address). Join its 5 GHz Mobile Hotspot, allow Local Network access, and check the Windows server status.")
        }
    }

    func prepare(layers: Int, context: Int) throws {
        var request = Data([1])
        Self.append(Int32(layers), to: &request)
        Self.append(Int32(context), to: &request)
        try send(request)
        try response(seconds: 90)
    }

    func compute(tokens: UnsafePointer<Int32>, count: Int32, position: Int32, output: UnsafeMutablePointer<Float>) -> Bool {
        guard count > 0, count <= Self.batchSize else { return false }
        do {
            var request = Data([2])
            Self.append(position, to: &request)
            Self.append(count, to: &request)
            request.append(Data(bytes: tokens, count: Int(count) * MemoryLayout<Int32>.size))
            try send(request)
            try response(seconds: 30)
            let bytes = try read(Int(count) * Self.activationWidth * MemoryLayout<Float>.size, seconds: 15)
            bytes.withUnsafeBytes { source in
                UnsafeMutableRawPointer(output).copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
            return true
        } catch {
            failure = error is LocalError ? error : LocalError(message: "The link to \(device.name) stopped responding. Reconnect to its 5 GHz hotspot to continue.")
            connection.cancel()
            return false
        }
    }

    private func response(seconds: Double) throws {
        let header = [UInt8](try read(3, seconds: seconds))
        let length = Int(header[1]) | (Int(header[2]) << 8)
        guard header[0] <= 1, length <= 384 else { throw disconnected }
        if header[0] == 0 {
            guard length == 0 else { throw disconnected }
        } else {
            let text = String(decoding: try read(length, seconds: 5), as: UTF8.self)
            throw LocalError(message: text.isEmpty ? "The Windows worker could not continue." : text)
        }
    }

    private func send(_ data: Data) throws {
        let _: Void = try wait(seconds: 10) { done in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { done(.failure(error)) } else { done(.success(())) }
            })
        }
    }

    private func read(_ count: Int, seconds: Double) throws -> Data {
        let deadline = DispatchTime.now() + seconds
        let closed = disconnected
        var result = Data(capacity: count)
        while result.count < count {
            let chunkSize = min(count - result.count, 128 * 1024)
            let chunk: Data = try wait(until: deadline) { done in
                connection.receive(minimumIncompleteLength: chunkSize, maximumLength: chunkSize) { bytes, _, _, error in
                    if let bytes, !bytes.isEmpty { done(.success(bytes)) }
                    else { done(.failure(error ?? closed)) }
                }
            }
            result.append(chunk)
        }
        return result
    }

    private var disconnected: LocalError {
        LocalError(message: "The Windows connection dropped. Check that its 5 GHz hotspot and server are still running.")
    }

    private func wait<Value>(seconds: Double, _ start: (@escaping (Result<Value, Error>) -> Void) -> Void) throws -> Value {
        try wait(until: .now() + seconds, start)
    }

    private func wait<Value>(until deadline: DispatchTime,
                             _ start: (@escaping (Result<Value, Error>) -> Void) -> Void) throws -> Value {
        let result = WireResult<Value>()
        if stop?.cancelled == true { throw CancellationError() }
        start { result.finish($0) }
        while result.ready.wait(timeout: min(deadline, .now() + .milliseconds(100))) == .timedOut {
            if stop?.cancelled == true { throw CancellationError() }
            if DispatchTime.now() >= deadline { throw disconnected }
        }
        return try result.value()
    }

    private static func append(_ value: Int32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
