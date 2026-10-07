import Foundation
import MetopeCore

func malformed(_ detail: String) -> MTPError { MTPError(code: "Protocol", detail: detail) }

struct MTPReader {
    let data: Data
    var offset = 0
    var remaining: Int { data.count - offset }
    mutating func integer<T: FixedWidthInteger>(_ type: T.Type = T.self) throws -> T {
        let count = MemoryLayout<T>.size
        guard remaining >= count else { throw malformed("Truncated MTP dataset.") }
        var result: T = 0
        for i in 0..<count { result |= T(data[data.startIndex + offset + i]) << (i * 8) }
        offset += count
        return result
    }
    mutating func string() throws -> String {
        let count = Int(try integer(UInt8.self))
        if count == 0 { return "" }
        guard remaining >= count * 2 else { throw malformed("Truncated MTP string.") }
        var units: [UInt16] = []
        for _ in 0..<count { units.append(try integer()) }
        guard units.removeLast() == 0, !units.contains(0) else { throw malformed("Invalid MTP string terminator.") }
        let text = String(decoding: units, as: UTF16.self)
        guard Array(text.utf16) == units else { throw malformed("Invalid UTF-16 in device filename.") }
        return text
    }
    mutating func array<T: FixedWidthInteger>(_ type: T.Type) throws -> [T] {
        let count = Int(try integer(UInt32.self))
        guard count <= remaining / MemoryLayout<T>.size else { throw malformed("Invalid MTP array length.") }
        return try (0..<count).map { _ in try integer(type) }
    }
    func finished() throws { guard remaining == 0 else { throw malformed("Unexpected trailing MTP data.") } }
}
struct MTPWriter {
    var data = Data()
    mutating func integer<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    mutating func string(_ value: String) throws {
        if value.isEmpty { integer(UInt8(0)); return }
        let units = Array(value.utf16)
        guard units.count <= 254, !units.contains(0) else { throw malformed("MTP names must fit in 254 UTF-16 code units.") }
        integer(UInt8(units.count + 1)); units.forEach { integer($0) }; integer(UInt16(0))
    }
}
enum Operation: UInt16 {
    case deviceInfo = 0x1001, openSession = 0x1002, closeSession = 0x1003
    case storageIDs = 0x1004, storageInfo = 0x1005, objectHandles = 0x1007, objectInfo = 0x1008
    case getObject = 0x1009, deleteObject = 0x100B, sendObjectInfo = 0x100C, sendObject = 0x100D
    case getObjectProperty = 0x9803, setObjectProperty = 0x9804
}
struct ContainerHeader {
    var length: UInt32
    var type: UInt16
    var code: UInt16
    var transaction: UInt32
    init(length: UInt32, type: UInt16, code: UInt16, transaction: UInt32) {
        self.length = length; self.type = type; self.code = code; self.transaction = transaction
    }
    init(_ data: Data) throws {
        var r = MTPReader(data: data)
        length = try r.integer(); type = try r.integer(); code = try r.integer(); transaction = try r.integer()
        guard length >= 12, (1...4).contains(type) else { throw malformed("Invalid MTP container header.") }
    }
    var encoded: Data {
        var w = MTPWriter(); w.integer(length); w.integer(type); w.integer(code); w.integer(transaction); return w.data
    }
    static func dataLength(_ payload: UInt64) -> UInt32 {
        payload >= UInt64(UInt32.max) - 12 ? UInt32.max : UInt32(payload + 12)
    }
}

struct DeviceDataset {
    var info: DeviceInfo
    var operations: Set<UInt16>
    init(_ data: Data) throws {
        var r = MTPReader(data: data)
        _ = try r.integer(UInt16.self); _ = try r.integer(UInt32.self); _ = try r.integer(UInt16.self)
        _ = try r.string(); _ = try r.integer(UInt16.self)
        operations = Set(try r.array(UInt16.self))
        for _ in 0..<4 { _ = try r.array(UInt16.self) }
        let manufacturer = try r.string(), model = try r.string(), version = try r.string(), serial = try r.string()
        var details = DeviceInfo.Details(manufacturer: manufacturer, model: model, serial: serial)
        details.DeviceVersion = version; info = DeviceInfo(details: details)
        try r.finished()
    }
}
func decodeStorage(_ data: Data, id: UInt32) throws -> DeviceStorage {
    var r = MTPReader(data: data)
    _ = try r.integer(UInt16.self); _ = try r.integer(UInt16.self)
    let access = try r.integer(UInt16.self), capacity = try r.integer(UInt64.self), free = try r.integer(UInt64.self)
    _ = try r.integer(UInt32.self)
    let name = try r.string(); _ = try r.string(); try r.finished()
    var storage = DeviceStorage(id: id, name: name, capacity: capacity, free: free)
    storage.Info.AccessCapability = access
    return storage
}
struct ObjectDataset {
    var storage: UInt32
    var format: UInt16
    var size: UInt32
    var parent: UInt32
    var name: String
    var modified: String
    var folder: Bool { format == 0x3001 }
    init(_ data: Data) throws {
        var r = MTPReader(data: data)
        storage = try r.integer(); format = try r.integer(); _ = try r.integer(UInt16.self); size = try r.integer()
        _ = try r.integer(UInt16.self)
        for _ in 0..<6 { _ = try r.integer(UInt32.self) }
        parent = try r.integer(); _ = try r.integer(UInt16.self)
        _ = try r.integer(UInt32.self); _ = try r.integer(UInt32.self)
        name = try r.string(); _ = try r.string(); modified = try r.string(); _ = try r.string()
        try r.finished(); try TransferSafety.validateName(name)
    }
    static func encode(storage: UInt32, parent: UInt32, name: String, folder: Bool, size: UInt64, modified: Date = Date()) throws -> Data {
        var w = MTPWriter()
        w.integer(storage); w.integer(UInt16(folder ? 0x3001 : 0x3000)); w.integer(UInt16(0))
        w.integer(size >= UInt64(UInt32.max) ? UInt32.max : UInt32(size)); w.integer(UInt16(0))
        for _ in 0..<6 { w.integer(UInt32(0)) }
        w.integer(parent); w.integer(UInt16(folder ? 1 : 0)); w.integer(UInt32(0)); w.integer(UInt32(0))
        try w.string(name)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd'T'HHmmss"
        try w.string(f.string(from: modified)); try w.string(f.string(from: modified)); try w.string("")
        return w.data
    }
    var isoDate: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        let value = modified.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        for format in ["yyyyMMdd'T'HHmmssXXXXX", "yyyyMMdd'T'HHmmssZ", "yyyyMMdd'T'HHmmss.SSSXXXXX", "yyyyMMdd'T'HHmmss"] {
            f.dateFormat = format
            if let date = f.date(from: value) { return ISO8601DateFormatter().string(from: date) }
        }
        return ""
    }
}
