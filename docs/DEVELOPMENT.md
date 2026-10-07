# Developing Metope

Metope uses Swift and SwiftUI, with a separate helper process for USB transfers. Run the commands below from the repository root.

## Build and test

Use an Apple Silicon Mac with Xcode 27 selected as the active developer directory:

```sh
./scripts/build.sh
open dist/Metope.app
```

`./scripts/build.sh debug` produces a debug build. Open `Package.swift` in Xcode for editing; use the packaging script for a runnable app with its helper and libraries.

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
swift test --disable-sandbox -debug-info-format none
```

The manifest explicitly stamps the GUI executable with macOS 27 SDK linkage. This matters: the SwiftPM toolchain on this host otherwise stamped the executable with its deployment target and triggered legacy macOS control styling. Deployment remains macOS 26. No older-OS visual fallback is included.

## Signing and notarization

Build with your installed Developer ID Application identity:

```sh
METOPE_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./scripts/build.sh
```

This signs the library, helper, and app with hardened runtime and secure timestamps. Store notarization credentials interactively with `xcrun notarytool store-credentials metope`, then run:

```sh
./scripts/notarize.sh metope
(cd website && npm run sync-app && npm run build)
```

The notarization script waits for Apple’s result, requires acceptance, staples and validates the ticket, and checks Gatekeeper. Rebuilding afterward replaces the stapled app, so notarize again before packaging that build. Credentials are kept in Keychain, never in the repository.

For website captures, launch `dist/Metope.app/Contents/MacOS/Metope --demo --screenshot`. This hides sample labels only; sample transport remains read-only. Normal `--demo` mode remains labeled.

## Icon and website

The editable icon is `Resources/AppIcon.icon`, an Icon Composer document. The packaging script compiles it with `actool`, embeds both `Assets.car` and `AppIcon.icns`, and preserves its Liquid Glass material settings. Edit this document in Icon Composer for future icon changes; the older `scripts/icon.swift` generator is no longer part of the build.

The Astro landing page lives in [`website/`](../website/README.md). Run `npm ci` and `npm run dev` there for local development, or `npm run check && npm run build` for a static production build. After rebuilding and notarizing the app, `npm run sync-app` in `website/` verifies its notarization, refreshes its native icon renders, and packages the download with a SHA-256 file. Cloudflare Pages republishes https://metope.org on every push to `main`; see the website README for deployment settings.

## Architecture

- `Metope`: SwiftUI app, IOKit hotplug hints, native dialogs, Quick Look and application state.
- `MetopeEngine`: Swift packet codecs, USB discovery, session/transaction handling, object filesystem and streamed transfers. Exposes a library product and an injectable `BulkTransport` for tests.
- `CLibUSB`: official libusb public header and module map. libusb handles USB I/O only; it contains no MTP protocol implementation.
- `MetopeEngineHost`: Swift executable owning a single engine, with correlated JSON requests, results and progress over pipes.
- `MetopeCore`: app/helper models, structured errors, asynchronous process client, transfer manifests and staging safety.
- `Tests`: USB packet fixtures, simulated-phone workflows, process failure/cancellation, path and publication safety.

There is no network dependency, account, analytics, or web view. The app is currently unsandboxed to support direct USB access and Finder-selected destinations. macOS handles standard file-access prompts.

## Protocol and validation

- [Protocol research](RESEARCH.md)
- [Engine architecture](ENGINE-PLAN.md)
- [Validation and device test matrix](VALIDATION.md)
- [libusb provenance and rebuilding](../Vendor/libusb/README.md)

The automated suite covers packet fixtures, a simulated device, helper-process behavior, and local transfer safety. Physical-device testing is separate; document the device and actual operations when reporting results.
