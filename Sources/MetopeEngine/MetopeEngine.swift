import Foundation
import MetopeCore

/// Native Swift MTP engine. Call serially from a dedicated worker or the bundled engine host.
public final class MetopeEngine {
    public typealias Event = (String, JSONValue) -> Void
    private let makeTransport: () throws -> BulkTransport
    private var session: MTPSession?
    private var device: DeviceDataset?
    private var event: Event = { _, _ in }
    private let root = UInt32.max
    private let excludedNames: Set<String> = [".DS_Store", "[-----DS_Store.mtp.test----].txt"]
    public init(transport: @escaping () throws -> BulkTransport = { try USBTransport.discover() }) { makeTransport = transport }
    deinit { session?.close() }
    public func close() { session?.close(); session = nil; device = nil }
    private var connection: MTPSession {
        get throws {
            guard let session, session.valid else { throw MTPError(code: "Disconnected", detail: "Connect your phone first.") }
            return session
        }
    }
    public func connect() throws -> DeviceInfo {
        close()
        let candidate = MTPSession(transport: try makeTransport())
        do {
            let info = try DeviceDataset(candidate.get(.deviceInfo))
            guard info.operations.contains(Operation.storageIDs.rawValue), info.operations.contains(Operation.objectHandles.rawValue) else {
                throw MTPError(detail: "This USB device does not expose MTP file storage.")
            }
            try candidate.open(); session = candidate; device = info
            return info.info
        } catch { candidate.close(); throw error }
    }
    private func verifyIdentity() throws -> DeviceInfo {
        let info = try DeviceDataset(connection.get(.deviceInfo)).info
        guard info.identity == device?.info.identity else { close(); throw MTPError(code: "ErrorDeviceChanged", detail: "The connected device changed.") }
        return info
    }
    public func storages() throws -> [DeviceStorage] {
        var reader = try MTPReader(data: connection.get(.storageIDs))
        let ids = try reader.array(UInt32.self); try reader.finished()
        guard !ids.isEmpty else { throw MTPError(code: "ErrorNoStorage", detail: "Unlock your phone and allow file access.") }
        return try ids.map { try decodeStorage(connection.get(.storageInfo, [$0]), id: $0) }
    }
    private func writable(_ storage: UInt32, bytes: Int64 = 0) throws {
        let info = try decodeStorage(connection.get(.storageInfo, [storage]), id: storage)
        guard info.writable else { throw MTPError(detail: "This storage is read-only.") }
        guard bytes >= 0, UInt64(bytes) <= info.Info.FreeSpaceInBytes else { throw MTPError(code: "ErrorStorageFull", detail: "There isn’t enough space for this transfer.") }
    }
    private func metadata(_ handle: UInt32, storage: UInt32, parent: UInt32, path: String) throws -> RemoteFile {
        let object = try ObjectDataset(connection.get(.objectInfo, [handle]))
        guard object.storage == storage, object.parent == parent || (parent == root && object.parent == 0) else {
            throw malformed("The device returned an object outside the requested folder.")
        }
        var size = UInt64(object.size)
        if !object.folder && object.size == UInt32.max {
            var reader = try MTPReader(data: connection.get(.getObjectProperty, [handle, 0xDC04]))
            size = try reader.integer(UInt64.self); try reader.finished()
        }
        guard size <= UInt64(Int64.max) else { throw malformed("The file size is outside the supported range.") }
        return RemoteFile(name: object.name, path: try TransferSafety.child(object.name, of: path), size: object.folder ? 0 : Int64(size), isFolder: object.folder, objectId: handle, dateAdded: object.isoDate)
    }
    private func children(storage: UInt32, handle: UInt32, path: String) throws -> [RemoteFile] {
        var reader = try MTPReader(data: connection.get(.objectHandles, [storage, 0, handle]))
        let handles = try reader.array(UInt32.self); try reader.finished()
        guard handles.count <= 200_000, Set(handles).count == handles.count,
              !handles.contains(0), !handles.contains(root), !handles.contains(handle) else { throw malformed("Invalid or cyclic object handle list.") }
        var files: [RemoteFile] = []
        for id in handles {
            let file = try metadata(id, storage: storage, parent: handle, path: path)
            files.append(file); event("preprocess", .object(["fullPath": .string(file.path)]))
        }
        guard Set(files.map(\.name)).count == files.count else { throw malformed("Ambiguous filenames in the device folder.") }
        return files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func resolve(_ path: String, storage: UInt32) throws -> RemoteFile {
        try TransferSafety.validateRemotePath(path)
        var current = RemoteFile(name: "", path: "/", isFolder: true, objectId: root)
        for component in path.split(separator: "/").map(String.init) {
            guard current.isFolder else { throw MTPError(detail: "A component of the path is not a folder.") }
            let matches = try children(storage: storage, handle: current.objectId, path: current.path)
            guard let child = matches.first(where: { $0.name == component }) else { throw MTPError(code: "NotFound", detail: "“\(path)” no longer exists on your phone.") }
            current = child
        }
        return current
    }
    public func list(storage: UInt32, path: String, recursive: Bool = false, filter: Bool = false) throws -> [RemoteFile] {
        let folder = try resolve(path, storage: storage)
        guard folder.isFolder else { throw MTPError(detail: "Choose a folder to browse.") }
        var files: [RemoteFile] = [], seen = Set<UInt32>([folder.objectId])
        func walk(_ folder: RemoteFile, depth: Int) throws {
            guard depth <= 256 else { throw malformed("The folder tree exceeds the depth limit.") }
            for file in try children(storage: storage, handle: folder.objectId, path: folder.path) {
                guard seen.insert(file.objectId).inserted, seen.count <= 200_000 else { throw malformed("Cyclic or excessively large folder tree.") }
                if filter && excludedNames.contains(file.name) { continue }
                files.append(file)
                if recursive && file.isFolder { try walk(file, depth: depth + 1) }
            }
        }
        try walk(folder, depth: 0); return files
    }
    private func assertAbsent(_ name: String, storage: UInt32, parent: RemoteFile) throws {
        try TransferSafety.validateName(name)
        guard parent.isFolder else { throw MTPError(detail: "The destination is not a folder.") }
        try TransferSafety.rejectCollisions([name], existing: children(storage: storage, handle: parent.objectId, path: parent.path).map(\.name))
    }
    private func createObject(storage: UInt32, parent: UInt32, name: String, folder: Bool, size: UInt64, modified: Date = Date()) throws -> UInt32 {
        let data = try ObjectDataset.encode(storage: storage, parent: parent, name: name, folder: folder, size: size, modified: modified)
        let response = try connection.send(.sendObjectInfo, [storage, parent], data: data)
        guard response.count == 3, response[0] == storage, response[1] == parent || (parent == root && response[1] == 0), response[2] != 0, response[2] != root else {
            close(); throw malformed("The device returned an invalid new object handle.")
        }
        return response[2]
    }
    public func makeDirectory(storage: UInt32, path: String) throws {
        try TransferSafety.validateRemotePath(path)
        guard path != "/" else { throw MTPError(code: "Collision", detail: "The storage root already exists.") }
        try writable(storage)
        let parent = try resolve((path as NSString).deletingLastPathComponent, storage: storage)
        let name = (path as NSString).lastPathComponent
        try assertAbsent(name, storage: storage, parent: parent)
        _ = try createObject(storage: storage, parent: parent.objectId, name: name, folder: true, size: 0)
    }
    public func rename(storage: UInt32, path: String, name: String) throws {
        try writable(storage); try TransferSafety.validateName(name)
        guard path != "/" else { throw MTPError(detail: "The storage root cannot be renamed.") }
        let file = try resolve(path, storage: storage)
        if file.name == name { return }
        let parent = try resolve(file.parentPath, storage: storage)
        try assertAbsent(name, storage: storage, parent: parent)
        guard device?.operations.contains(Operation.setObjectProperty.rawValue) == true else { throw MTPError(detail: "This phone does not support renaming files through MTP.") }
        var data = MTPWriter(); try data.string(name)
        _ = try connection.send(.setObjectProperty, [file.objectId, 0xDC07], data: data.data)
    }
    public func delete(storage: UInt32, paths: [String]) throws {
        try writable(storage)
        let files = try paths.map { path -> RemoteFile in
            guard path != "/" else { throw MTPError(detail: "The storage root cannot be deleted.") }
            return try resolve(path, storage: storage)
        }
        for file in files where !files.contains(where: { $0.path != file.path && file.path.hasPrefix($0.path + "/") }) {
            _ = try connection.command(.deleteObject, [file.objectId, 0])
        }
    }
    private func transferProgress(_ name: String, path: String, size: Int64, active: Int64, total: Int64, sent: Int64, count: Int, completed: Int, start: Date) {
        func sizeValue(_ total: Int64, _ sent: Int64) -> JSONValue {
            .object(["total": .integer(total), "sent": .integer(sent), "progress": .number(total == 0 ? 100 : Double(sent) / Double(total) * 100)])
        }
        event("progress", .object(["name": .string(name), "fullPath": .string(path), "speed": .number(Double(sent) / max(0.001, Date().timeIntervalSince(start))), "totalFiles": .integer(Int64(count)), "filesSent": .integer(Int64(completed)), "activeFileSize": sizeValue(size, active), "bulkFileSize": sizeValue(total, sent)]))
    }
    public func upload(storage: UInt32, sources: [URL], destination: String) throws {
        guard !sources.isEmpty else { return }
        let manifest = try TransferSafety.localManifest(sources), total = try TransferSafety.totalBytes(manifest)
        try writable(storage, bytes: total)
        let parent = try resolve(destination, storage: storage)
        guard parent.isFolder else { throw MTPError(detail: "The destination is not a folder.") }
        try TransferSafety.rejectCollisions(sources.map(\.lastPathComponent), existing: children(storage: storage, handle: parent.objectId, path: destination).map(\.name))
        var directories: [String: UInt32] = ["": parent.objectId]
        var sent: Int64 = 0, completed = 0
        let start = Date(); var lastEvent = Date.distantPast
        for entry in manifest {
            let relative = entry.relativePath as NSString
            let parentPath = relative.deletingLastPathComponent
            guard let parentHandle = directories[parentPath], let source = sources.first(where: { entry.relativePath == $0.lastPathComponent || entry.relativePath.hasPrefix($0.lastPathComponent + "/") }) else { throw malformed("Invalid upload manifest.") }
            let name = relative.lastPathComponent
            let path = destination == "/" ? "/" + entry.relativePath : destination + "/" + entry.relativePath
            event("preprocess", .object(["fullPath": .string(path)]))
            // Recheck immediately before each creation. MTP itself has no atomic exclusive-create operation.
            let remoteParent = RemoteFile(name: "", path: (path as NSString).deletingLastPathComponent, isFolder: true, objectId: parentHandle)
            try assertAbsent(name, storage: storage, parent: remoteParent)
            if entry.isFolder {
                directories[entry.relativePath] = try createObject(storage: storage, parent: parentHandle, name: name, folder: true, size: 0)
            } else {
                let directory = try LocalDirectory(path: source.deletingLastPathComponent().path)
                let input = try directory.read(entry.relativePath, expected: entry.size)
                defer { try? input.close() }
                _ = try createObject(storage: storage, parent: parentHandle, name: name, folder: false, size: UInt64(entry.size), modified: try LocalDirectory.modificationDate(input))
                var active: Int64 = 0
                _ = try connection.send(.sendObject, size: UInt64(entry.size)) { count in
                    let chunk = try input.read(upToCount: count) ?? Data()
                    active += Int64(chunk.count); sent += Int64(chunk.count)
                    if Date().timeIntervalSince(lastEvent) >= 0.15 {
                        self.transferProgress(name, path: path, size: entry.size, active: active, total: total, sent: sent, count: manifest.count, completed: completed, start: start); lastEvent = Date()
                    }
                    return chunk
                }
                guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw MTPError(detail: "The source file grew during upload: \(name)") }
            }
            completed += 1
            transferProgress(name, path: path, size: entry.isFolder ? 0 : entry.size, active: entry.isFolder ? 0 : entry.size, total: total, sent: sent, count: manifest.count, completed: completed, start: start)
        }
    }
    public func download(storage: UInt32, sources: [String], destination: URL) throws {
        try TransferSafety.requireUnique(sources.map { ($0 as NSString).lastPathComponent })
        guard !sources.contains(where: { path in sources.contains { $0 != path && path.hasPrefix($0 + "/") } }) else {
            throw MTPError(detail: "Select a folder or its contents, rather than both.")
        }
        let roots = try sources.map { try resolve($0, storage: storage) }
        guard !roots.contains(where: { $0.path == "/" || excludedNames.contains($0.name) }) else { throw MTPError(detail: "Choose files or folders inside the storage root.") }
        var files: [RemoteFile] = []
        for root in roots {
            files.append(root)
            if root.isFolder { files += try list(storage: storage, path: root.path, recursive: true, filter: true) }
        }
        let manifest = try TransferSafety.remoteManifest(roots: roots, descendants: files)
        let total = try TransferSafety.totalBytes(manifest)
        let local = try LocalDirectory(path: destination.path)
        var sent: Int64 = 0, completed = 0
        let start = Date(); var lastEvent = Date.distantPast
        for file in files {
            guard let root = roots.first(where: { file.path == $0.path || file.path.hasPrefix($0.path + "/") }) else { throw malformed("Invalid download manifest.") }
            let relative = root.name + String(file.path.dropFirst(root.path.count))
            if file.isFolder { try local.directory(relative) }
            else {
                let output = try local.create(relative); defer { try? output.close() }
                var active: Int64 = 0
                try connection.receive(.getObject, [file.objectId], expected: UInt64(file.size)) { data in
                    try output.write(contentsOf: data); active += Int64(data.count); sent += Int64(data.count)
                    if Date().timeIntervalSince(lastEvent) >= 0.15 {
                        self.transferProgress(file.name, path: file.path, size: file.size, active: active, total: total, sent: sent, count: files.count, completed: completed, start: start); lastEvent = Date()
                    }
                }
                try LocalDirectory.setModificationDate(file.modified, on: output)
                try output.synchronize()
            }
            completed += 1
            transferProgress(file.name, path: file.path, size: file.size, active: file.size, total: total, sent: sent, count: files.count, completed: completed, start: start)
        }
    }
    /// Correlated IPC is provided by MetopeEngineHost; this adapter is also useful for deterministic tests.
    public func perform(_ request: BridgeRequest, onEvent: @escaping Event = { _, _ in }) throws -> JSONValue {
        event = onEvent; defer { event = { _, _ in } }
        func argument<T: Decodable>(_ key: String, _ type: T.Type = T.self) throws -> T {
            guard let value = request.arguments[key] else { throw MTPError(detail: "Missing engine argument: \(key)") }
            return try value.decode(type)
        }
        func encoded<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
        do {
            if request.operation == "Initialize" { return try encoded(connect()) }
            if request.operation == "Dispose" { close(); return .null }
            let identity = try verifyIdentity()
            switch request.operation {
            case "FetchDeviceInfo": return try encoded(identity)
            case "FetchStorages": return try encoded(storages())
            case "Walk":
                return try encoded(list(storage: argument("storageId"), path: argument("fullPath"), recursive: (try? argument("recursive", Bool.self)) ?? false, filter: (try? argument("skipDisallowedFiles", Bool.self)) ?? false))
            case "FileExists":
                let path: String = try argument("fullPath"), storage: UInt32 = try argument("storageId")
                do { _ = try resolve(path, storage: storage); return .object(["fullpath": .string(path), "exists": .bool(true)]) }
                catch let error as MTPError where error.code == "NotFound" { return .object(["fullpath": .string(path), "exists": .bool(false)]) }
            case "MakeDirectory": try makeDirectory(storage: argument("storageId"), path: argument("fullPath"))
            case "RenameFile": try rename(storage: argument("storageId"), path: argument("fullPath"), name: argument("newFileName"))
            case "DeleteFile": try delete(storage: argument("storageId"), paths: argument("files"))
            case "UploadFiles":
                let sources: [String] = try argument("sources")
                try upload(storage: argument("storageId"), sources: sources.map { URL(fileURLWithPath: $0) }, destination: argument("destination"))
            case "DownloadFiles": try download(storage: argument("storageId"), sources: argument("sources"), destination: URL(fileURLWithPath: argument("destination")))
            default: throw MTPError(detail: "Unknown engine operation: \(request.operation)")
            }
            return .bool(true)
        } catch let error as ResponseFailure { throw error.presented }
        catch {
            if let session, !session.valid {
                throw MTPError(code: "Protocol", detail: error.localizedDescription)
            }
            throw error
        }
    }
}
