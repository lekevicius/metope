# MetopeEngine — Swift protocol port

MetopeEngine implements MTP in Swift and uses libusb for USB transport.

## Architecture and implementation order
1. Bounded little-endian codec: MTP containers, UTF-16 strings, arrays, device/storage/object datasets. Preserve 64-bit sizes and reject malformed lengths before allocating.
2. Injectable USB bulk transport. Swift calls libusb for descriptor enumeration, configuration, interface claim/release, and bulk I/O. Match MTP interfaces and the older Samsung CDC/ACM naming quirk. Reject multiple matching devices. Do not detach drivers or reset unrelated interfaces.
3. Serialized session transaction layer: transaction IDs, command/data/response phases, split-header negotiation, endpoint packet sizes, zero-length termination, exact byte accounting, response status translation. Poison a session on transport/framing failure; never replay writes.
4. Object filesystem: synthesize paths from session-scoped handles, explicit storage roots, full metadata enumeration, cycle detection, 64-bit ObjectSize fallback, create/rename/delete, recursive manifests, streaming upload/download. Reject collisions and unsafe names, preserve empty folders, fail on unreadable metadata rather than silently omitting objects.
5. Swift helper process named MetopeEngineHost. Keep the existing asynchronous JSON IPC boundary and app transfer queue. Killing this helper cancels blocked USB work without hanging the UI. The only native dependency is dynamically linked libusb.
6. Protocol fixtures exercise byte-level transactions and a simulated device end to end; existing filesystem/IPC tests remain. Build/sign the release bundle, verify linked libraries, smoke-test helper, inspect current Liquid Glass UI.

## Acceptance and limits
- Browsing, storage enumeration, create folder, rename, delete, recursive upload/download and progress use Swift engine paths.
- Data-phase success requires exact bytes and an OK response with matching transaction ID. Truncated streams never become successful files.
- MTP has no atomic exclusive-create operation. Preflight collision checks cannot prevent a separate on-phone writer racing creation. Existing objects are never deliberately deleted to replace them.
- Large files use the 0xffffffff container/object size sentinel plus 64-bit ObjectSize. No claim of >4 GiB hardware validation until tested on a phone.
- Cancellation invalidates the session; remote partial uploads and local staging are retained for inspection. No resume promise.
- Hardware testing needs exclusive USB ownership.
- Current macOS 26+ Liquid Glass controls and SDK linkage are preserved.
