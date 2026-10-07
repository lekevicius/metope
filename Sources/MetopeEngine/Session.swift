import Foundation
import MetopeCore

/// One owner, one synchronous transaction at a time. The app accesses this through its isolated helper.
public protocol BulkTransport: AnyObject {
    var inputPacketSize: Int { get }
    var outputPacketSize: Int { get }
    func read(maxLength: Int) throws -> Data
    func write(_ data: Data) throws
    func close()
}
struct ResponseFailure: LocalizedError {
    let code: UInt16
    var errorDescription: String? { String(format: "MTP response 0x%04X", code) }
    var presented: MTPError {
        switch code {
        case 0x2003: return MTPError(code: "Disconnected", detail: "The device session is no longer open.")
        case 0x2005: return MTPError(detail: "This phone does not support this operation.")
        case 0x2008, 0x2013: return MTPError(code: "ErrorNoStorage", detail: "Storage is unavailable.")
        case 0x2009: return MTPError(detail: "This file no longer exists on your phone. Refresh the folder.")
        case 0x200C: return MTPError(code: "ErrorStorageFull", detail: "The phone's storage is full.")
        case 0x200F: return MTPError(code: "ErrorDeviceLocked", detail: "The phone denied access to this object.")
        case 0x2019: return MTPError(detail: "Your phone is busy. Try again when its current operation finishes.")
        default: return MTPError(detail: errorDescription ?? "MTP operation failed.")
        }
    }
}
final class MTPSession {
    let transport: BulkTransport
    private var nextID: UInt32 = 0
    private var opened = false
    private(set) var valid = true
    private var active = false
    private(set) var separateHeader = false
    static let chunkSize = 16 * 1024
    static let metadataLimit = 32 * 1024 * 1024
    init(transport: BulkTransport) { self.transport = transport }
    deinit { transport.close() }
    func open() throws {
        guard !opened else { return }
        do { _ = try command(.openSession, [UInt32.random(in: 1..<UInt32.max)]) }
        catch let failure as ResponseFailure where failure.code == 0x201E {
            // Only recover an explicit stale session. Never reset a busy device or replay a write.
            _ = try command(.closeSession)
            _ = try command(.openSession, [UInt32.random(in: 1..<UInt32.max)])
        }
        opened = true; nextID = 1
    }
    func close() {
        if valid && opened { _ = try? command(.closeSession) }
        opened = false; valid = false; transport.close()
    }
    @discardableResult func command(_ op: Operation, _ parameters: [UInt32] = []) throws -> [UInt32] {
        try transaction(op, parameters) { id in try response(id: id) }
    }
    func get(_ op: Operation, _ parameters: [UInt32] = []) throws -> Data {
        var data = Data()
        try receive(op, parameters, expected: nil) { data.append($0) }
        return data
    }
    func send(_ op: Operation, _ parameters: [UInt32] = [], data: Data) throws -> [UInt32] {
        var offset = 0
        return try send(op, parameters, size: UInt64(data.count)) { count in
            let end = min(data.count, offset + count); defer { offset = end }
            return data.subdata(in: offset..<end)
        }
    }
    private func transaction<T>(_ op: Operation, _ parameters: [UInt32], body: (UInt32) throws -> T) throws -> T {
        guard valid else { throw MTPError(code: "Disconnected", detail: "Reconnect to open a new device session.") }
        guard !active, parameters.count <= 5 else { throw malformed("Overlapping transaction or invalid parameters.") }
        active = true; defer { active = false }
        let id = nextID
        if opened {
            guard nextID < UInt32.max else { throw malformed("The transaction counter requires a new session.") }
            nextID += 1
        }
        do {
            var bytes = ContainerHeader(length: UInt32(12 + parameters.count * 4), type: 1, code: op.rawValue, transaction: id).encoded
            var w = MTPWriter(); parameters.forEach { w.integer($0) }; bytes.append(w.data)
            try transport.write(bytes)
            return try body(id)
        } catch let error as ResponseFailure {
            if [0x2003, 0x2004].contains(error.code) { valid = false; transport.close() }
            throw error
        } catch {
            // A failed data phase leaves framing unknown. Never issue another request on this pipe.
            valid = false; transport.close(); throw error
        }
    }
    private func firstPacket() throws -> Data {
        for _ in 0..<3 {
            let bytes = try transport.read(maxLength: transport.inputPacketSize)
            if !bytes.isEmpty { return bytes }
        }
        throw malformed("The device returned repeated empty USB packets.")
    }
    private func parseResponse(_ data: Data, id: UInt32) throws -> [UInt32] {
        let header = try ContainerHeader(data)
        guard header.type == 3, header.transaction == id, header.length == data.count,
              data.count <= 32, (data.count - 12) % 4 == 0 else { throw malformed("Unexpected MTP response or transaction ID.") }
        guard header.code == 0x2001 else { throw ResponseFailure(code: header.code) }
        var r = MTPReader(data: data); r.offset = 12
        var parameters: [UInt32] = []
        while r.remaining > 0 { parameters.append(try r.integer()) }
        return parameters
    }
    private func response(id: UInt32) throws -> [UInt32] { try parseResponse(firstPacket(), id: id) }
    func receive(_ op: Operation, _ parameters: [UInt32] = [], expected: UInt64?, sink: (Data) throws -> Void) throws {
        try transaction(op, parameters) { id in
            let first = try firstPacket(), header = try ContainerHeader(first)
            if header.type == 3 {
                _ = try parseResponse(first, id: id)
                throw malformed("The device reported success without sending the requested data.")
            }
            guard header.type == 2, header.code == op.rawValue, header.transaction == id else { throw malformed("Unexpected MTP data container.") }
            let length: UInt64
            if header.length == UInt32.max {
                guard let expected else { throw malformed("An unbounded metadata container was rejected.") }
                length = expected
            } else { length = UInt64(header.length - 12) }
            if let expected, expected != length { throw malformed("The object size changed before download.") }
            if expected == nil, length > Self.metadataLimit { throw malformed("The metadata exceeds the 32 MB limit.") }
            var received = UInt64(first.count - 12)
            guard received <= length else { throw malformed("The data container contains excess bytes.") }
            if first.count == 12 && length > 0 { separateHeader = true }
            else if received < length && first.count % transport.inputPacketSize != 0 {
                throw malformed("The device ended the first data packet early.")
            }
            if received > 0 { try sink(Data(first.dropFirst(12))) }
            while received < length {
                let remaining = length - received
                let packet = transport.inputPacketSize
                let request = min(Self.chunkSize, ((Int(min(remaining, UInt64(Self.chunkSize))) + packet - 1) / packet) * packet)
                let data = try transport.read(maxLength: request)
                guard !data.isEmpty, UInt64(data.count) <= remaining else { throw malformed("The device ended the transfer early or sent excess data.") }
                received += UInt64(data.count)
                guard received == length || data.count % packet == 0 else { throw malformed("The device returned a short object stream.") }
                try sink(data)
            }
            _ = try response(id: id)
        }
    }
    @discardableResult func send(_ op: Operation, _ parameters: [UInt32] = [], size: UInt64, source: (Int) throws -> Data) throws -> [UInt32] {
        try transaction(op, parameters) { id in
            let header = ContainerHeader(length: ContainerHeader.dataLength(size), type: 2, code: op.rawValue, transaction: id).encoded
            var sent: UInt64 = 0
            var lastWrite = 0
            func writeBody(_ count: Int, prefix: Data = Data()) throws {
                let data = try source(count)
                guard data.count == count else { throw malformed("The local file ended before its declared size.") }
                var payload = prefix; payload.append(data)
                try transport.write(payload); lastWrite = payload.count; sent += UInt64(data.count)
            }
            if separateHeader { try transport.write(header); lastWrite = header.count }
            else { try writeBody(Int(min(size, UInt64(transport.outputPacketSize - 12))), prefix: header) }
            while sent < size { try writeBody(Int(min(size - sent, UInt64(Self.chunkSize)))) }
            if lastWrite % transport.outputPacketSize == 0 { try transport.write(Data()) }
            return try response(id: id)
        }
    }
}
