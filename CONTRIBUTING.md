# Contributing to Metope

Thanks for helping make Android file transfer feel at home on the Mac. Bug reports, device testing, documentation fixes, and focused pull requests all help.

## Report a problem

[Open an issue](https://github.com/lekevicius/metope/issues/new) with:

- Metope version, macOS version, and Mac model.
- Phone or tablet model and Android version, if a device is involved.
- Steps to reproduce, what you expected, and what happened.
- The error message and a screenshot if it helps explain the problem.

Remove personal filenames and other private information from screenshots or logs before sharing them. Never include signing credentials or passwords.

## Share a device report

Use disposable test files and describe what you actually tried: connecting, browsing, sending, saving, renaming, creating folders, or cancelling a transfer. Include the device model, Android version, and whether you used internal storage or an SD card.

For round-trip tests, compare SHA-256 checksums before and after copying. A successful connection or a passing simulated-device test does not establish that all transfers work on a real phone. The current [validation notes](docs/VALIDATION.md) list the remaining hardware checks.

## Make a change

1. Fork the repository and create a branch for your change.
2. Follow the [developer guide](docs/DEVELOPMENT.md) to build and run the relevant checks.
3. Keep the change focused and describe the problem it solves in your pull request.
4. Include how you tested it. For interface changes, add a screenshot; for device behavior, identify the hardware you tested.

For larger changes, open an issue first so the approach can be discussed. Metope aims to stay a small, native Mac app with predictable file-transfer behavior.

App changes should pass the Swift tests. Website changes should pass `npm run check` and `npm run build` from `website/` and be checked at desktop and mobile widths. Signing and notarization are only needed for distributing a release, not for local development.
