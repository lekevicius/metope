# Protocol research

Research date: 2026-10-06. **MetopeEngine** implements MTP in native Swift.

## Source evidence

- Android's [MtpServer](https://android.googlesource.com/platform/frameworks/av/+/refs/heads/main/media/mtp/MtpServer.cpp), inspected at blob `80fe51abceff41bc0216093104fa914103f43356`: SendObjectInfo precedes SendObject, large sizes use a sentinel, and the receiver distinguishes initial header/body bytes and short-packet termination.
- [libusb 1.0.30 synchronous I/O](https://libusb.sourceforge.io/api-1.0/group__libusb__syncio.html): check actual byte counts on reads and writes. A timeout may follow partial I/O; never assume it is safe to replay an operation.
- [Android MtpDevice](https://developer.android.com/reference/android/mtp/MtpDevice) documents the storage/object model and 64-bit object operations. [USB-IF documents](https://www.usb.org/documents) provides the MTP specification. This implementation is not a claim of complete spec conformance.

## Adopted behavior

Swift discovers USB interfaces, configures and claims one selected device, owns a single serialized MTP session, negotiates separate headers from the first incoming data packet, uses 64-bit accounting, resolves paths within storage/session boundaries, and translates device response codes. Hotplug remains an IOKit hint; users must unlock the phone, choose File Transfer and accept access prompts. The app checks for known competing MTP clients before connecting.

Transfer operations run in an isolated Swift helper. USB calls have a 15-second timeout; the app has metadata and transfer-inactivity deadlines. Cancellation terminates the helper, invalidates the session and requires reconnecting. Writes are never automatically retried. Existing files are never deliberately removed to replace them.

## Correctness and limits

- Failed metadata reads fail the operation. Walking uses bounds and cycle checks.
- Downloads require exact stream sizes and a matching successful response. Local files use descriptor-relative traversal, no-follow opens and exclusive creation. The app additionally stages, verifies and publishes downloads.
- String encoding preserves UTF-16 surrogate pairs and rejects malformed strings.
- Storage-full is response `0x200C`; invalid-object `0x2009` is reported separately.
- An explicit session-already-open response gets one close/open recovery. Transport/framing failures poison the connection. Broad USB resets and silent interface seizure are intentionally absent.
- MTP cannot promise atomic no-replace creation against a simultaneous on-phone writer. Preflight checks reduce this race; no overwrite/delete fallback exists.
- Files above 4 GiB have codec/property/sentinel tests, but large-file hardware transfers remain unverified. No resume or cryptographic integrity claim.
- File modification times are preserved; folder modification times are not promised. One device at a time; unsupported device extensions are not silently emulated.

## Native Liquid Glass interface

Use native NavigationSplitView, Table, toolbar search and inspector, ToolbarSpacer groups, system colors, SF Symbols, menus, file panels and glass button styles. Keep the app linked against the current SDK: the GUI explicitly stamps SDK 27 with a macOS 26 minimum. The current SwiftPM toolchain otherwise stamped an older SDK, triggering legacy styling. Toolbar modifiers belong inside the detail column to avoid unwanted overflow.

Apple references: [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass), [custom glass views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views), [Landmarks sample](https://developer.apple.com/documentation/swiftui/landmarks-building-an-app-with-liquid-glass).
