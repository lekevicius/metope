# Metope

A macOS app for browsing and transferring Android files over USB. Built with SwiftUI and **MetopeEngine**, a Swift MTP engine based on OpenMTP.

**Requires macOS 26 or later.** The current build targets Apple Silicon. Intel is not currently packaged or tested.

## Open the app

The ready-to-run build is `dist/Metope.app`. Open it in Finder. The build script uses ad-hoc signing by default; the distribution workflow below uses Developer ID signing and notarization.

Quit other MTP clients before connecting a phone. Connect a data-capable USB cable, unlock the phone, choose **File Transfer** in its USB notification, and accept the storage-access prompt.

Use **Help → Show Sample Files** to inspect the interface without a phone. Sample mode is prominently labeled and read-only. **Help → Exit Sample Files** returns to the real device connection.

## Everyday use

- Browse storage in the sidebar. Double-click folders; use ⌘[ / ⌘] to go back/forward and ⌘↑ for the parent folder.
- Use the toolbar search to filter the current folder. Switch between table and icon views, and open the inspector with ⌥⌘I.
- Drop files or folders from Finder, or use **Send** (⌘U).
- Select files or folders and use **Save** (⌘S) to choose a Mac destination.
- Press Space on a file for Quick Look. It downloads and verifies a local temporary copy first.
- Return renames the selected item. The context menu contains rename and permanent delete; deletion requires confirmation.
- ⌘R refreshes phone-side changes. ⌘⇧. toggles hidden files. ⌘J opens transfer history.
- Disconnect with the sidebar eject control or ⌘E. Transfers are serialized; additional transfers can be queued while one is active.

Existing destination names are preserved. Choose a different folder or rename the source instead of overwriting. File links and special files are rejected. Metope excludes `.DS_Store` and transfer-test metadata from recursive copies.

Downloads go to a hidden `.Metope-transfer-…` staging directory on the destination volume, are checked against the expected file sizes, and then moved into place. Failed downloads retain their staging directory; **Show unfinished download** reveals it. Stopping an upload can leave a partial object on the phone. No automatic deletion or retry occurs. Size verification is not a checksum comparison.

## Build and test

With Xcode 27 selected:

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

The editable icon is `Resources/AppIcon.icon`, copied from the latest saved Icon Composer document. The packaging script compiles it with `actool`, embeds both `Assets.car` and `AppIcon.icns`, and preserves its Liquid Glass material settings. Edit this document in Icon Composer for future icon changes; the older `scripts/icon.swift` generator is no longer part of the build.

The Astro landing page lives in [`website/`](website/README.md). Run `npm ci` and `npm run dev` there for local development, or `npm run check && npm run build` for a static production build. After rebuilding and notarizing the app, `npm run sync-app` in `website/` verifies its notarization, refreshes its native icon renders, and packages the download with a SHA-256 file. Cloudflare Pages republishes https://metope.org on every push to `main`; see the website README for deployment settings.

## Architecture

- `Metope`: SwiftUI app, IOKit hotplug hints, native dialogs, Quick Look and application state.
- `MetopeEngine`: Swift packet codecs, USB discovery, session/transaction handling, object filesystem and streamed transfers. Exposes a library product and an injectable `BulkTransport` for tests.
- `CLibUSB`: official libusb public header and module map. libusb handles USB I/O only; it contains no MTP protocol implementation.
- `MetopeEngineHost`: Swift executable owning a single engine, with correlated JSON requests, results and progress over pipes.
- `MetopeCore`: app/helper models, structured errors, asynchronous process client, transfer manifests and staging safety.
- `Tests`: USB packet fixtures, simulated-phone workflows, process failure/cancellation, path and publication safety.

There is no network dependency, account, analytics, or web view. The app is currently unsandboxed to support direct USB access and Finder-selected destinations. macOS handles standard file-access prompts.

## Research, plan and evidence

- [Protocol research](docs/RESEARCH.md)
- [Implementation plan](docs/PLAN.md)
- [Swift engine port plan](docs/ENGINE-PLAN.md)
- [Validation and remaining hardware checks](docs/VALIDATION.md)
- [Acknowledgments](Resources/ACKNOWLEDGMENTS.txt)

The only third-party binary is dynamically linked libusb 1.0.30; see `Vendor/libusb/README.md` for provenance and rebuilding. The website download is Developer ID signed and notarized by Apple. Physical-device acceptance testing remains outstanding: the Swift engine is fixture-tested, not yet proven across real phones.
