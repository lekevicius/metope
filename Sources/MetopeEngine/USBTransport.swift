import Foundation
import CLibUSB
import MetopeCore

/// libusb is only a USB byte pipe. All MTP protocol behavior lives in Swift.
public final class USBTransport: BulkTransport {
    private var context: OpaquePointer?
    private var handle: OpaquePointer?
    private var claimed = false
    private let interface: Int32
    private let input: UInt8
    private let output: UInt8
    public let inputPacketSize: Int
    public let outputPacketSize: Int
    private let timeout: UInt32 = 15_000
    private struct Candidate {
        let device: OpaquePointer
        let configuration: Int32
        let interface: Int32
        let alternate: Int32
        let input: UInt8
        let output: UInt8
        let inputSize: Int
        let outputSize: Int
    }
    public static func discover() throws -> USBTransport {
        var context: OpaquePointer?
        try check(libusb_init(&context))
        var transferred = false
        defer { if !transferred { libusb_exit(context) } }
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(context, &list)
        guard count >= 0, let list else { throw MTPError(code: "ErrorDeviceSetup", detail: "USB enumeration failed.") }
        defer { libusb_free_device_list(list, 1) }
        var candidates: [Candidate] = []
        var discoveryError: Error?
        for index in 0..<count {
            guard let device = list[index] else { continue }
            var descriptor = libusb_device_descriptor()
            guard libusb_get_device_descriptor(device, &descriptor) == 0 else { continue }
            var selected: Candidate?
            for configIndex in 0..<descriptor.bNumConfigurations {
                var config: UnsafeMutablePointer<libusb_config_descriptor>?
                guard libusb_get_config_descriptor(device, configIndex, &config) == 0, let config else { continue }
                defer { libusb_free_config_descriptor(config) }
                guard let interfaces = config.pointee.interface else { continue }
                for i in 0..<Int(config.pointee.bNumInterfaces) {
                    let iface = interfaces[i]
                    guard let alternates = iface.altsetting else { continue }
                    for a in 0..<Int(iface.num_altsetting) {
                        let alt = alternates[a]
                        guard let endpoints = alt.endpoint else { continue }
                        var input: UInt8 = 0, output: UInt8 = 0, event: UInt8 = 0
                        var inputSize = 0, outputSize = 0
                        for e in 0..<Int(alt.bNumEndpoints) {
                            let endpoint = endpoints[e], kind = endpoint.bmAttributes & 3
                            if kind == 2 && endpoint.bEndpointAddress & 0x80 != 0 { input = endpoint.bEndpointAddress; inputSize = Int(endpoint.wMaxPacketSize & 0x7ff) }
                            if kind == 2 && endpoint.bEndpointAddress & 0x80 == 0 { output = endpoint.bEndpointAddress; outputSize = Int(endpoint.wMaxPacketSize & 0x7ff) }
                            if kind == 3 && endpoint.bEndpointAddress & 0x80 != 0 { event = endpoint.bEndpointAddress }
                        }
                        guard input != 0, output != 0, event != 0, [64, 512, 1024].contains(inputSize), [64, 512, 1024].contains(outputSize) else { continue }
                        // Standard still-image/PTP class or named MTP interface, including older Samsung labels.
                        var matches = alt.bInterfaceClass == 6 && alt.bInterfaceSubClass == 1 && alt.bInterfaceProtocol == 1
                        if !matches && alt.iInterface != 0 {
                            var probe: OpaquePointer?
                            let result = libusb_open(device, &probe)
                            if result == 0, let probe {
                                var buffer = [UInt8](repeating: 0, count: 256)
                                let n = libusb_get_string_descriptor_ascii(probe, alt.iInterface, &buffer, 256)
                                libusb_close(probe)
                                if n > 0 {
                                    let name = String(decoding: buffer.prefix(Int(n)), as: UTF8.self).uppercased()
                                    matches = ["MTP", "CDC", "ACM"].contains { name.contains($0) }
                                }
                            } else { discoveryError = usbError(result) }
                        }
                        guard matches else { continue }
                        if selected == nil { selected = Candidate(device: device, configuration: Int32(config.pointee.bConfigurationValue), interface: Int32(alt.bInterfaceNumber), alternate: Int32(alt.bAlternateSetting), input: input, output: output, inputSize: inputSize, outputSize: outputSize) }
                    }
                }
            }
            if let selected { candidates.append(selected) }
        }
        guard !candidates.isEmpty else { throw discoveryError ?? MTPError(code: "ErrorMtpDetectFailed", detail: "No MTP USB interface found.") }
        guard candidates.count == 1 else { throw MTPError(code: "ErrorMultipleDevice", detail: "More than one MTP USB device is connected.") }
        let transport = try USBTransport(context: context, candidate: candidates[0])
        transferred = true; return transport
    }
    private init(context: OpaquePointer?, candidate: Candidate) throws {
        // Transfer context ownership only after setup succeeds; discover releases it on failure.
        interface = candidate.interface; input = candidate.input; output = candidate.output
        inputPacketSize = candidate.inputSize; outputPacketSize = candidate.outputSize
        do {
            try Self.check(libusb_open(candidate.device, &handle))
            var current: Int32 = 0
            try Self.check(libusb_get_configuration(handle, &current))
            if current != candidate.configuration { try Self.check(libusb_set_configuration(handle, candidate.configuration)) }
            try Self.check(libusb_claim_interface(handle, interface)); claimed = true
            if candidate.alternate != 0 { try Self.check(libusb_set_interface_alt_setting(handle, interface, candidate.alternate)) }
            self.context = context
        } catch { close(); throw error }
    }
    public func read(maxLength: Int) throws -> Data {
        guard let handle else { throw MTPError(code: "Disconnected", detail: "USB connection closed.") }
        var buffer = [UInt8](repeating: 0, count: maxLength), actual: Int32 = 0
        try Self.check(libusb_bulk_transfer(handle, input, &buffer, Int32(maxLength), &actual, timeout))
        guard actual >= 0, actual <= maxLength else { throw malformed("Invalid USB read length.") }
        return Data(buffer.prefix(Int(actual)))
    }
    public func write(_ data: Data) throws {
        guard let handle else { throw MTPError(code: "Disconnected", detail: "USB connection closed.") }
        var actual: Int32 = 0
        let result = data.withUnsafeBytes { bytes in
            libusb_bulk_transfer(handle, output, UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress), Int32(data.count), &actual, timeout)
        }
        try Self.check(result)
        guard actual == data.count else { throw malformed("USB accepted only part of the outgoing packet.") }
    }
    public func close() {
        if let handle {
            if claimed { _ = libusb_release_interface(handle, interface); claimed = false }
            libusb_close(handle); self.handle = nil
        }
        if let context { libusb_exit(context); self.context = nil }
    }
    deinit { close() }
    private static func check(_ result: Int32) throws { if result < 0 { throw usbError(result) } }
    private static func usbError(_ result: Int32) -> MTPError {
        let code: String
        switch result {
        case -4: code = "Disconnected"
        case -7: code = "Timeout"
        default: code = "ErrorDeviceSetup"
        }
        let detail = result == -6 ? "The USB interface is in use by another application." : String(cString: libusb_error_name(result))
        return MTPError(code: code, detail: detail)
    }
}
