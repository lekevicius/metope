# Validation

## Distribution verification — 2026-10-07

Version 0.1.0 for Apple Silicon was signed with Developer ID Application (team `N56PMJ99UT`) and hardened runtime. Apple accepted submission `68f5edd5-302e-4e30-8c08-112fb6679493`. Stapling, ticket validation, deep signature verification, and Gatekeeper assessment passed (`source=Notarized Developer ID`).

The packaged website download is `website/public/downloads/Metope-0.1.0-arm64.zip`; its SHA-256 is recorded alongside it. The packaging script now requires a valid stapled ticket and Gatekeeper acceptance. All 40 Swift tests and the Astro check/build passed. Physical-device acceptance remains outstanding.

## Initial implementation verification — 2026-10-06

Tested locally on 2026-10-06, Apple Silicon, macOS 27.0.1, Xcode 27.0 (27A266a), Swift 6.4. Deployment target: macOS 26.

## Swift engine port

The app uses the new MetopeEngine Swift library through the Swift MetopeEngineHost executable. libusb 1.0.30 is the sole third-party runtime binary; provenance is recorded in `Vendor/libusb/README.md`.

## Automated evidence

40 tests pass: 26 engine tests and 14 core/process tests. Full output: `test-results.txt`.

- Byte-level MTP containers and transaction IDs, session-already-open recovery, combined/split data headers, packet-aligned transfers with/without zero-length termination, zero-byte uploads, response-code mapping and failed final responses.
- Reject mismatched transaction IDs, premature/overlong data, invalid strings/arrays, size changes and unbounded metadata. Transport/framing failure invalidates the session.
- UTF-16 surrogate pairs, string limits and >4 GiB ObjectSize/sentinel handling without allocating multi-gigabyte fixtures.
- USB-level simulated phone: connect, storage enumeration, recursive browsing, mkdir, rename, upload a nested directory with a 50 KB file plus empty folder and zero-byte file, download and compare bytes, then delete.
- Metadata failure never silently omits an object; identity changes and read-only storage block mutation; collisions preserve existing files; overlapping roots and symlink escapes fail; descriptor-based modification dates work.
- App/helper model decoding, split/stale IPC frames, helper crash, serialization/cancellation, safe manifests and no-replace staging publication.

## Bundle and UI evidence

- Debug and optimized release builds succeeded. `codesign --verify --deep --strict` succeeds with local ad-hoc signing.
- GUI executable retains **minos 26.0, sdk 27.0**, checked with `xcrun vtool -show-build`.
- Bundle contains exactly `Helpers/MetopeEngineHost` and `Frameworks/libusb-1.0.dylib`. It is approximately 3.6 MB.
- `otool -L` confirms system Swift/framework dependencies and `@rpath/libusb-1.0.dylib`. The source-tree development rpath is removed from the packaged helper; no Homebrew runtime path remains.
- Launched the bundled helper and verified its correlated Dispose result and clean exit. This smoke test deliberately does not claim a USB interface.
- Relaunched the rebuilt app. Settings visibly says “Built with SwiftUI and MetopeEngine.”
- Inspected the sample browser after rebuilding: current Liquid Glass toolbar grouping, system sidebar styling, native search and inspector remain intact. Demo mode is visibly labeled and read-only.

## Hardware boundary

No physical transfers have been performed with this Swift port.

Still required: Pixel/Samsung discovery and authorization, SD storage, Unicode filename round trips, zero-byte and >4 GiB transfers, SHA-256 round trips, unplug/replug, sleep/wake, full-storage responses, real Quick Look, drag-in and cancellation with partial-file inspection. Fixture success is not hardware compatibility proof. Real-device testing is the next acceptance gate.

Intel builds, VoiceOver end-to-end use and Developer ID signing/notarization are not verified. Older than macOS 26 is unsupported. No resume, folder-timestamp or cryptographic integrity guarantee is provided.

## Build environment

Workspace module caches avoid restricted shared-cache writes. `-debug-info-format none` avoids the host's sandbox-denied optional dSYM generation step. Cache warnings are benign. The release build succeeds under normal workspace permissions.
