# Metope — native Android file transfer

## Product contract
A macOS 26+ Swift/SwiftUI application for browsing one USB MTP device, importing and exporting files and folders, creating folders, renaming and deleting objects. MetopeEngine implements the protocol in Swift. No Electron, embedded web UI, ADB, account, network service, or FUSE mount.

The main window is a familiar Mac file browser: source sidebar, unified toolbar, resizable native table, optional icon view and inspector, bottom path bar, floating Liquid Glass transfer accessory. Link against the current SDK so standard controls use current styling; use native ToolbarSpacer groups, toolbar search, system inspector, and glass button styles. Finder is the local file browser. Use native panels, drag-in from Finder, contextual commands, menu shortcuts, system colors, SF Symbols, light/dark appearance, accessibility labels and standard selection.

## Research and architectural decisions
See RESEARCH.md for source-level evidence. The protocol is object based, not POSIX. Storage and object handles are session scoped. Only one operation may use the session at a time. Swift owns packet framing and object semantics; libusb provides the USB byte pipe. See ENGINE-PLAN.md for the detailed port sequence.

Use a separate Swift helper executable, MetopeEngineHost. It owns MetopeEngine and its USB session; a typed, request-ID-tagged JSON-line channel carries results and progress to the Swift app. The process boundary contains faults and gives cancellation a reliable boundary, including when the USB call blocks. Stdout is exclusively the IPC channel. No protocol state is shared with the GUI.

The main actor owns UI state; asynchronous helper I/O never blocks it. The client rejects overlapping operations. The app serializes transfer jobs and pins them to device identity and storage; disconnect invalidates outstanding work. Metadata requests have bounded deadlines. Transfers use an inactivity deadline reset by progress. Cancellation terminates the helper, discards the session and requires reconnect. This is abort, not resumable pause; partially written remote objects may remain.

## Implementation sequence and acceptance criteria

1. **Foundation and provenance**
   - Swift package containing core, native app, engine library, helper, libusb module and tests.
   - Repeatable script emits an ad-hoc-signed .app with Swift helper and libusb and acknowledgments.
   - Document binary provenance, license notices, and deployment boundaries.
2. **Protocol bridge**
   - Typed initialize, storages, walk, existence, mkdir, rename, delete, upload/download and dispose.
   - Decode nullable empty listings, UInt32 handles, Int64 byte counts and structured errors.
   - Preserve session serialization, correlate callbacks, enforce timeouts, handle helper exit and cancellation.
   - Smoke-test the bundled engine without requiring a phone.
3. **Transfer correctness**
   - Validate names, paths and source types. Reject symlinks and case-equivalent destination collisions.
   - Never silently overwrite. Preflight uploads against existing device objects and available capacity.
   - Preflight downloads with recursive manifests; validate all paths and local capacity.
   - Download to a private staging directory on the destination volume; verify file sizes before moving top-level items into place without replacing anything.
   - Keep incomplete downloads recoverable with their staging location; never delete phone originals after copying.
   - Queue records distinguish queued, preparing, transferring, verifying, completed, failed and cancelled. Completion is based on final response plus verification, never progress percentage.
4. **Native application**
   - Sidebar with phone, storage capacity, common phone folders and transfer history.
   - Table and icon browser, natural sort, current-folder search, multi-selection, back/forward/up and clickable breadcrumbs.
   - Inspector with file metadata. Native file import/export, drag-in, rename/new-folder sheets and permanent-delete confirmation.
   - Menus and keyboard commands; native Settings and About; system appearance and hidden-file preference.
   - Useful unplugged, locked, no-storage, busy and error states. Device changes observed using IOKit; refresh after events with debouncing, no USB polling during transfers.
   - Explicit demonstration mode for UI verification; never represent its contents as a connected phone.
5. **Validation and delivery**
   - Unit tests for wire datasets and app/helper messages, large sizes, error mapping, path traversal/collision rejection, manifest verification and interrupted download publication.
   - Real engine launch/no-device response, app bundle dependency/signature checks, GUI inspection and interaction in disconnected and demo modes.
   - Build a runnable app; record exact results and remaining hardware-only checks in VALIDATION.md.

## Scope boundaries
One active MTP device, with unambiguous USB selection. No misleading multi-device chooser. No speculative thumbnail reads, filesystem mount, folder synchronization, automatic device cleanup, overwrite/merge, resumable transfer, or whole-device search. Quick Look may use an explicit verified local download. The default workflow transfers through native panels and Finder drops.

## Physical acceptance matrix
Requires a real phone and user-owned test data: Pixel and Samsung; unlock/allow-access; internal/SD storage; Unicode and empty folders; zero-byte and >4 GiB files; compare SHA-256 after round trips; occupied USB interface; disconnect mid-copy; cancel upload and inspect partial object; sleep/wake; full storage; changes made on phone followed by refresh. Simulator and fixture results do not substitute for this matrix.
