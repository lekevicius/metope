import Foundation
import IOKit

/// USB events are hints. Only a successful MTP request establishes a connection.
final class USBMonitor {
    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0
    var onChange: (() -> Void)?
    init() {
        port = IONotificationPortCreate(kIOMainPortDefault)
        guard let port else { return }
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            var found = false
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service); found = true }
            guard found, let context else { return }
            Unmanaged<USBMonitor>.fromOpaque(context).takeUnretainedValue().onChange?()
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"), callback, context, &added)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"), callback, context, &removed)
        // Drain initial enumeration to arm notifications without manufacturing attach events.
        for iterator in [added, removed] { while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) } }
    }
    deinit {
        if added != 0 { IOObjectRelease(added) }; if removed != 0 { IOObjectRelease(removed) }
        if let port { IONotificationPortDestroy(port) }
    }
}
