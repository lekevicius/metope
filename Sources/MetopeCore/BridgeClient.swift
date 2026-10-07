import Foundation
import Darwin

@MainActor public protocol MTPTransport: AnyObject {
    func request(_ operation: String, arguments: [String: JSONValue], onEvent: ((BridgeEvent) -> Void)?) async throws -> JSONValue
    func stop()
}
@MainActor public final class BridgeClient: MTPTransport {
    private let executable: URL
    private let arguments: [String]
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var pending: Pending?
    private var watchdog: Task<Void, Never>?
    private var generation = UUID()
    private struct Pending {
        var id: UUID
        var continuation: CheckedContinuation<JSONValue, Error>
        var onEvent: ((BridgeEvent) -> Void)?
        var deadline: TimeInterval
        var lastActivity = Date()
        var progressMarker: String?
    }
    public init(executable: URL, arguments: [String] = []) { self.executable = executable; self.arguments = arguments }
    private func start() throws {
        guard process == nil else { return }
        signal(SIGPIPE, SIG_IGN)
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = stdin; process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let token = UUID(); generation = token
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if !data.isEmpty { self.consume(data) }
            }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.stop(with: MTPError(code: "Disconnected", detail: "The USB helper exited (\(process.terminationStatus))."))
            }
        }
        do { try process.run() } catch { stdout.fileHandleForReading.readabilityHandler = nil; throw error }
        self.process = process; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
    }
    public func request(_ operation: String, arguments: [String: JSONValue] = [:], onEvent: ((BridgeEvent) -> Void)? = nil) async throws -> JSONValue {
        guard pending == nil else { throw MTPError(detail: "Another device operation is still running.") }
        try Task.checkCancellation(); try start()
        let request = BridgeRequest(operation: operation, arguments: arguments)
        var data = try JSONEncoder().encode(request); data.append(10)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = Pending(id: request.id, continuation: continuation, onEvent: onEvent, deadline: operation.contains("Files") || operation == "Walk" ? 300 : 30)
                do { try input?.write(contentsOf: data) } catch { stop(with: error); return }
                watchdog = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled, let self, let pending = self.pending else { return }
                        if Date().timeIntervalSince(pending.lastActivity) > pending.deadline {
                            self.stop(with: MTPError(code: "Timeout", detail: "The operation timed out.")); return
                        }
                    }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.stop() } }
    }
    private func consume(_ data: Data) {
        buffer.append(data)
        guard buffer.count < 64 * 1024 * 1024 else { stop(with: MTPError(detail: "The device response exceeded the 64 MB safety limit.")); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            do {
                let event = try JSONDecoder().decode(BridgeEvent.self, from: line)
                guard var current = pending, current.id == event.id else { continue }
                var marker: String?
                if event.phase == "progress", let payload = event.result.data,
                   let progress = try? payload.decode(TransferProgress.self) {
                    marker = "\(progress.fullPath)|\(progress.bulkFileSize.sent)|\(progress.filesSent)"
                } else if event.phase == "preprocess", case .object(let payload) = event.result.data {
                    marker = try? payload["fullPath"]?.decode(String.self)
                }
                // Progress can repeat while USB is stuck; elapsed time alone
                // is not evidence of forward progress and must not reset the watchdog.
                if let marker, marker != current.progressMarker {
                    current.lastActivity = Date(); current.progressMarker = marker
                }
                pending = current
                if event.phase == "done" {
                    pending = nil; watchdog?.cancel(); watchdog = nil
                    do { current.continuation.resume(returning: try event.result.checked()) }
                    catch { current.continuation.resume(throwing: error) }
                } else {
                    // Progress errors terminate the operation rather than masquerading as success.
                    _ = try event.result.checked()
                    current.onEvent?(event)
                }
            } catch { stop(with: error); return }
        }
    }
    public func stop() { stop(with: MTPError(code: "Cancelled", detail: "Stopped by user.")) }
    private func stop(with error: Error) {
        generation = UUID(); watchdog?.cancel(); watchdog = nil
        output?.readabilityHandler = nil
        try? input?.close(); try? output?.close(); input = nil; output = nil
        let old = process; process = nil; buffer.removeAll()
        if let old, old.isRunning {
            old.terminate()
            Task.detached {
                try? await Task.sleep(for: .seconds(1))
                if old.isRunning { kill(old.processIdentifier, SIGKILL) }
            }
        }
        let current = pending; pending = nil; current?.continuation.resume(throwing: error)
    }
}

@MainActor public final class MTPService {
    public let transport: MTPTransport
    public init(transport: MTPTransport) { self.transport = transport }
    public func connect() async throws -> (DeviceInfo, [DeviceStorage]) {
        let device = try await transport.request("Initialize", arguments: [:], onEvent: nil).decode(DeviceInfo.self)
        let storage = try await storages()
        return (device, storage)
    }
    public func storages() async throws -> [DeviceStorage] {
        let value = try await transport.request("FetchStorages", arguments: [:], onEvent: nil)
        return value == .null ? [] : try value.decode([DeviceStorage].self)
    }
    public func verifyIdentity(_ expected: String) async throws {
        let info = try await transport.request("FetchDeviceInfo", arguments: [:], onEvent: nil).decode(DeviceInfo.self)
        guard info.identity == expected else { throw MTPError(code: "ErrorDeviceChanged", detail: "Device identity changed.") }
    }
    public func list(storage: UInt32, path: String, recursive: Bool = false, transferFilter: Bool = false) async throws -> [RemoteFile] {
        try TransferSafety.validateRemotePath(path)
        let value = try await transport.request("Walk", arguments: ["storageId": .integer(Int64(storage)), "fullPath": .string(path), "recursive": .bool(recursive), "skipHiddenFiles": .bool(false), "skipDisallowedFiles": .bool(transferFilter)], onEvent: nil)
        let files = value == .null ? [] : try value.decode([RemoteFile].self)
        for file in files { try TransferSafety.validateRemotePath(file.path); try TransferSafety.validateName(file.name) }
        return files
    }
    public func mutate(_ operation: String, storage: UInt32, fields: [String: JSONValue]) async throws {
        var args = fields; args["storageId"] = .integer(Int64(storage))
        _ = try await transport.request(operation, arguments: args, onEvent: nil)
    }
    public func transfer(upload: Bool, storage: UInt32, sources: [String], destination: String, onEvent: @escaping (BridgeEvent) -> Void) async throws {
        _ = try await transport.request(upload ? "UploadFiles" : "DownloadFiles", arguments: ["storageId": .integer(Int64(storage)), "sources": .strings(sources), "destination": .string(destination), "preprocessFiles": .bool(true)], onEvent: onEvent)
    }
    public func disconnect() async { _ = try? await transport.request("Dispose", arguments: [:], onEvent: nil); transport.stop() }
}
