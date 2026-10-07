#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
configuration="${1:-release}"
arch="$(uname -m)"
usb="$PWD/Vendor/libusb/$arch/libusb-1.0.dylib"
if [[ ! -f "$usb" ]]; then
    echo "No libusb build is vendored for $arch. See Vendor/libusb/README.md." >&2
    exit 1
fi
swift build --disable-sandbox -c "$configuration" -debug-info-format none
bin="$(swift build --disable-sandbox -c "$configuration" -debug-info-format none --show-bin-path)"
mkdir -p dist
staging="$(mktemp -d "$PWD/dist/.bundle-XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Metope.app"
mkdir -p "$app/Contents/"{MacOS,Helpers,Frameworks,Resources}
cp "$bin/Metope" "$app/Contents/MacOS/Metope"
cp "$bin/MetopeEngineHost" "$app/Contents/Helpers/MetopeEngineHost"
cp "$usb" "$app/Contents/Frameworks/"
# The source-tree rpath is useful for swift test, but must never ship in the app.
install_name_tool -delete_rpath "$PWD/Vendor/libusb/$arch" "$app/Contents/Helpers/MetopeEngineHost"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/ACKNOWLEDGMENTS.txt "$app/Contents/Resources/"
# Compile the editable Icon Composer document, including its Liquid Glass materials.
xcrun actool "$PWD/Resources/AppIcon.icon" \
    --compile "$app/Contents/Resources" \
    --platform macosx --minimum-deployment-target 26.0 --target-device mac \
    --app-icon AppIcon --output-partial-info-plist "$staging/icon-info.plist" \
    --output-format human-readable-text
identity="${METOPE_SIGNING_IDENTITY:--}"
sign_options=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then
    sign_options+=(--options runtime --timestamp)
fi
for binary in "$app/Contents/Frameworks/libusb-1.0.dylib" "$app/Contents/Helpers/MetopeEngineHost"; do codesign "${sign_options[@]}" "$binary"; done
codesign "${sign_options[@]}" "$app"
codesign --verify --deep --strict "$app"
# Replace the entire generated bundle so retired helpers and libraries cannot survive a rebuild.
rm -rf "$PWD/dist/Metope.app"
mv "$app" "$PWD/dist/Metope.app"
echo "Built $PWD/dist/Metope.app"
