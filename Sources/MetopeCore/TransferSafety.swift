import Foundation

public enum TransferSafety {
    public static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), name.utf8.count <= 255 else {
            throw MTPError(detail: "“\(name)” isn’t a safe filename. Use a name without slashes, colons, or control characters.")
        }
    }
    public static func validateRemotePath(_ path: String) throws {
        guard path.hasPrefix("/") else { throw MTPError(detail: "The device returned a relative path.") }
        if path == "/" { return }
        for part in path.dropFirst().split(separator: "/", omittingEmptySubsequences: false) { try validateName(String(part)) }
    }
    public static func child(_ name: String, of parent: String) throws -> String {
        try validateName(name); try validateRemotePath(parent)
        return parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }
    public static func collisionKey(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }
    public static func requireUnique(_ names: [String]) throws {
        var seen = Set<String>()
        for name in names { try validateName(name); guard seen.insert(collisionKey(name)).inserted else { throw MTPError(code: "Collision", detail: name) } }
    }
    public static func rejectCollisions(_ names: [String], existing: [String]) throws {
        try requireUnique(names)
        let keys = Set(existing.map(collisionKey))
        if let match = names.first(where: { keys.contains(collisionKey($0)) }) { throw MTPError(code: "Collision", detail: match) }
    }
    public static func localManifest(_ urls: [URL]) throws -> [ManifestEntry] {
        try requireUnique(urls.map(\.lastPathComponent))
        var entries: [ManifestEntry] = []
        let fm = FileManager.default
        func append(_ url: URL, relative: String) throws {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
                throw MTPError(detail: "“\(url.lastPathComponent)” is a link or special file. Choose the original file instead.")
            }
            try validateName(url.lastPathComponent)
            entries.append(ManifestEntry(relativePath: relative, size: Int64(values.fileSize ?? 0), isFolder: values.isDirectory == true))
            if values.isDirectory == true {
                let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).filter { ![".DS_Store", "[-----DS_Store.mtp.test----].txt"].contains($0.lastPathComponent) }
                try requireUnique(children.map(\.lastPathComponent))
                for child in children { try append(child, relative: relative + "/" + child.lastPathComponent) }
            }
        }
        for url in urls {
            guard ![".DS_Store", "[-----DS_Store.mtp.test----].txt"].contains(url.lastPathComponent) else { throw MTPError(detail: "Metope excludes this system metadata file from transfers.") }
            try append(url, relative: url.lastPathComponent)
        }
        return entries
    }
    public static func remoteManifest(roots: [RemoteFile], descendants: [RemoteFile]) throws -> [ManifestEntry] {
        try requireUnique(roots.map(\.name))
        var entries: [ManifestEntry] = []; var seen: [String: String] = [:]
        for file in roots + descendants {
            try validateRemotePath(file.path); try validateName(file.name)
            guard (file.path as NSString).lastPathComponent == file.name, file.size >= 0 else { throw MTPError(detail: "Invalid device metadata for \(file.name).") }
            guard let root = roots.first(where: { file.path == $0.path || ($0.isFolder && file.path.hasPrefix($0.path + "/")) }) else {
                throw MTPError(detail: "The device returned an object outside the selected folder.")
            }
            let suffix = String(file.path.dropFirst(root.path.count))
            let relative = root.name + suffix
            let key = collisionKey(relative)
            if let previous = seen[key] {
                guard previous == file.path else { throw MTPError(code: "Collision", detail: relative) }
                continue
            }
            seen[key] = file.path
            entries.append(ManifestEntry(relativePath: relative, size: file.size, isFolder: file.isFolder))
        }
        return entries
    }
    public static func totalBytes(_ manifest: [ManifestEntry]) throws -> Int64 {
        var total: Int64 = 0
        for entry in manifest where !entry.isFolder {
            let (value, overflow) = total.addingReportingOverflow(entry.size)
            guard !overflow, entry.size >= 0 else { throw MTPError(detail: "Invalid transfer size.") }
            total = value
        }
        return total
    }
}
public struct ManifestEntry: Codable, Sendable, Equatable {
    public let relativePath: String
    public let size: Int64
    public let isFolder: Bool
    public init(relativePath: String, size: Int64, isFolder: Bool) { self.relativePath = relativePath; self.size = size; self.isFolder = isFolder }
}

/// A staging directory lives on the destination volume; publication never replaces files.
public final class DownloadStaging {
    public let directory: URL
    public let destination: URL
    public let manifest: [ManifestEntry]
    public init(destination: URL, manifest: [ManifestEntry]) throws {
        self.destination = destination; self.manifest = manifest
        directory = destination.appendingPathComponent(".Metope-transfer-\(UUID().uuidString)", isDirectory: true)
        // Validate public API callers too, before creating or touching any paths.
        for entry in manifest { try TransferSafety.validateRemotePath("/" + entry.relativePath) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    public func verify() throws {
        for entry in manifest {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(entry.relativePath)
            let value = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard value.isSymbolicLink != true, entry.isFolder ? value.isDirectory == true : value.isRegularFile == true else {
                throw MTPError(detail: "The downloaded object “\(entry.relativePath)” has the wrong type.")
            }
            if !entry.isFolder && Int64(value.fileSize ?? -1) != entry.size {
                throw MTPError(detail: "“\(entry.relativePath)” is incomplete. Expected \(byteString(entry.size)); the download has \(byteString(Int64(value.fileSize ?? 0))).")
            }
        }
    }
    public func publish() throws -> [URL] {
        try verify()
        let names = Set(manifest.compactMap { $0.relativePath.split(separator: "/").first.map(String.init) }).sorted()
        let existing = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        try TransferSafety.rejectCollisions(names, existing: existing)
        var moved: [(URL, URL)] = []
        do {
            for name in names {
                try Task.checkCancellation()
                let source = directory.appendingPathComponent(name), target = destination.appendingPathComponent(name)
                try FileManager.default.moveItem(at: source, to: target)
                moved.append((source, target))
            }
        } catch {
            // Best-effort rollback never overwrites; staging remains for recovery.
            for (source, target) in moved.reversed() { try? FileManager.default.moveItem(at: target, to: source) }
            throw error
        }
        try? FileManager.default.removeItem(at: directory) // Only our now-empty staging directory.
        return moved.map { $0.1 }
    }
}
