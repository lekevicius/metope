import Foundation

public struct DeviceInfo: Codable, Sendable {
    public var mtpDeviceInfo: Details
    public struct Details: Codable, Sendable {
        public var Manufacturer: String?
        public var Model: String?
        public var SerialNumber: String?
        public var DeviceVersion: String?
        public init(manufacturer: String, model: String, serial: String) { Manufacturer = manufacturer; Model = model; SerialNumber = serial }
    }
    public var name: String { mtpDeviceInfo.Model.flatMap { $0.isEmpty ? nil : $0 } ?? "Android device" }
    public var identity: String { [mtpDeviceInfo.Manufacturer, mtpDeviceInfo.Model, mtpDeviceInfo.SerialNumber].compactMap { $0 }.joined(separator: "|") }
    public init(details: Details) { mtpDeviceInfo = details }
}
public struct DeviceStorage: Codable, Identifiable, Hashable, Sendable {
    public var Sid: UInt32
    public var Info: Details
    public var id: UInt32 { Sid }
    public var name: String { Info.StorageDescription.isEmpty ? "Internal storage" : Info.StorageDescription }
    public struct Details: Codable, Hashable, Sendable {
        public var StorageDescription: String
        public var MaxCapability: UInt64?
        public var FreeSpaceInBytes: UInt64
        public var AccessCapability: UInt16?
        // Kept stable for the app/helper wire format.
        public init(name: String, capacity: UInt64, free: UInt64) { StorageDescription = name; MaxCapability = capacity; FreeSpaceInBytes = free }
    }
    public init(id: UInt32, name: String, capacity: UInt64, free: UInt64) { Sid = id; Info = Details(name: name, capacity: capacity, free: free) }
    public var usedFraction: Double { guard let total = Info.MaxCapability, total > 0 else { return 0 }; return min(1, max(0, 1 - Double(Info.FreeSpaceInBytes) / Double(total))) }
    public var writable: Bool { Info.AccessCapability == nil || Info.AccessCapability == 0 }
}
public struct RemoteFile: Codable, Identifiable, Hashable, Sendable {
    public var size: Int64
    public var isFolder: Bool
    public var dateAdded: String
    public var name: String
    public var path: String
    public var parentPath: String
    public var objectId: UInt32
    public var id: String { path }
    public init(name: String, path: String, size: Int64 = 0, isFolder: Bool = false, objectId: UInt32 = 0, dateAdded: String = "") {
        self.name = name; self.path = path; self.size = size; self.isFolder = isFolder; self.objectId = objectId; self.dateAdded = dateAdded
        parentPath = (path as NSString).deletingLastPathComponent
    }
    public var kind: String {
        if isFolder { return "Folder" }
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "Document" : "\(ext) file"
    }
    public var symbol: String {
        if isFolder {
            switch name.lowercased() {
            case "dcim", "pictures": return "photo.on.rectangle.angled"
            case "download", "downloads": return "arrow.down.circle"
            case "music": return "music.note"
            case "movies": return "film"
            case "documents": return "doc.text"
            default: return "folder.fill"
            }
        }
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "webp", "gif", "dng": return "photo"
        case "mp4", "mov", "mkv", "webm": return "film"
        case "mp3", "wav", "flac", "m4a", "ogg": return "music.note"
        case "zip", "gz", "tar", "7z": return "doc.zipper"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
    public var modified: Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: dateAdded) ?? ISO8601DateFormatter().date(from: dateAdded) ?? formatter.date(from: dateAdded)
    }
}
public struct TransferProgress: Codable, Sendable {
    public var name: String
    public var fullPath: String
    public var speed: Double
    public var totalFiles: Int64
    public var filesSent: Int64
    public var activeFileSize: Size
    public var bulkFileSize: Size
    public struct Size: Codable, Sendable { public var total: Int64; public var sent: Int64; public var progress: Double }
    public var fraction: Double { bulkFileSize.total > 0 ? min(1, max(0, Double(bulkFileSize.sent) / Double(bulkFileSize.total))) : 0 }
}
public struct Existence: Codable, Sendable { public var fullpath: String; public var exists: Bool }
public func byteString(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
