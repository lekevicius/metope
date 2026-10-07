import XCTest
import MetopeCore
@testable import MetopeEngine

final class ScriptedUSB: BulkTransport {
    let inputPacketSize = 64, outputPacketSize = 64
    var reads: [Data]
    var writes: [Data] = []
    var closed = false
    init(_ reads: [Data]) { self.reads = reads }
    func read(maxLength: Int) throws -> Data {
        guard !reads.isEmpty else { throw MTPError(code: "Timeout", detail: "Fixture exhausted") }
        let next = reads.removeFirst()
        guard next.count <= maxLength else { throw malformed("Fixture read exceeds buffer") }
        return next
    }
    func write(_ data: Data) throws { writes.append(data) }
    func close() { closed = true }
}
func packet(_ type: UInt16, _ code: UInt16, _ id: UInt32 = 0, _ body: Data = Data(), length: UInt32? = nil) -> Data {
    var result = ContainerHeader(length: length ?? UInt32(body.count + 12), type: type, code: code, transaction: id).encoded
    result.append(body); return result
}
final class SessionTests: XCTestCase {
    func testSessionUsesZeroThenMonotonicTransactionIDs() throws {
        let usb = ScriptedUSB([packet(3, 0x2001), packet(3, 0x2001, 1), packet(3, 0x2001, 2)])
        let session = MTPSession(transport: usb)
        try session.open(); try session.command(.deleteObject, [7, 0]); session.close()
        XCTAssertEqual(try usb.writes.map { try ContainerHeader($0).transaction }, [0,1,2])
        XCTAssertTrue(usb.closed)
    }
    func testStaleSessionRecoveryIsBounded() throws {
        let usb = ScriptedUSB([packet(3, 0x201E), packet(3, 0x2001), packet(3, 0x201E)])
        let session = MTPSession(transport: usb)
        XCTAssertThrowsError(try session.open())
        XCTAssertEqual(try usb.writes.map { try ContainerHeader($0).code }, [0x1002,0x1003,0x1002])
    }
    func testCombinedReceiveConsumesAlignedZLPBeforeResponse() throws {
        let content = Data((0..<116).map(UInt8.init))
        let usb = ScriptedUSB([packet(2, 0x1009, 0, content.prefix(52), length: 128), Data(content.suffix(64)), Data(), packet(3, 0x2001)])
        let session = MTPSession(transport: usb); var result = Data()
        try session.receive(.getObject, [1], expected: 116) { result.append($0) }
        XCTAssertEqual(result, content); XCTAssertTrue(usb.reads.isEmpty)
    }
    func testAlignedDataWithoutZLPDoesNotConsumeResponseAsFile() throws {
        let content = Data(repeating: 42, count: 52)
        let usb = ScriptedUSB([packet(2, 0x1009, 0, content), packet(3, 0x2001)])
        var result = Data(); let session = MTPSession(transport: usb)
        try session.receive(.getObject, [1], expected: 52) { result.append($0) }
        XCTAssertEqual(result, content)
    }
    func testSplitHeaderNegotiationControlsNextSend() throws {
        let usb = ScriptedUSB([packet(2, 0x1001, length: 15), Data([1,2,3]), packet(3, 0x2001), packet(3, 0x2001)])
        let session = MTPSession(transport: usb)
        XCTAssertEqual(try session.get(.deviceInfo), Data([1,2,3])); XCTAssertTrue(session.separateHeader)
        try session.send(.sendObject, data: Data(repeating: 5, count: 64))
        XCTAssertEqual(usb.writes.map(\.count), [12,12,12,64,0])
    }
    func testSendPacketBoundariesAndZeroByteFile() throws {
        for count in [0,1,51,52,53,64,116,16_400] {
            let usb = ScriptedUSB([packet(3, 0x2001)])
            let active = MTPSession(transport: usb)
            try active.send(.sendObject, data: Data(repeating: 0xA5, count: count))
            let payloads = Array(usb.writes.dropFirst())
            XCTAssertEqual(payloads.last?.isEmpty, (count + 12) % 64 == 0, "size \(count)")
            XCTAssertEqual(payloads.reduce(0) { $0 + $1.count }, count + 12)
        }
    }
    func testEarlyErrorResponseAndTransactionMismatch() throws {
        let usb = ScriptedUSB([packet(3, 0x200F)])
        XCTAssertThrowsError(try MTPSession(transport: usb).get(.storageIDs)) { XCTAssertEqual(($0 as? ResponseFailure)?.code, 0x200F) }
        let wrong = ScriptedUSB([packet(3, 0x2001, 999)])
        let invalid = MTPSession(transport: wrong)
        XCTAssertThrowsError(try invalid.command(.deleteObject, [1,0])); XCTAssertFalse(invalid.valid); XCTAssertTrue(wrong.closed)
    }
    func testShortObjectAndShortLocalSourceInvalidateSession() throws {
        let usb = ScriptedUSB([packet(2, 0x1009, 0, Data([1]), length: 112), packet(3, 0x2001)])
        let session = MTPSession(transport: usb)
        XCTAssertThrowsError(try session.receive(.getObject, [1], expected: 100) { _ in })
        XCTAssertFalse(session.valid)
        let outgoing = ScriptedUSB([])
        let writer = MTPSession(transport: outgoing)
        XCTAssertThrowsError(try writer.send(.sendObject, size: 100) { _ in Data() })
        XCTAssertTrue(outgoing.closed)
    }
    func testSizeMismatchAndUnboundedMetadataAreRejected() throws {
        let usb = ScriptedUSB([packet(2, 0x1009, 0, Data([1]), length: 13)])
        XCTAssertThrowsError(try MTPSession(transport: usb).receive(.getObject, expected: 2) { _ in })
        let unlimited = ScriptedUSB([packet(2, 0x1001, length: UInt32.max)])
        XCTAssertThrowsError(try MTPSession(transport: unlimited).get(.deviceInfo))
    }
    func test64BitSentinelReceiveUsesKnownLengthWithoutAllocatingGigabytes() throws {
        let usb = ScriptedUSB([packet(2, 0x1009, length: UInt32.max), Data([1,2,3]), packet(3, 0x2001)])
        var bytes = Data()
        try MTPSession(transport: usb).receive(.getObject, expected: 3) { bytes.append($0) }
        XCTAssertEqual(bytes, Data([1,2,3]))
    }
    func testFailureAfterAllDataNeverReportsSuccess() throws {
        let usb = ScriptedUSB([packet(2, 0x1009, 0, Data([7])), packet(3, 0x200C)])
        XCTAssertThrowsError(try MTPSession(transport: usb).receive(.getObject, expected: 1) { _ in })
    }
}
