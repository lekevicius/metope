#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
profile="${1:-metope}"
app="$PWD/dist/Metope.app"
if ! codesign -dv "$app" 2>&1 | grep -q 'Authority=Developer ID Application:'; then
    echo 'Build with METOPE_SIGNING_IDENTITY set to a Developer ID Application identity first.' >&2
    exit 1
fi
codesign --verify --deep --strict "$app"
archive="$PWD/dist/Metope-notarization.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait --output-format json > "$PWD/dist/notarization.json"
python3 - "$PWD/dist/notarization.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
print('Notarization:', result['status'], result['id'])
if result['status'] != 'Accepted':
    raise SystemExit('Apple did not accept this build; inspect the submission log.')
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
echo 'Notarized and stapled. Refresh the website download with npm run sync-app.'
