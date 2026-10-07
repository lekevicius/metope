import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), integer(Int64), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
    public static func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }
}

public struct BridgeRequest: Codable, Sendable {
    public var id: UUID
    public var operation: String
    public var arguments: [String: JSONValue]
    public init(id: UUID = UUID(), operation: String, arguments: [String: JSONValue] = [:]) {
        self.id = id; self.operation = operation; self.arguments = arguments
    }
}
public struct EngineEnvelope: Codable, Sendable {
    public var errorType: String?
    public var error: String?
    public var data: JSONValue?
    public init(errorType: String? = nil, error: String? = nil, data: JSONValue? = nil) {
        self.errorType = errorType; self.error = error; self.data = data
    }
    public func checked() throws -> JSONValue {
        if let error, !error.isEmpty { throw MTPError(code: errorType ?? "ErrorGeneral", detail: error) }
        if let errorType, !errorType.isEmpty { throw MTPError(code: errorType, detail: error ?? errorType) }
        return data ?? .null
    }
}
public struct BridgeEvent: Codable, Sendable {
    public var id: UUID
    public var phase: String
    public var result: EngineEnvelope
    public init(id: UUID, phase: String, result: EngineEnvelope) { self.id = id; self.phase = phase; self.result = result }
}
public struct MTPError: LocalizedError, Sendable {
    public let code: String
    public let detail: String
    public init(code: String = "ErrorGeneral", detail: String) { self.code = code; self.detail = detail }
    public var errorDescription: String? {
        switch code {
        case "OtherMTPClient": return "Quit \(detail) to connect"
        case "ErrorMtpDetectFailed": return "No Android device found"
        case "ErrorDeviceLocked": return "Unlock your phone"
        case "ErrorAllowStorageAccess", "ErrorNoStorage", "ErrorStorageInfo": return "Allow access to your phone’s files"
        case "ErrorDeviceChanged", "Disconnected": return "Your phone disconnected"
        case "ErrorMultipleDevice": return "Connect one device at a time"
        case "ErrorDeviceSetup": return "Couldn’t open the USB connection"
        case "ErrorStorageFull": return "There isn’t enough free space"
        case "Cancelled": return "Transfer stopped"
        case "Timeout": return "Your phone stopped responding"
        case "Protocol": return "The device connection needs to be reopened"
        case "Collision": return "A file with that name already exists"
        default: return detail
        }
    }
    public var recoverySuggestion: String? {
        switch code {
        case "OtherMTPClient": return "Another file-transfer app is running. Close it to free the USB connection, then try again."
        case "ErrorMtpDetectFailed", "ErrorDeviceSetup": return "Connect with a data-capable USB cable, unlock your phone, and choose File Transfer in its USB notification. Quit other MTP apps if they’re using the connection."
        case "ErrorDeviceLocked", "ErrorAllowStorageAccess", "ErrorNoStorage", "ErrorStorageInfo": return "Unlock your phone, choose File Transfer, and accept the access prompt. Then connect again."
        case "ErrorMultipleDevice": return "MetopeEngine supports one active MTP device. Disconnect the others, then try again."
        case "ErrorDeviceChanged", "Disconnected", "Timeout", "Protocol": return "Reconnect your phone and try again. Unfinished downloads remain in their temporary folder."
        case "Cancelled": return "Reconnect before continuing. An interrupted upload may leave a partial file on your phone."
        case "Collision": return "Rename the source or choose another folder. Metope preserves existing files."
        default: return nil
        }
    }
}
