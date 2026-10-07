import XCTest
import MetopeCore
@testable import MetopeEngine

/// A USB-level phone fixture. It understands commands and datasets; no engine methods are mocked.
final class FixturePhone: BulkTransport {
    struct Object {
        var parent: UInt32
        var name: String
        var folder: Bool
        var bytes: Data
        var advertisedSize: UInt64?
    }
    let inputPacketSize = 64, outputPacketSize = 64
    let storage: UInt32 = 0x10001
    var objects: [UInt32: Object] = [1: Object(parent: UInt32.max, name: "Pictures", folder: true, bytes: Data()), 2: Object(parent: 1, name: "hello.txt", folder: false, bytes: Data("hello 📷".utf8))]
    var packets: [Data] = []
    var operations: [UInt16] = []
    var failMetadata: UInt32?
    var closed = false
    var nextHandle: UInt32 = 10
    var serial = "fixture-1"
    var pending: (ContainerHeader, [UInt32])?
    var body = Data()
    var bodySize: Int?
    var pendingObject: UInt32?
    var readOnly = false
    func close() { closed = true }
    func read(maxLength: Int) throws -> Data {
        var result = Data()
        while result.count < maxLength {
            guard !packets.isEmpty else { throw malformed("Fixture has no response") }
            let part = packets.removeFirst()
            guard result.count + part.count <= maxLength else { throw malformed("Fixture packet overflow") }
            result.append(part)
            if part.count < inputPacketSize { break }
        }
        return result
    }
    func write(_ bytes: Data) throws {
        if bytes.isEmpty { return }
        if let pending {
            if bodySize == nil {
                let header = try ContainerHeader(bytes)
                guard header.type == 2, header.code == pending.0.code, header.transaction == pending.0.transaction else { throw malformed("Fixture expected data phase") }
                bodySize = Int(header.length) - 12; body = Data(bytes.dropFirst(12))
            } else { body.append(bytes) }
            if body.count == bodySize {
                try finish(pending.0, pending.1, body); self.pending = nil; bodySize = nil; body = Data()
            } else if body.count > bodySize! { throw malformed("Fixture data overflow") }
            return
        }
        let header = try ContainerHeader(bytes)
        guard header.type == 1 else { throw malformed("Fixture expected command") }
        operations.append(header.code)
        var reader = MTPReader(data: Data(bytes.dropFirst(12))); var parameters: [UInt32] = []
        while reader.remaining > 0 { parameters.append(try reader.integer()) }
        switch header.code {
        case 0x1001:
            var w = MTPWriter(); w.integer(UInt16(100)); w.integer(UInt32(6)); w.integer(UInt16(100)); try w.string("microsoft.com: 1.0;"); w.integer(UInt16(0))
            let operations: [UInt16] = [0x1001,0x1002,0x1003,0x1004,0x1005,0x1007,0x1008,0x1009,0x100B,0x100C,0x100D,0x9803,0x9804]
            w.integer(UInt32(operations.count)); operations.forEach { w.integer($0) }
            for _ in 0..<4 { w.integer(UInt32(0)) }
            try w.string("Test vendor"); try w.string("Fixture phone"); try w.string("1.0"); try w.string(serial)
            data(w.data, header)
        case 0x1002, 0x1003: response(header)
        case 0x1004:
            var w = MTPWriter(); w.integer(UInt32(1)); w.integer(storage); data(w.data, header)
        case 0x1005:
            var w = MTPWriter(); w.integer(UInt16(3)); w.integer(UInt16(2)); w.integer(UInt16(readOnly ? 1 : 0))
            w.integer(UInt64(128_000_000_000)); w.integer(UInt64(100_000_000_000)); w.integer(UInt32.max)
            try w.string("Internal storage"); try w.string("Phone"); data(w.data, header)
        case 0x1007:
            XCTAssertEqual(parameters[0], storage); XCTAssertEqual(parameters[1], 0)
            let ids = objects.filter { $0.value.parent == parameters[2] }.keys.sorted()
            var w = MTPWriter(); w.integer(UInt32(ids.count)); ids.forEach { w.integer($0) }; data(w.data, header)
        case 0x1008:
            guard let object = objects[parameters[0]], failMetadata != parameters[0] else { response(header, code: 0x2009); return }
            data(try ObjectDataset.encode(storage: storage, parent: object.parent, name: object.name, folder: object.folder, size: object.advertisedSize ?? UInt64(object.bytes.count)), header)
        case 0x9803:
            XCTAssertEqual(parameters[1], 0xDC04)
            var w = MTPWriter(); w.integer(objects[parameters[0]]!.advertisedSize!); data(w.data, header)
        case 0x1009: data(objects[parameters[0]]!.bytes, header)
        case 0x100B:
            var removed: Set<UInt32> = [parameters[0]]
            var previous = -1
            while previous != removed.count {
                previous = removed.count
                for (id, object) in objects where removed.contains(object.parent) { removed.insert(id) }
            }
            for id in removed { objects[id] = nil }; response(header)
        case 0x100C, 0x100D, 0x9804: pending = (header, parameters)
        default: response(header, code: 0x2005)
        }
    }
    func finish(_ header: ContainerHeader, _ parameters: [UInt32], _ body: Data) throws {
        switch header.code {
        case 0x100C:
            let object = try ObjectDataset(body), id = nextHandle; nextHandle += 1
            XCTAssertEqual(object.storage, parameters[0]); XCTAssertEqual(object.parent, parameters[1])
            objects[id] = Object(parent: object.parent, name: object.name, folder: object.folder, bytes: Data())
            pendingObject = object.folder ? nil : id
            response(header, parameters: [storage, object.parent, id])
        case 0x100D:
            guard let id = pendingObject else { throw malformed("Fixture received file without metadata") }
            objects[id]?.bytes = body; pendingObject = nil; response(header)
        case 0x9804:
            XCTAssertEqual(parameters[1], 0xDC07)
            var r = MTPReader(data: body); objects[parameters[0]]?.name = try r.string(); response(header)
        default: throw malformed("Unexpected fixture data phase")
        }
    }
    func response(_ header: ContainerHeader, code: UInt16 = 0x2001, parameters: [UInt32] = []) {
        var w = MTPWriter(); parameters.forEach { w.integer($0) }
        packets.append(packet(3, code, header.transaction, w.data))
    }
    func data(_ data: Data, _ header: ContainerHeader) {
        let container = packet(2, header.code, header.transaction, data)
        var offset = 0
        while offset < container.count {
            let end = min(offset + inputPacketSize, container.count)
            packets.append(container.subdata(in: offset..<end)); offset = end
        }
        if container.count % inputPacketSize == 0 { packets.append(Data()) }
        response(header)
    }
}

final class EngineTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MetopeEngineTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testPhoneWorkflowBrowseCreateRenameUploadDownloadDelete() throws {
        let phone = FixturePhone(), local = try temporary(), destination = try temporary()
        let engine = MetopeEngine(transport: { phone })
        XCTAssertEqual(try engine.connect().name, "Fixture phone")
        XCTAssertEqual(try engine.storages().first?.Info.FreeSpaceInBytes, 100_000_000_000)
        let initial = try engine.list(storage: phone.storage, path: "/", recursive: true)
        XCTAssertEqual(initial.map(\.path), ["/Pictures", "/Pictures/hello.txt"])
        try engine.makeDirectory(storage: phone.storage, path: "/Documents")
        try engine.rename(storage: phone.storage, path: "/Documents", name: "Archive")
        let folder = local.appendingPathComponent("Trip")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        let bytes = Data((0..<50_000).map { UInt8($0 % 251) })
        try bytes.write(to: folder.appendingPathComponent("photo.bin")); try Data().write(to: folder.appendingPathComponent("zero.txt"))
        try engine.upload(storage: phone.storage, sources: [folder], destination: "/Archive")
        let remote = try engine.list(storage: phone.storage, path: "/Archive/Trip", recursive: true)
        XCTAssertEqual(Set(remote.map(\.name)), Set(["Empty", "photo.bin", "zero.txt"]))
        try engine.download(storage: phone.storage, sources: ["/Archive/Trip"], destination: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Trip/photo.bin")), bytes)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Trip/zero.txt")).count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Trip/Empty").path))
        try engine.delete(storage: phone.storage, paths: ["/Archive"])
        XCTAssertEqual(try engine.list(storage: phone.storage, path: "/").map(\.name), ["Pictures"])
        engine.close(); XCTAssertTrue(phone.closed)
    }
    func testFailedMetadataDoesNotSilentlyOmitFiles() throws {
        let phone = FixturePhone()
        let active = MetopeEngine(transport: { phone }); _ = try active.connect(); phone.failMetadata = 2
        XCTAssertThrowsError(try active.list(storage: phone.storage, path: "/", recursive: true))
    }
    func testLargeSizeUses64BitObjectProperty() throws {
        let phone = FixturePhone(); phone.objects[2]?.advertisedSize = 5_000_000_123
        let engine = MetopeEngine(transport: { phone }); _ = try engine.connect()
        let files = try engine.list(storage: phone.storage, path: "/Pictures")
        XCTAssertEqual(files.first?.size, 5_000_000_123); XCTAssertTrue(phone.operations.contains(0x9803))
    }
    func testCollisionsDoNotDeleteOrReplaceExistingFiles() throws {
        let phone = FixturePhone()
        let active = MetopeEngine(transport: { phone }); _ = try active.connect()
        XCTAssertThrowsError(try active.makeDirectory(storage: phone.storage, path: "/pictures"))
        let local = try temporary(); try Data("preserved".utf8).write(to: local.appendingPathComponent("hello.txt"))
        XCTAssertThrowsError(try active.download(storage: phone.storage, sources: ["/Pictures/hello.txt"], destination: local))
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("hello.txt"), encoding: .utf8), "preserved")
        XCTAssertFalse(phone.operations.contains(0x100B)); XCTAssertFalse(phone.operations.contains(0x100C))
    }
    func testReadOnlyAndIdentityChangeBlockMutations() throws {
        let phone = FixturePhone(); let engine = MetopeEngine(transport: { phone }); _ = try engine.connect()
        phone.readOnly = true
        XCTAssertThrowsError(try engine.makeDirectory(storage: phone.storage, path: "/new"))
        phone.serial = "replacement"
        XCTAssertThrowsError(try engine.perform(BridgeRequest(operation: "MakeDirectory", arguments: ["storageId": .integer(Int64(phone.storage)), "fullPath": .string("/new")]))) { XCTAssertEqual(($0 as? MTPError)?.code, "ErrorDeviceChanged") }
        XCTAssertTrue(phone.closed); XCTAssertFalse(phone.operations.contains(0x100C))
    }
    func testSymlinkDestinationCannotEscapeDownloadRoot() throws {
        let phone = FixturePhone(), local = try temporary(), outside = try temporary()
        let engine = MetopeEngine(transport: { phone }); _ = try engine.connect()
        try FileManager.default.createSymbolicLink(at: local.appendingPathComponent("Pictures"), withDestinationURL: outside)
        XCTAssertThrowsError(try engine.download(storage: phone.storage, sources: ["/Pictures"], destination: local))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
    func testWireProgressAndResultDecodeIntoAppModels() throws {
        let phone = FixturePhone(), local = try temporary()
        let engine = MetopeEngine(transport: { phone })
        let result = try engine.perform(BridgeRequest(operation: "Initialize"))
        XCTAssertEqual(try result.decode(DeviceInfo.self).name, "Fixture phone")
        var updates: [TransferProgress] = []
        _ = try engine.perform(BridgeRequest(operation: "DownloadFiles", arguments: ["storageId": .integer(Int64(phone.storage)), "sources": .strings(["/Pictures/hello.txt"]), "destination": .string(local.path)])) { phase, value in
            if phase == "progress", let update = try? value.decode(TransferProgress.self) { updates.append(update) }
        }
        XCTAssertEqual(updates.last?.fraction, 1); XCTAssertEqual(updates.last?.filesSent, 1)
    }
    func testCaseDistinctNamesBrowseButCannotBeCopiedTogether() throws {
        let phone = FixturePhone(), destination = try temporary()
        phone.objects[3] = FixturePhone.Object(parent: 1, name: "HELLO.txt", folder: false, bytes: Data([1]))
        let engine = MetopeEngine(transport: { phone }); _ = try engine.connect()
        XCTAssertEqual(try engine.list(storage: phone.storage, path: "/Pictures").count, 2)
        XCTAssertThrowsError(try engine.download(storage: phone.storage, sources: ["/Pictures"], destination: destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }
    func testOverlappingDownloadRootsFailBeforeCreatingFiles() throws {
        let phone = FixturePhone(), destination = try temporary()
        let engine = MetopeEngine(transport: { phone }); _ = try engine.connect()
        XCTAssertThrowsError(try engine.download(storage: phone.storage, sources: ["/Pictures", "/Pictures/hello.txt"], destination: destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }
    func testDescriptorBasedFileDatesRoundTrip() throws {
        let root = try temporary(), date = Date(timeIntervalSince1970: 1_600_000_000)
        let directory = try LocalDirectory(path: root.path), file = try directory.create("timestamp.txt")
        defer { try? file.close() }
        try file.write(contentsOf: Data([1,2,3]))
        try LocalDirectory.setModificationDate(date, on: file)
        XCTAssertEqual(try LocalDirectory.modificationDate(file).timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)
    }

}
