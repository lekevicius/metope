import XCTest
import MetopeCore
@testable import MetopeEngine

final class CodecTests: XCTestCase {
    func testContainerMatchesWireBytesAndLargeSentinel() throws {
        let header = ContainerHeader(length: 16, type: 1, code: 0x1002, transaction: 0x12345678)
        XCTAssertEqual(Array(header.encoded), [16,0,0,0,1,0,2,16,0x78,0x56,0x34,0x12])
        XCTAssertEqual(try ContainerHeader(header.encoded).transaction, 0x12345678)
        XCTAssertEqual(ContainerHeader.dataLength(4_294_967_296), UInt32.max)
        XCTAssertEqual(ContainerHeader.dataLength(UInt64(UInt32.max) - 13), UInt32.max - 1)
        XCTAssertEqual(ContainerHeader.dataLength(UInt64.max), UInt32.max)
    }
    func testUTF16SurrogatePairsAndLimits() throws {
        var writer = MTPWriter(); try writer.string("A📷")
        XCTAssertEqual(Array(writer.data), [4,65,0,0x3d,0xd8,0xf7,0xdc,0,0])
        var reader = MTPReader(data: writer.data); XCTAssertEqual(try reader.string(), "A📷"); try reader.finished()
        writer = MTPWriter(); try writer.string(String(repeating: "x", count: 254))
        XCTAssertEqual(writer.data.first, 255)
        XCTAssertThrowsError(try writer.string(String(repeating: "x", count: 255)))
        var invalid = MTPReader(data: Data([2, 0, 0xd8, 0, 0]))
        XCTAssertThrowsError(try invalid.string())
        var missingNull = MTPReader(data: Data([1, 65, 0]))
        XCTAssertThrowsError(try missingNull.string())
    }
    func testBoundsCheckedBeforeArrayAllocation() {
        var reader = MTPReader(data: Data([255,255,255,255]))
        XCTAssertThrowsError(try reader.array(UInt32.self))
        for count in 0..<12 { XCTAssertThrowsError(try ContainerHeader(Data(repeating: 0, count: count))) }
    }
    func testObjectDatasetRoundTripAndSizeSentinel() throws {
        let bytes = try ObjectDataset.encode(storage: 0x10001, parent: 42, name: "📷.jpg", folder: false, size: 5_000_000_000)
        XCTAssertEqual(bytes.count > 52, true)
        let object = try ObjectDataset(bytes)
        XCTAssertEqual(object.name, "📷.jpg"); XCTAssertEqual(object.size, UInt32.max)
        XCTAssertEqual(object.storage, 0x10001); XCTAssertEqual(object.parent, 42); XCTAssertFalse(object.folder)
        XCTAssertFalse(object.isoDate.isEmpty)
        XCTAssertThrowsError(try ObjectDataset(Data(bytes.dropLast())))
    }
    func testResponseCodesDistinguishMissingObjectAndFullStorage() {
        XCTAssertEqual(ResponseFailure(code: 0x200C).presented.code, "ErrorStorageFull")
        XCTAssertNotEqual(ResponseFailure(code: 0x2009).presented.code, "ErrorStorageFull")
    }
}
