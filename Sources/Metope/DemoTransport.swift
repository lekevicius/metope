import Foundation
import MetopeCore

@MainActor final class DemoTransport: MTPTransport {
    private var files: [RemoteFile] = [
        .init(name: "DCIM", path: "/DCIM", isFolder: true),
        .init(name: "Documents", path: "/Documents", isFolder: true),
        .init(name: "Download", path: "/Download", isFolder: true),
        .init(name: "Movies", path: "/Movies", isFolder: true),
        .init(name: "Music", path: "/Music", isFolder: true),
        .init(name: "Pictures", path: "/Pictures", isFolder: true),
        .init(name: "Camera", path: "/DCIM/Camera", isFolder: true),
        .init(name: "Autumn in Vilnius.jpg", path: "/Pictures/Autumn in Vilnius.jpg", size: 6_284_992, dateAdded: "2026-10-05 16:42:00"),
        .init(name: "Weekend notes.pdf", path: "/Documents/Weekend notes.pdf", size: 284_512, dateAdded: "2026-10-04 10:12:00"),
        .init(name: "Field recording.wav", path: "/Music/Field recording.wav", size: 128_000_000, dateAdded: "2026-10-03 18:30:00"),
        .init(name: "IMG_20261005_164201.jpg", path: "/DCIM/Camera/IMG_20261005_164201.jpg", size: 7_248_922, dateAdded: "2026-10-05 16:42:01"),
        .init(name: "VID_20261005_172010.mp4", path: "/DCIM/Camera/VID_20261005_172010.mp4", size: 482_504_128, dateAdded: "2026-10-05 17:20:10"),
        .init(name: "Read me.txt", path: "/Read me.txt", size: 164, dateAdded: "2026-10-06 12:00:00")
    ]
    func request(_ operation: String, arguments: [String: JSONValue], onEvent: ((BridgeEvent) -> Void)?) async throws -> JSONValue {
        try await Task.sleep(for: .milliseconds(100))
        func encode<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
        switch operation {
        case "Initialize", "FetchDeviceInfo": return try encode(DeviceInfo(details: .init(manufacturer: "Google", model: "Pixel 9 Pro", serial: "DEMO")))
        case "FetchStorages": return try encode([DeviceStorage(id: 65537, name: "Internal storage", capacity: 128_000_000_000, free: 76_800_000_000)])
        case "Walk":
            let path = try arguments["fullPath"]?.decode(String.self) ?? "/"
            return try encode(files.filter { $0.parentPath == path })
        case "Dispose": return .bool(true)
        default: throw MTPError(detail: "Demo mode is read-only. Connect a phone to transfer or change files.")
        }
    }
    func stop() {}
}
