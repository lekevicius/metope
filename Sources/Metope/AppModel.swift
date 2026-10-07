import AppKit
import Observation
import MetopeCore

struct TransferJob: Identifiable {
    enum State: String { case queued = "Waiting", preparing = "Preparing", transferring = "Transferring", verifying = "Verifying", completed = "Completed", failed = "Failed", cancelled = "Stopped" }
    let id = UUID()
    let upload: Bool
    let storage: UInt32
    let identity: String
    let localURLs: [URL]
    let remoteFiles: [RemoteFile]
    let destination: String
    var state: State = .queued
    var progress: TransferProgress?
    var message: String?
    var recoveryURL: URL?
    var resultURLs: [URL] = []
    var title: String {
        let names = upload ? localURLs.map(\.lastPathComponent) : remoteFiles.map(\.name)
        return names.count == 1 ? names[0] : "\(names.count) items"
    }
}
struct AppNotice: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

@MainActor @Observable final class AppModel {
    var service: MTPService
    var isDemo: Bool
    // Used only when capturing website assets with the read-only sample transport.
    var isScreenshot: Bool { isDemo && CommandLine.arguments.contains("--screenshot") }
    var device: DeviceInfo?
    var storages: [DeviceStorage] = []
    var storageID: UInt32?
    var path = "/"
    var files: [RemoteFile] = []
    var rootFolders = Set<String>()
    var selection = Set<String>()
    var search = ""
    var busy = false
    var connecting = false
    var connectionIssue: MTPError?
    var notice: AppNotice?
    var showInspector = false
    var showTransfers = false
    var iconView = false
    var showHidden = UserDefaults.standard.bool(forKey: "showHidden")
    var jobs: [TransferJob] = []
    var activeJobID: UUID?
    var history: [String] = ["/"]
    var historyIndex = 0
    var monitor: USBMonitor?
    var hotplugTask: Task<Void, Never>?
    var operationTask: Task<Void, Never>?
    var previewAfterDownload = false
    var quickLook = QuickLookController()
    var storage: DeviceStorage? { storages.first { $0.id == storageID } }
    var connected: Bool { device != nil && storageID != nil }
    var canMutate: Bool { connected && !busy && !isDemo && storage?.writable == true }
    var selectedFiles: [RemoteFile] { files.filter { selection.contains($0.id) } }
    var activeJob: TransferJob? { jobs.first { $0.id == activeJobID } }
    var visibleFiles: [RemoteFile] {
        files.filter { (showHidden || !$0.name.hasPrefix(".")) && (search.isEmpty || $0.name.localizedStandardContains(search)) }
    }
    init(demo: Bool = CommandLine.arguments.contains("--demo")) {
        isDemo = demo
        if demo { service = MTPService(transport: DemoTransport()) }
        else { service = Self.liveService() }
    }
    private static func liveService() -> MTPService {
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        return MTPService(transport: BridgeClient(executable: contents.appendingPathComponent("Helpers/MetopeEngineHost")))
    }

    func toggleDemo() {
        guard !busy else { return }
        service.transport.stop(); clearConnection(); isDemo.toggle()
        service = isDemo ? MTPService(transport: DemoTransport()) : Self.liveService()
        Task { await connect() }
    }
    func start() {
        if monitor == nil {
            monitor = USBMonitor()
            monitor?.onChange = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.hotplugTask?.cancel()
                    self?.hotplugTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled, let self, !self.busy, !self.isDemo else { return }
                        if self.connected { await self.refresh() } else { await self.connect() }
                    }
                }
            }
        }
        operationTask = Task { await connect() }
    }
    func connect() async {
        guard !busy else { return }
        busy = true; connecting = true; connectionIssue = nil
        service.transport.stop()
        defer { busy = false; connecting = false }
        do {
            if !isDemo {
                let competing = NSWorkspace.shared.runningApplications.compactMap(\.localizedName).filter { ["Android File Transfer"].contains($0) }
                if !competing.isEmpty { throw MTPError(code: "OtherMTPClient", detail: competing.joined(separator: ", ")) }
            }
            let (info, stores) = try await service.connect()
            guard let first = stores.first else { throw MTPError(code: "ErrorNoStorage", detail: "No storage available.") }
            let initial = try await service.list(storage: first.id, path: "/")
            device = info; storages = stores; storageID = first.id; files = initial
            rootFolders = Set(initial.filter(\.isFolder).map(\.path))
            path = "/"; history = ["/"]; historyIndex = 0; selection = []
        } catch {
            service.transport.stop(); clearConnection()
            connectionIssue = error as? MTPError ?? MTPError(detail: error.localizedDescription)
        }
    }
    func clearConnection() { device = nil; storages = []; storageID = nil; files = []; selection = [] }
    func disconnect() {
        guard !busy else { return }
        busy = true
        Task { await service.disconnect(); clearConnection(); connectionIssue = nil; busy = false }
    }
    func refresh() async {
        guard !busy, let storageID else { return }
        busy = true; defer { busy = false }
        do {
            if let device { try await service.verifyIdentity(device.identity) }
            let stores = try await service.storages()
            guard stores.contains(where: { $0.id == storageID }) else { throw MTPError(code: "ErrorNoStorage", detail: "Storage removed.") }
            files = try await service.list(storage: storageID, path: path); storages = stores
            selection.formIntersection(Set(files.map(\.id)))
            if path == "/" { rootFolders = Set(files.filter(\.isFolder).map(\.path)) }
        } catch { handle(error) }
    }
    func navigate(_ destination: String, storage newStorage: UInt32? = nil, record: Bool = true, historyTarget: Int? = nil) {
        guard !busy, let sid = newStorage ?? storageID else { return }
        busy = true
        operationTask = Task {
            defer { busy = false }
            do {
                let entries = try await service.list(storage: sid, path: destination)
                if sid != storageID { history = [destination]; historyIndex = 0 }
                else if record {
                    history = Array(history.prefix(historyIndex + 1)); history.append(destination); historyIndex += 1
                } else if let historyTarget { historyIndex = historyTarget }
                if destination == "/" { rootFolders = Set(entries.filter(\.isFolder).map(\.path)) }
                storageID = sid; path = destination; files = entries; selection = []; search = ""
            } catch { handle(error) }
        }
    }
    func back() { if historyIndex > 0 { navigate(history[historyIndex - 1], record: false, historyTarget: historyIndex - 1) } }
    func forward() { if historyIndex + 1 < history.count { navigate(history[historyIndex + 1], record: false, historyTarget: historyIndex + 1) } }
    func up() { if path != "/" { navigate((path as NSString).deletingLastPathComponent) } }
    func openSelection() { if selectedFiles.count == 1, let file = selectedFiles.first { if file.isFolder { navigate(file.path) } else { preview(file) } } }
    func handle(_ error: Error) {
        let mtp = error as? MTPError
        let message = [mtp?.recoverySuggestion, mtp?.detail == mtp?.errorDescription ? nil : mtp?.detail].compactMap { $0 }.joined(separator: "\n\n")
        notice = AppNotice(title: error.localizedDescription, message: message)
        if let mtp, ["ErrorDeviceChanged", "Disconnected", "Timeout", "ErrorDeviceLocked", "ErrorAllowStorageAccess", "ErrorMtpDetectFailed", "ErrorNoStorage", "ErrorDeviceSetup", "Protocol", "Cancelled"].contains(mtp.code) {
            service.transport.stop(); clearConnection(); connectionIssue = mtp
        }
    }
    func createFolder(_ name: String) { mutation { sid in
        let destination = try TransferSafety.child(name, of: self.path)
        let current = try await self.service.list(storage: sid, path: self.path)
        try TransferSafety.rejectCollisions([name], existing: current.map(\.name))
        try await self.service.mutate("MakeDirectory", storage: sid, fields: ["fullPath": .string(destination)])
    } }
    func rename(_ file: RemoteFile, to name: String) { mutation { sid in
        try TransferSafety.validateName(name)
        if name == file.name { return }
        let current = try await self.service.list(storage: sid, path: self.path)
        try TransferSafety.rejectCollisions([name], existing: current.map(\.name))
        try await self.service.mutate("RenameFile", storage: sid, fields: ["fullPath": .string(file.path), "newFileName": .string(name)])
    } }
    func deleteSelection() {
        let targets = selectedFiles
        guard canMutate, !targets.isEmpty else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = targets.count == 1 ? "Delete “\(targets[0].name)”?" : "Delete \(targets.count) items?"
        alert.informativeText = "These items will be permanently deleted from your phone. They won’t go to the Mac’s Trash."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        mutation { sid in try await self.service.mutate("DeleteFile", storage: sid, fields: ["files": .strings(targets.map(\.path))]) }
    }
    private func mutation(_ action: @escaping (UInt32) async throws -> Void) {
        guard canMutate, let sid = storageID else { return }
        busy = true
        operationTask = Task {
            defer { busy = false }
            do { if let device { try await service.verifyIdentity(device.identity) }; try await action(sid); files = try await service.list(storage: sid, path: path); selection = [] }
            catch { handle(error) }
        }
    }
    func importPanel() {
        guard connected, !isDemo else { return }
        let panel = NSOpenPanel(); panel.title = "Send to \(device?.name ?? "Phone")"; panel.prompt = "Send"
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.begin { [weak self] result in if result == .OK { Task { @MainActor in self?.enqueueUpload(panel.urls) } } }
    }
    func downloadPanel() {
        guard connected, !selectedFiles.isEmpty, !isDemo else { return }
        let selected = selectedFiles
        let panel = NSOpenPanel(); panel.title = "Save to your Mac"; panel.prompt = "Save Here"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.begin { [weak self] result in
            if result == .OK, let destination = panel.url { Task { @MainActor in self?.enqueueDownload(selected, to: destination) } }
        }
    }
    func enqueueUpload(_ urls: [URL]) {
        guard let device, let storage, !isDemo, storage.writable, !urls.isEmpty, !busy || activeJobID != nil else { return }
        jobs.insert(TransferJob(upload: true, storage: storage.id, identity: device.identity, localURLs: urls, remoteFiles: [], destination: path), at: 0)
        pumpQueue()
    }
    func enqueueDownload(_ files: [RemoteFile], to destination: URL) {
        guard let device, let sid = storageID, !isDemo, !files.isEmpty, !busy || activeJobID != nil else { return }
        jobs.insert(TransferJob(upload: false, storage: sid, identity: device.identity, localURLs: [], remoteFiles: files, destination: destination.path), at: 0)
        pumpQueue()
    }
    func updateJob(_ id: UUID, _ edit: (inout TransferJob) -> Void) { if let index = jobs.firstIndex(where: { $0.id == id }) { edit(&jobs[index]) } }
    func pumpQueue() {
        guard !busy, let job = jobs.last(where: { $0.state == .queued }) else { return }
        busy = true; activeJobID = job.id
        operationTask = Task {
            await execute(job)
            activeJobID = nil; busy = false
            if connected { await refresh() }
            pumpQueue()
        }
    }
    func execute(_ job: TransferJob) async {
        var staging: DownloadStaging?
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Transferring files over USB")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        do {
            guard device?.identity == job.identity else { throw MTPError(code: "ErrorDeviceChanged", detail: "This job belongs to a different connection.") }
            updateJob(job.id) { $0.state = .preparing }
            try await service.verifyIdentity(job.identity)
            let manifest: [ManifestEntry]
            if job.upload {
                manifest = try await Task.detached { try TransferSafety.localManifest(job.localURLs) }.value
                let existing = try await service.list(storage: job.storage, path: job.destination)
                try TransferSafety.rejectCollisions(job.localURLs.map(\.lastPathComponent), existing: existing.map(\.name))
                let stores = try await service.storages()
                let bytes = try TransferSafety.totalBytes(manifest)
                guard let target = stores.first(where: { $0.id == job.storage }), UInt64(bytes) <= target.Info.FreeSpaceInBytes else { throw MTPError(code: "ErrorStorageFull", detail: "The phone doesn’t have room for these files.") }
            } else {
                var descendants: [RemoteFile] = []
                for root in job.remoteFiles where root.isFolder {
                    descendants += try await service.list(storage: job.storage, path: root.path, recursive: true, transferFilter: true)
                }
                manifest = try TransferSafety.remoteManifest(roots: job.remoteFiles, descendants: descendants)
                let destination = URL(fileURLWithPath: job.destination, isDirectory: true)
                try TransferSafety.rejectCollisions(job.remoteFiles.map(\.name), existing: FileManager.default.contentsOfDirectory(atPath: destination.path))
                let free = try destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
                if let free, try TransferSafety.totalBytes(manifest) > free { throw MTPError(code: "ErrorStorageFull", detail: "Your Mac doesn’t have room for these files.") }
                staging = try DownloadStaging(destination: destination, manifest: manifest)
                updateJob(job.id) { $0.recoveryURL = staging?.directory }
                // Create empty folders in staging before the transfer starts.
                // Recreate the manifest directories so empty folders survive a copy.
                if let staging {
                    for entry in manifest where entry.isFolder {
                        try FileManager.default.createDirectory(at: staging.directory.appendingPathComponent(entry.relativePath), withIntermediateDirectories: true)
                    }
                }
            }
            try Task.checkCancellation()
            updateJob(job.id) { $0.state = .transferring }
            try await service.transfer(upload: job.upload, storage: job.storage, sources: job.upload ? job.localURLs.map(\.path) : job.remoteFiles.map(\.path), destination: staging?.directory.path ?? job.destination) { [weak self] event in
                if event.phase == "progress", let value = event.result.data, let progress = try? value.decode(TransferProgress.self) {
                    self?.updateJob(job.id) { $0.progress = progress }
                }
            }
            updateJob(job.id) { $0.state = .verifying }
            if let staging {
                try Task.checkCancellation()
                let publishTask = Task.detached { try staging.publish() }
                let urls = try await withTaskCancellationHandler { try await publishTask.value } onCancel: { publishTask.cancel() }
                updateJob(job.id) { $0.resultURLs = urls; $0.recoveryURL = nil }
                if previewAfterDownload, let url = urls.first { quickLook.show(url) }
            } else {
                // Verify every uploaded file's metadata after the final transport response.
                var remote: [RemoteFile] = []
                let top = try await service.list(storage: job.storage, path: job.destination)
                for entry in manifest where !entry.relativePath.contains("/") {
                    guard let root = top.first(where: { $0.name == entry.relativePath }) else { throw MTPError(detail: "The uploaded item “\(entry.relativePath)” is missing.") }
                    remote.append(root)
                    if root.isFolder { remote += try await service.list(storage: job.storage, path: root.path, recursive: true) }
                }
                let lookup = Dictionary(remote.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
                for entry in manifest {
                    let key = job.destination == "/" ? "/" + entry.relativePath : job.destination + "/" + entry.relativePath
                    guard let file = lookup[key], file.isFolder == entry.isFolder, entry.isFolder || file.size == entry.size else {
                        throw MTPError(detail: "Couldn’t verify “\(entry.relativePath)” on the phone. A partial copy may remain.")
                    }
                }
            }
            updateJob(job.id) { $0.state = .completed; $0.message = job.upload ? "Saved to your phone · sizes verified" : "Saved to your Mac · sizes verified" }
        } catch {
            let cancelled = (error as? MTPError)?.code == "Cancelled" || error is CancellationError
            updateJob(job.id) { $0.state = cancelled ? .cancelled : .failed; $0.message = error.localizedDescription + (job.upload ? " A partial copy may remain on your phone." : "") }
            handle(error)
            for index in jobs.indices where jobs[index].state == .queued { jobs[index].state = .cancelled; jobs[index].message = "Stopped after an earlier transfer failed. Select the files again to retry." }
        }
        previewAfterDownload = false
    }
    func cancelTransfer() {
        operationTask?.cancel(); service.transport.stop()
        clearConnection(); connectionIssue = MTPError(code: "Cancelled", detail: "Transfer stopped.")
        for index in jobs.indices where jobs[index].state == .queued { jobs[index].state = .cancelled }
    }
    func preview(_ file: RemoteFile) {
        guard !busy, !isDemo, !file.isFolder else { return }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Metope-Preview-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            previewAfterDownload = true; enqueueDownload([file], to: directory)
        } catch { handle(error) }
    }
    func prepareToQuit() -> Bool {
        if activeJobID != nil {
            let alert = NSAlert(); alert.messageText = "Stop the transfer and quit?"
            alert.informativeText = "An interrupted upload may leave a partial file on your phone. Incomplete downloads remain in their temporary folder."
            alert.addButton(withTitle: "Keep Transferring"); alert.addButton(withTitle: "Stop and Quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        service.transport.stop(); return true
    }
}
