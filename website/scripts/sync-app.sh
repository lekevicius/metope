#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="../dist/Metope.app"
if [[ ! -f "$app/Contents/Resources/Assets.car" ]]; then
  echo 'Build the app first: cd .. && ./scripts/build.sh' >&2
  exit 1
fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
if [[ "$version" != '0.1.0' ]]; then
  echo 'Update the version and download link in src/pages/index.astro before packaging a new release.' >&2
  exit 1
fi
codesign --verify --deep --strict "$app"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT
iconutil -c iconset "$app/Contents/Resources/AppIcon.icns" -o "$temp_dir/AppIcon.iconset"
mkdir -p public/images public/downloads
cp "$temp_dir/AppIcon.iconset/icon_128x128@2x.png" public/images/metope-icon.png
CLANG_MODULE_CACHE_PATH="$temp_dir/swift-cache" swift scripts/export-icon.swift "$PWD/$app" "$PWD/public/images/metope-icon-large.png"
ditto -c -k --sequesterRsrc --keepParent "$app" "$temp_dir/Metope-0.1.0-arm64.zip"
mv "$temp_dir/Metope-0.1.0-arm64.zip" public/downloads/
echo 'Updated the website icons and download from dist/Metope.app.'
